#Requires -Version 5.1
<#
    FPS Booster  -  Gaming-Optimierung fuer Windows 10/11
    Alle Aenderungen werden vorher gesichert und lassen sich mit
    "Alles zuruecksetzen" vollstaendig rueckgaengig machen.
#>

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------
#  Admin-Rechte sicherstellen (startet sich sonst selbst neu)
# ---------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $argList = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show('FPS Booster benötigt Administratorrechte, um Windows-Einstellungen zu ändern.', 'FPS Booster', 'OK', 'Warning') | Out-Null
    }
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------------------------------------------------------------
#  Native Hilfsfunktionen (CPU-Last, RAM, Maus, RAM freigeben)
# ---------------------------------------------------------------
$nativeCode = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class FpsNative
{
    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME { public uint Low; public uint High; }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private class MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
        public MEMORYSTATUSEX() { dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)); }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX buffer);

    [DllImport("psapi.dll")]
    private static extern bool EmptyWorkingSet(IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint param, int[] vparam, uint winIni);

    private static ulong lastIdle = 0;
    private static ulong lastTotal = 0;

    private static ulong ToU(FILETIME f) { return ((ulong)f.High << 32) | f.Low; }

    public static double CpuUsage()
    {
        FILETIME i, k, u;
        if (!GetSystemTimes(out i, out k, out u)) return -1;
        ulong idle = ToU(i);
        ulong total = ToU(k) + ToU(u);
        ulong dIdle = idle - lastIdle;
        ulong dTotal = total - lastTotal;
        lastIdle = idle;
        lastTotal = total;
        if (dTotal == 0) return 0;
        double v = 100.0 * (1.0 - (double)dIdle / (double)dTotal);
        if (v < 0) v = 0;
        if (v > 100) v = 100;
        return v;
    }

    public static double[] Memory()
    {
        MEMORYSTATUSEX m = new MEMORYSTATUSEX();
        if (!GlobalMemoryStatusEx(m)) return new double[] { 0, 0, 0 };
        double total = m.ullTotalPhys / 1073741824.0;
        double used = (m.ullTotalPhys - m.ullAvailPhys) / 1073741824.0;
        return new double[] { m.dwMemoryLoad, used, total };
    }

    public static int TrimAll(string[] skip)
    {
        int count = 0;
        foreach (Process p in Process.GetProcesses())
        {
            try
            {
                if (p.Id == 0 || p.Id == 4) continue;
                bool isSkipped = false;
                if (skip != null)
                {
                    foreach (string n in skip)
                    {
                        if (string.Equals(n, p.ProcessName, StringComparison.OrdinalIgnoreCase)) { isSkipped = true; break; }
                    }
                }
                if (isSkipped) continue;
                // Nur minimale Rechte (Abfrage + Speicherquote) - kein Vollzugriff auf fremde Prozesse
                IntPtr h = OpenProcess(0x1000 | 0x0100, false, p.Id);
                if (h != IntPtr.Zero)
                {
                    if (EmptyWorkingSet(h)) count++;
                    CloseHandle(h);
                }
            }
            catch { }
            finally { p.Dispose(); }
        }
        return count;
    }

    public static bool SetMouse(int t1, int t2, int speed)
    {
        int[] v = new int[] { t1, t2, speed };
        return SystemParametersInfo(0x0004, 0, v, 0x03);
    }
}
'@
if (-not ('FpsNative' -as [type]) -or -not ([FpsNative].GetMethod('TrimAll', [type[]]@([string[]])))) { Add-Type -TypeDefinition $nativeCode -Language CSharp }

# ---------------------------------------------------------------
#  Daten / Sicherung
# ---------------------------------------------------------------
$DataDir      = Join-Path $env:LOCALAPPDATA 'FPSBooster'
$BackupFile   = Join-Path $DataDir 'backup.json'
$SettingsFile = Join-Path $DataDir 'settings.json'
$AppDir = $PSScriptRoot
if (-not $AppDir) { $AppDir = $DataDir }
$LogFile   = Join-Path $AppDir 'log.txt'
$CrashFile = Join-Path $AppDir 'fehler.txt'
try { [IO.File]::AppendAllText($LogFile, '') } catch { $LogFile = Join-Path $DataDir 'log.txt'; $CrashFile = Join-Path $DataDir 'fehler.txt' }
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

$GuidRegex    = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
$UltimateBase = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$HighPerf     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

function Read-JsonAsHashtable([string]$path) {
    $h = @{}
    if (Test-Path $path) {
        try {
            $raw = Get-Content -Path $path -Raw -ErrorAction Stop
            if ($raw -and $raw.Trim().Length -gt 0) {
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
            }
        } catch { }
    }
    return $h
}

$script:Backup   = Read-JsonAsHashtable $BackupFile
$script:Settings = Read-JsonAsHashtable $SettingsFile

function Save-Backup {
    try { ConvertTo-Json -InputObject $script:Backup -Depth 6 | Set-Content -Path $BackupFile -Encoding UTF8 -ErrorAction Stop } catch { }
}
function Save-Settings {
    try { ConvertTo-Json -InputObject $script:Settings -Depth 6 | Set-Content -Path $SettingsFile -Encoding UTF8 -ErrorAction Stop } catch { }
}

# ---------------------------------------------------------------
#  Registry-Helfer
# ---------------------------------------------------------------
function Get-RegInfo([string]$path, [string]$name) {
    $r = @{ Existed = $false; Value = $null; Kind = 'DWord' }
    try {
        if (Test-Path $path) {
            $key = Get-Item -Path $path -ErrorAction Stop
            if ($key.GetValueNames() -contains $name) {
                $r.Existed = $true
                $r.Value   = $key.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
                $r.Kind    = $key.GetValueKind($name).ToString()
            }
        }
    } catch { }
    return $r
}

function Set-RegValue([string]$path, [string]$name, $value, [string]$kind) {
    if (-not $kind) { $kind = 'DWord' }
    if (-not (Test-Path $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $kind -Force -ErrorAction Stop | Out-Null
}

function Backup-RegValue([string]$path, [string]$name) {
    $key = "$path|$name"
    if ($script:Backup.ContainsKey($key)) { return }
    $info = Get-RegInfo $path $name
    $script:Backup[$key] = @{ Path = $path; Name = $name; Existed = $info.Existed; Value = $info.Value; Kind = $info.Kind }
}

function Apply-RegEntries($entries) {
    foreach ($e in $entries) {
        Backup-RegValue $e.P $e.N
        Set-RegValue $e.P $e.N $e.V $e.T
    }
    Save-Backup
}

function Test-RegEntries($entries) {
    if (-not $entries -or @($entries).Count -eq 0) { return $false }
    foreach ($e in $entries) {
        $info = Get-RegInfo $e.P $e.N
        if (-not $info.Existed) { return $false }
        if ([string]$info.Value -ne [string]$e.V) { return $false }
    }
    return $true
}

function New-Entry([string]$p, [string]$n, $v, [string]$t = 'DWord') {
    return @{ P = $p; N = $n; V = $v; T = $t }
}

# ---------------------------------------------------------------
#  Energieplan
# ---------------------------------------------------------------
function Get-ActiveScheme {
    $o = (powercfg /getactivescheme 2>$null) | Out-String
    if ($o -match $GuidRegex) { return $Matches[1].ToLower() }
    return $null
}

function Get-ActiveSchemeName {
    $o = (powercfg /getactivescheme 2>$null) | Out-String
    if ($o -match '\((.+)\)') { return $Matches[1].Trim() }
    return 'Unbekannt'
}

function Enable-PerformancePlan {
    $current = Get-ActiveScheme
    if (-not $script:Settings['OriginalScheme'] -and $current) {
        $script:Settings['OriginalScheme'] = $current
        Save-Settings
    }
    $list = (powercfg /list 2>$null) | Out-String
    $guid = $script:Settings['UltimateGuid']
    if (-not $guid -or ($list -notmatch [regex]::Escape($guid))) {
        $guid = $null
        $out = (powercfg -duplicatescheme $UltimateBase 2>&1) | Out-String
        if ($out -match $GuidRegex) {
            $guid = $Matches[1].ToLower()
            powercfg /changename $guid 'FPS Booster - Ultimative Leistung' 'Erstellt von FPS Booster' 2>$null | Out-Null
        }
        $script:Settings['UltimateGuid'] = $guid
        Save-Settings
    }
    if ($guid) {
        powercfg /setactive $guid 2>$null | Out-Null
        if ((Get-ActiveScheme) -eq $guid) { return 'Ultimative Leistung aktiviert' }
    }
    powercfg /setactive $HighPerf 2>$null | Out-Null
    if ((Get-ActiveScheme) -eq $HighPerf) { return 'Höchstleistung aktiviert' }
    throw 'Kein Hochleistungs-Energieplan verfügbar (bei manchen Laptops gesperrt).'
}

function Test-PerformancePlan {
    $a = Get-ActiveScheme
    if (-not $a) { return $false }
    return (($a -eq $script:Settings['UltimateGuid']) -or ($a -eq $HighPerf))
}

# ---------------------------------------------------------------
#  Netzwerk-Interfaces (Nagle)
# ---------------------------------------------------------------
function Get-NagleEntries {
    $res = @()
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    foreach ($k in (Get-ChildItem -Path $base -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $ip = $null
        if ($p.DhcpIPAddress -and $p.DhcpIPAddress -ne '0.0.0.0') { $ip = $p.DhcpIPAddress }
        elseif ($p.IPAddress) {
            $first = @($p.IPAddress)[0]
            if ($first -and $first -ne '0.0.0.0') { $ip = $first }
        }
        if ($ip) {
            $path = "$base\$($k.PSChildName)"
            $res += New-Entry $path 'TcpAckFrequency' 1
            $res += New-Entry $path 'TCPNoDelay' 1
        }
    }
    return ,$res
}

# ---------------------------------------------------------------
#  Optimierungen (Tweaks)
# ---------------------------------------------------------------
$MM    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$Games = "$MM\Tasks\Games"
$GCS   = 'HKCU:\System\GameConfigStore'

$Tweaks = @(
    [pscustomobject]@{ Id='power'; Kind='power'; Default=$true; Restart=$false
        Title='Energieplan: Ultimative Leistung'
        Desc='CPU taktet nicht mehr herunter, keine Energiespar-Verzögerungen. Größter Einzeleffekt auf stabile FPS.'
        Reg=$null },
    [pscustomobject]@{ Id='gamemode'; Kind='reg'; Default=$true; Restart=$false
        Title='Windows-Spielmodus an'
        Desc='Windows priorisiert das laufende Spiel und pausiert Updates/Hintergrundaufgaben.'
        Reg=@( (New-Entry 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1),
               (New-Entry 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1) ) },
    [pscustomobject]@{ Id='gamedvr'; Kind='reg'; Default=$true; Restart=$false
        Title='Xbox Game DVR / Hintergrundaufnahme aus'
        Desc='Die ständige Hintergrund-Videoaufnahme kostet spürbar FPS. Game Bar selbst bleibt nutzbar.'
        Reg=@( (New-Entry $GCS 'GameDVR_Enabled' 0),
               (New-Entry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0) ) },
    [pscustomobject]@{ Id='gpusched'; Kind='reg'; Default=$true; Restart=$true
        Title='Hardwarebeschleunigte GPU-Planung'
        Desc='Die Grafikkarte verwaltet ihren Speicher selbst - weniger Latenz. Wirkt nach Neustart.'
        Reg=@( (New-Entry 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2) ) },
    [pscustomobject]@{ Id='priority'; Kind='reg'; Default=$true; Restart=$false
        Title='Spiele-Priorität (CPU & GPU)'
        Desc='Gibt Spielen im Windows-Multimedia-Scheduler höchste CPU- und GPU-Priorität.'
        Reg=@( (New-Entry $MM 'SystemResponsiveness' 10),
               (New-Entry $Games 'GPU Priority' 8),
               (New-Entry $Games 'Priority' 6),
               (New-Entry $Games 'Scheduling Category' 'High' 'String'),
               (New-Entry $Games 'SFIO Priority' 'High' 'String') ) },
    [pscustomobject]@{ Id='netthrottle'; Kind='reg'; Default=$true; Restart=$true
        Title='Netzwerk-Drosselung aus'
        Desc='Windows bremst Netzwerkpakete nicht mehr bei Multimedia-Last. Wirkt nach Neustart.'
        Reg=@( (New-Entry $MM 'NetworkThrottlingIndex' -1) ) },
    [pscustomobject]@{ Id='nagle'; Kind='reg'; Default=$true; Restart=$true
        Title='Niedriger Ping (Nagle-Algorithmus aus)'
        Desc='Netzwerkpakete werden sofort gesendet statt gesammelt - weniger Verzögerung online.'
        Reg=(Get-NagleEntries) },
    [pscustomobject]@{ Id='mouse'; Kind='reg'; Default=$true; Restart=$false
        Title='Mausbeschleunigung aus'
        Desc='1:1-Mausbewegung für präzises Zielen ("Zeigerbeschleunigung verbessern" aus).'
        Reg=@( (New-Entry 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'),
               (New-Entry 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'),
               (New-Entry 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String') ) },
    [pscustomobject]@{ Id='visual'; Kind='reg'; Default=$true; Restart=$false
        Title='Visuelle Effekte reduzieren'
        Desc='Transparenz und Animationen aus - entlastet Desktop und GPU. Teilweise nach Neuanmeldung.'
        Reg=@( (New-Entry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2),
               (New-Entry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0),
               (New-Entry 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' 'String') ) },
    [pscustomobject]@{ Id='bgapps'; Kind='reg'; Default=$true; Restart=$false
        Title='Hintergrund-Apps blockieren'
        Desc='Store-Apps dürfen nicht mehr im Hintergrund laufen (spart CPU & RAM).'
        Reg=@( (New-Entry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1) ) },
    [pscustomobject]@{ Id='notify'; Kind='reg'; Default=$false; Restart=$false
        Title='Benachrichtigungen aus'
        Desc='Keine Windows-Popups mehr, die dich aus dem Spiel reißen.'
        Reg=@( (New-Entry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0) ) },
    [pscustomobject]@{ Id='fso'; Kind='reg'; Default=$false; Restart=$false
        Title='Vollbild-Optimierungen aus (Experte)'
        Desc='Echtes Exklusiv-Vollbild. Hilft bei manchen älteren Spielen, bei neuen meist ohne Effekt.'
        Reg=@( (New-Entry $GCS 'GameDVR_FSEBehaviorMode' 2),
               (New-Entry $GCS 'GameDVR_HonorUserFSEBehaviorMode' 1),
               (New-Entry $GCS 'GameDVR_FSEBehavior' 2),
               (New-Entry $GCS 'GameDVR_DXGIHonorFSEWindowsCompatible' 1) ) }
)

function Invoke-Tweak($t) {
    if ($t.Kind -eq 'power') { return (Enable-PerformancePlan) }
    if (-not $t.Reg -or @($t.Reg).Count -eq 0) { throw 'Auf diesem PC nicht verfügbar.' }
    Apply-RegEntries $t.Reg
    if ($t.Id -eq 'mouse') { [FpsNative]::SetMouse(0, 0, 0) | Out-Null }
    return 'angewendet'
}

function Test-Tweak($t) {
    try {
        if ($t.Kind -eq 'power') { return (Test-PerformancePlan) }
        return (Test-RegEntries $t.Reg)
    } catch { return $false }
}

function Restore-All {
    $ok = 0; $fail = 0
    foreach ($k in @($script:Backup.Keys)) {
        $b = $script:Backup[$k]
        try {
            if ($b.Existed) {
                Set-RegValue $b.Path $b.Name $b.Value $b.Kind
            } else {
                if (Test-Path $b.Path) { Remove-ItemProperty -Path $b.Path -Name $b.Name -ErrorAction SilentlyContinue }
            }
            $ok++
        } catch { $fail++; Write-Log "Konnte $($b.Name) nicht zurücksetzen: $($_.Exception.Message)" 'ERR' }
    }

    $orig = $script:Settings['OriginalScheme']
    if ($orig) { powercfg /setactive $orig 2>$null | Out-Null }
    $ult = $script:Settings['UltimateGuid']
    if ($ult -and $ult -ne $orig) { powercfg /delete $ult 2>$null | Out-Null }
    $script:Settings['OriginalScheme'] = $null
    $script:Settings['UltimateGuid'] = $null

    try {
        $t1 = [int](Get-RegInfo 'HKCU:\Control Panel\Mouse' 'MouseThreshold1').Value
        $t2 = [int](Get-RegInfo 'HKCU:\Control Panel\Mouse' 'MouseThreshold2').Value
        $sp = [int](Get-RegInfo 'HKCU:\Control Panel\Mouse' 'MouseSpeed').Value
        [FpsNative]::SetMouse($t1, $t2, $sp) | Out-Null
    } catch { }

    $script:Backup = @{}
    Save-Backup
    Save-Settings
    return @($ok, $fail)
}

# ---------------------------------------------------------------
#  Werkzeuge
# ---------------------------------------------------------------
function Clear-TempFiles {
    $freed = [int64]0
    $paths = @($env:TEMP, (Join-Path $env:windir 'Temp')) | Select-Object -Unique
    foreach ($root in $paths) {
        if (-not $root -or -not (Test-Path $root)) { continue }
        $files = Get-ChildItem -Path $root -Recurse -Force -File -ErrorAction SilentlyContinue
        $i = 0
        foreach ($f in $files) {
            $len = $f.Length
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $freed += $len
            } catch { }
            $i++
            if ($i % 300 -eq 0) { Invoke-DoEvents }
        }
        $dirs = Get-ChildItem -Path $root -Recurse -Force -Directory -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending
        foreach ($d in $dirs) {
            try { Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop } catch { }
        }
    }
    return [math]::Round($freed / 1MB, 1)
}

function Clear-Dns {
    try { Clear-DnsClientCache -ErrorAction Stop; return $true }
    catch { ipconfig /flushdns 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) }
}

# Spiele und Anti-Cheat werden NIE angefasst (kein RAM-Trimmen, nicht schließbar)
$GameSkip = @('ShooterGame','ShooterGame_BE','ShooterGame_EAC','ArkAscended','ArkAscended_BE','ArkAscended_EAC',
              'BEService','BEService_x64','BEDaisy','BattlEye','EasyAntiCheat','EasyAntiCheat_EOS','EACLauncher',
              'vgc','vgtray','FACEIT','faceit','EAAntiCheat.GameServiceLauncher','EAAntiCheat.GameService',
              'steam','steamwebhelper','steamservice','GameOverlayUI','EpicGamesLauncher','EpicWebHelper')

$KnownBackground = @('OneDrive','Teams','ms-teams','Spotify','Skype','Dropbox','GoogleDriveFS','CCXProcess',
                     'Creative Cloud','AdobeCollabSync','msedge','chrome','firefox','opera','brave','Cortana',
                     'PhoneExperienceHost','YourPhone','WhatsApp','Telegram','iCloudServices')
$Protected = @('explorer','powershell','pwsh','conhost','ApplicationFrameHost','TextInputHost','SystemSettings',
               'ShellExperienceHost','StartMenuExperienceHost','SearchHost','SearchApp','dwm','csrss','winlogon',
               'svchost','lsass','services','smss','wininit','Taskmgr','LockApp','RuntimeBroker','sihost','ctfmon') + $GameSkip

function Get-ClosableApps {
    $all = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.SessionId -ne 0 }
    $names = @{}
    foreach ($p in $all) {
        if ($Protected -contains $p.ProcessName) { continue }
        $windowed = ($p.MainWindowHandle -ne [IntPtr]::Zero)
        if ($windowed -or ($KnownBackground -contains $p.ProcessName)) { $names[$p.ProcessName] = $true }
    }
    $result = @()
    foreach ($n in $names.Keys) {
        $procs = @($all | Where-Object { $_.ProcessName -eq $n })
        $mb = 0
        foreach ($p in $procs) { try { $mb += $p.WorkingSet64 } catch { } }
        $result += [pscustomobject]@{ Name = $n; Count = $procs.Count; MB = [math]::Round($mb / 1MB) }
    }
    return ($result | Sort-Object MB -Descending)
}

function Get-WindowedProcesses {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.Id -ne $PID -and ($Protected -notcontains $_.ProcessName) } |
        Sort-Object ProcessName
}

# ---------------------------------------------------------------
#  Oberflaeche (XAML)
# ---------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="FPS Booster" Width="1060" Height="720" MinWidth="900" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#0D1017" FontFamily="Segoe UI" Foreground="#E6E9F0">
  <Window.Resources>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="46" Height="24" Background="Transparent">
              <Border x:Name="Track" CornerRadius="12" Background="#2A303D"/>
              <Ellipse x:Name="Knob" Width="18" Height="18" Fill="#8A93A6" HorizontalAlignment="Left" Margin="3,0,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#00C853"/>
                <Setter TargetName="Knob" Property="Fill" Value="White"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,3,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#E6E9F0"/>
      <Setter Property="Background" Value="#1B2130"/>
      <Setter Property="BorderBrush" Value="#2C3446"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Nav" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Margin" Value="0,2"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#151A24"/>
      <Setter Property="BorderBrush" Value="#232A38"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="16"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="230"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- Seitenleiste -->
    <Border Grid.Column="0" Background="#0A0D13" BorderBrush="#1C2230" BorderThickness="0,0,1,0">
      <DockPanel Margin="16">
        <StackPanel DockPanel.Dock="Top">
          <TextBlock Text="FPS" FontSize="30" FontWeight="Black" Foreground="#00E676"/>
          <TextBlock Text="BOOSTER" FontSize="18" FontWeight="Bold" Margin="0,-6,0,24"/>
          <Button x:Name="NavTweaks" Style="{StaticResource Nav}" Content="⚡  Optimierungen"/>
          <Button x:Name="NavTools"  Style="{StaticResource Nav}" Content="🛠  Werkzeuge"/>
          <Button x:Name="NavLog"    Style="{StaticResource Nav}" Content="📋  Protokoll"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom" VerticalAlignment="Bottom">
          <TextBlock Text="LIVE" FontSize="11" Foreground="#6B7488" FontWeight="Bold" Margin="0,0,0,6"/>
          <TextBlock x:Name="TxtCpu" Text="CPU: -" FontSize="13"/>
          <ProgressBar x:Name="BarCpu" Height="6" Maximum="100" Margin="0,4,0,10" Background="#1B2130" Foreground="#00E676" BorderThickness="0"/>
          <TextBlock x:Name="TxtRam" Text="RAM: -" FontSize="13"/>
          <ProgressBar x:Name="BarRam" Height="6" Maximum="100" Margin="0,4,0,10" Background="#1B2130" Foreground="#40C4FF" BorderThickness="0"/>
          <TextBlock x:Name="TxtPlan" Text="Energieplan: -" FontSize="12" Foreground="#9AA3B5" TextWrapping="Wrap"/>
          <TextBlock x:Name="TxtSys" Text="" FontSize="11" Foreground="#6B7488" TextWrapping="Wrap" Margin="0,10,0,0"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- Hauptbereich -->
    <Grid Grid.Column="1" Margin="24,20,24,16">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Boost-Kopf -->
      <Border Grid.Row="0" CornerRadius="12" Padding="20" Margin="0,0,0,16">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#0F2A1E" Offset="0"/>
            <GradientStop Color="#121826" Offset="1"/>
          </LinearGradientBrush>
        </Border.Background>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel VerticalAlignment="Center">
            <TextBlock x:Name="TxtStatus" Text="Bereit" FontSize="22" FontWeight="Bold"/>
            <TextBlock x:Name="TxtStatusSub" Text="Wähle unten aus, was optimiert werden soll, und drück BOOST." Foreground="#9AA3B5" Margin="0,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnRestore" Style="{StaticResource Btn}" Content="↺  Alles zurücksetzen" Margin="0,0,12,0"/>
            <Button x:Name="BtnBoost" Style="{StaticResource Btn}" Background="#00C853" BorderBrush="#00E676"
                    Foreground="#06140C" FontSize="18" FontWeight="Black" Padding="34,14" Content="⚡ BOOST"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- Seite: Optimierungen -->
      <Grid x:Name="PageTweaks" Grid.Row="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <DockPanel Margin="0,0,0,10">
          <TextBlock Text="Optimierungen" FontSize="16" FontWeight="Bold" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnAll"  Style="{StaticResource Btn}" Content="Alle wählen" Padding="10,5" Margin="0,0,8,0"/>
            <Button x:Name="BtnNone" Style="{StaticResource Btn}" Content="Keine" Padding="10,5"/>
          </StackPanel>
        </DockPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="TweakPanel"/>
        </ScrollViewer>
      </Grid>

      <!-- Seite: Werkzeuge -->
      <ScrollViewer x:Name="PageTools" Grid.Row="1" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel>
          <TextBlock Text="Werkzeuge" FontSize="16" FontWeight="Bold" Margin="0,0,0,10"/>
          <UniformGrid Columns="2">
            <Border Style="{StaticResource Card}" Margin="0,0,5,10">
              <StackPanel>
                <TextBlock Text="🧹 Temporäre Dateien löschen" FontWeight="Bold" FontSize="14"/>
                <TextBlock Text="Leert Windows- und Benutzer-Temp. Dateien in Benutzung werden übersprungen." Foreground="#9AA3B5" TextWrapping="Wrap" Margin="0,4,0,10"/>
                <Button x:Name="BtnTemp" Style="{StaticResource Btn}" Content="Jetzt aufräumen" HorizontalAlignment="Left"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="5,0,0,10">
              <StackPanel>
                <TextBlock Text="🧠 Arbeitsspeicher freigeben" FontWeight="Bold" FontSize="14"/>
                <TextBlock Text="Gibt ungenutzten RAM aller Programme frei - am besten direkt vor dem Spielstart." Foreground="#9AA3B5" TextWrapping="Wrap" Margin="0,4,0,10"/>
                <Button x:Name="BtnRam" Style="{StaticResource Btn}" Content="RAM freigeben" HorizontalAlignment="Left"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="0,0,5,10">
              <StackPanel>
                <TextBlock Text="🌐 DNS-Cache leeren" FontWeight="Bold" FontSize="14"/>
                <TextBlock Text="Hilft bei Verbindungsproblemen zu Spielservern." Foreground="#9AA3B5" TextWrapping="Wrap" Margin="0,4,0,10"/>
                <Button x:Name="BtnDns" Style="{StaticResource Btn}" Content="DNS leeren" HorizontalAlignment="Left"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="5,0,0,10">
              <StackPanel>
                <TextBlock Text="🛡 Wiederherstellungspunkt" FontWeight="Bold" FontSize="14"/>
                <TextBlock Text="Zusätzliche Sicherheit: Windows-Wiederherstellungspunkt erstellen (dauert ca. 1 Minute)." Foreground="#9AA3B5" TextWrapping="Wrap" Margin="0,4,0,10"/>
                <Button x:Name="BtnRestorePoint" Style="{StaticResource Btn}" Content="Punkt erstellen" HorizontalAlignment="Left"/>
              </StackPanel>
            </Border>
          </UniformGrid>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="❌ Hintergrundprogramme schließen" FontWeight="Bold" FontSize="14"/>
              <TextBlock Text="Programme anhaken, die beim Zocken nicht laufen müssen (z. B. Browser, OneDrive). Nicht gespeicherte Daten gehen verloren!" Foreground="#9AA3B5" TextWrapping="Wrap" Margin="0,4,0,10"/>
              <ListBox x:Name="ProcList" Height="170" Background="#0F131B" BorderBrush="#232A38" Foreground="#E6E9F0"/>
              <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                <Button x:Name="BtnLoadProcs" Style="{StaticResource Btn}" Content="Liste aktualisieren" Margin="0,0,8,0"/>
                <Button x:Name="BtnKill" Style="{StaticResource Btn}" Background="#5A1A1F" BorderBrush="#7A2A30" Content="Ausgewählte schließen"/>
              </StackPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="🎮 Spiel auf hohe Priorität setzen" FontWeight="Bold" FontSize="14"/>
              <TextBlock Text="Spiel starten, Liste aktualisieren, Spiel auswählen. Mit 'dauerhaft' gilt es bei jedem Start des Spiels." Foreground="#9AA3B5" TextWrapping="Wrap" Margin="0,4,0,10"/>
              <ListBox x:Name="GameList" Height="150" Background="#0F131B" BorderBrush="#232A38" Foreground="#E6E9F0"/>
              <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                <Button x:Name="BtnLoadGames" Style="{StaticResource Btn}" Content="Liste aktualisieren" Margin="0,0,8,0"/>
                <Button x:Name="BtnPriority" Style="{StaticResource Btn}" Background="#0D3B66" BorderBrush="#1D5B96" Content="Priorität: Hoch" Margin="0,0,14,0"/>
                <CheckBox x:Name="ChkPermanent" Style="{StaticResource Switch}" VerticalAlignment="Center"/>
                <TextBlock Text="dauerhaft" VerticalAlignment="Center" Margin="8,0,0,0" Foreground="#9AA3B5"/>
              </StackPanel>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- Seite: Protokoll -->
      <Grid x:Name="PageLog" Grid.Row="1" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <TextBlock Text="Protokoll" FontSize="16" FontWeight="Bold" Margin="0,0,0,10"/>
        <TextBox x:Name="TxtLog" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                 Background="#0F131B" Foreground="#C9D1E0" BorderBrush="#232A38" FontFamily="Consolas" FontSize="12" Padding="8"/>
      </Grid>

      <TextBlock x:Name="TxtFooter" Grid.Row="2" Foreground="#6B7488" FontSize="11" Margin="0,10,0,0"
                 Text="Alle Änderungen werden gesichert und lassen sich mit 'Alles zurücksetzen' rückgängig machen."/>
    </Grid>
  </Grid>
</Window>
'@

try {
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    [System.Windows.MessageBox]::Show("Die Oberfläche konnte nicht geladen werden:`n$($_.Exception.Message)", 'FPS Booster', 'OK', 'Error') | Out-Null
    exit 1
}

$ui = @{}
foreach ($n in @('NavTweaks','NavTools','NavLog','TxtCpu','BarCpu','TxtRam','BarRam','TxtPlan','TxtSys','TxtStatus','TxtStatusSub',
                 'BtnRestore','BtnBoost','PageTweaks','PageTools','PageLog','BtnAll','BtnNone','TweakPanel','BtnTemp','BtnRam',
                 'BtnDns','BtnRestorePoint','ProcList','BtnLoadProcs','BtnKill','GameList','BtnLoadGames','BtnPriority',
                 'ChkPermanent','TxtLog','TxtFooter')) {
    $ui[$n] = $win.FindName($n)
}

$BrushGreen = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#00E676'))
$BrushGray  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#6B7488'))
$BrushText  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#E6E9F0'))
$BrushSub   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#9AA3B5'))

# ---------------------------------------------------------------
#  Hilfen fuer die Oberflaeche
# ---------------------------------------------------------------
function Invoke-DoEvents {
    try {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{ }, [System.Windows.Threading.DispatcherPriority]::Background)
    } catch { }
}

function Write-Log([string]$msg, [string]$level = 'INFO') {
    $line = '{0}  {1,-4} {2}' -f (Get-Date -Format 'HH:mm:ss'), $level, $msg
    try { Add-Content -Path $LogFile -Value ((Get-Date -Format 'yyyy-MM-dd ') + $line) -Encoding UTF8 -ErrorAction Stop } catch { }
    if ($ui -and $ui['TxtLog']) {
        $ui['TxtLog'].AppendText($line + [Environment]::NewLine)
        $ui['TxtLog'].ScrollToEnd()
    }
}

function Set-Status([string]$title, [string]$sub) {
    $ui['TxtStatus'].Text = $title
    $ui['TxtStatusSub'].Text = $sub
    Invoke-DoEvents
}

function Show-Page([string]$name) {
    $ui['PageTweaks'].Visibility = 'Collapsed'
    $ui['PageTools'].Visibility  = 'Collapsed'
    $ui['PageLog'].Visibility    = 'Collapsed'
    $ui[$name].Visibility = 'Visible'
    foreach ($b in @('NavTweaks','NavTools','NavLog')) { $ui[$b].Background = [System.Windows.Media.Brushes]::Transparent }
    $map = @{ PageTweaks = 'NavTweaks'; PageTools = 'NavTools'; PageLog = 'NavLog' }
    $ui[$map[$name]].Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#1B2130'))
}

# Tweak-Karten erzeugen
$script:TweakUI = @{}
$saved = $script:Settings['Selected']
foreach ($t in $Tweaks) {
    $card = New-Object System.Windows.Controls.Border
    $card.Style = $win.FindResource('Card')

    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::Auto
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2); $grid.ColumnDefinitions.Add($c3)

    $chk = New-Object System.Windows.Controls.CheckBox
    $chk.Style = $win.FindResource('Switch')
    $chk.VerticalAlignment = 'Center'
    $chk.Margin = '0,0,16,0'
    if ($saved) { $chk.IsChecked = (@($saved) -contains $t.Id) } else { $chk.IsChecked = $t.Default }
    [System.Windows.Controls.Grid]::SetColumn($chk, 0)

    $sp = New-Object System.Windows.Controls.StackPanel
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = $t.Title
    if ($t.Restart) { $title.Text += '   (Neustart)' }
    $title.FontSize = 14; $title.FontWeight = [System.Windows.FontWeights]::SemiBold; $title.Foreground = $BrushText
    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text = $t.Desc; $desc.TextWrapping = 'Wrap'; $desc.Foreground = $BrushSub; $desc.Margin = '0,3,0,0'
    $sp.Children.Add($title) | Out-Null
    $sp.Children.Add($desc) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($sp, 1)

    $st = New-Object System.Windows.Controls.TextBlock
    $st.VerticalAlignment = 'Center'; $st.Margin = '16,0,0,0'; $st.FontSize = 12; $st.FontWeight = [System.Windows.FontWeights]::Bold
    [System.Windows.Controls.Grid]::SetColumn($st, 2)

    $grid.Children.Add($chk) | Out-Null
    $grid.Children.Add($sp) | Out-Null
    $grid.Children.Add($st) | Out-Null
    $card.Child = $grid
    $ui['TweakPanel'].Children.Add($card) | Out-Null

    $script:TweakUI[$t.Id] = @{ Check = $chk; Status = $st }
}

function Update-TweakStatus {
    $active = 0
    foreach ($t in $Tweaks) {
        $st = $script:TweakUI[$t.Id].Status
        if ($t.Kind -eq 'reg' -and (-not $t.Reg -or @($t.Reg).Count -eq 0)) {
            $st.Text = 'n. v.'; $st.Foreground = $BrushGray; continue
        }
        if (Test-Tweak $t) { $st.Text = '● AKTIV'; $st.Foreground = $BrushGreen; $active++ }
        else { $st.Text = '○ aus'; $st.Foreground = $BrushGray }
    }
    $ui['TxtPlan'].Text = 'Energieplan: ' + (Get-ActiveSchemeName)
    return $active
}

# ---------------------------------------------------------------
#  Ereignisse
# ---------------------------------------------------------------
$ui['NavTweaks'].Add_Click({ Show-Page 'PageTweaks' })
$ui['NavTools'].Add_Click({ Show-Page 'PageTools' })
$ui['NavLog'].Add_Click({ Show-Page 'PageLog' })

$ui['BtnAll'].Add_Click({ foreach ($k in $script:TweakUI.Keys) { $script:TweakUI[$k].Check.IsChecked = $true } })
$ui['BtnNone'].Add_Click({ foreach ($k in $script:TweakUI.Keys) { $script:TweakUI[$k].Check.IsChecked = $false } })

$ui['BtnBoost'].Add_Click({
    $ui['BtnBoost'].IsEnabled = $false
    $ui['BtnRestore'].IsEnabled = $false
    try {
        Set-Status 'Boost läuft …' 'Optimierungen werden angewendet.'
        Write-Log '===== BOOST gestartet ====='
        $ok = 0; $fail = 0; $restart = $false; $selected = @()
        foreach ($t in $Tweaks) {
            if (-not $script:TweakUI[$t.Id].Check.IsChecked) { continue }
            $selected += $t.Id
            try {
                $r = Invoke-Tweak $t
                $ok++
                Write-Log "OK   $($t.Title) - $r"
                if ($t.Restart) { $restart = $true }
            } catch {
                $fail++
                Write-Log "FEHL $($t.Title) - $($_.Exception.Message)" 'WARN'
            }
            Invoke-DoEvents
        }
        $script:Settings['Selected'] = $selected
        Save-Settings

        try { $n = [FpsNative]::TrimAll([string[]]$GameSkip); Write-Log "OK   Arbeitsspeicher von $n Prozessen freigegeben" } catch { }
        if (Clear-Dns) { Write-Log 'OK   DNS-Cache geleert' }

        $active = Update-TweakStatus
        $sub = "$ok Optimierungen angewendet"
        if ($fail -gt 0) { $sub += ", $fail übersprungen (Details im Protokoll)" }
        if ($restart) { $sub += '. Für die volle Wirkung PC neu starten.' } else { $sub += '. Viel Spaß beim Zocken!' }
        Set-Status '⚡ Boost aktiv' $sub
        Write-Log "===== BOOST fertig: $ok ok, $fail übersprungen ====="
    } catch {
        Write-Log "Unerwarteter Fehler: $($_.Exception.Message)" 'ERR'
        Set-Status 'Fehler' $_.Exception.Message
    } finally {
        $ui['BtnBoost'].IsEnabled = $true
        $ui['BtnRestore'].IsEnabled = $true
    }
})

$ui['BtnRestore'].Add_Click({
    $ans = [System.Windows.MessageBox]::Show('Alle Änderungen von FPS Booster rückgängig machen und den ursprünglichen Zustand wiederherstellen?', 'Zurücksetzen', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    $ui['BtnBoost'].IsEnabled = $false
    $ui['BtnRestore'].IsEnabled = $false
    try {
        Set-Status 'Setze zurück …' 'Ursprüngliche Einstellungen werden wiederhergestellt.'
        $r = Restore-All
        Write-Log "Zurückgesetzt: $($r[0]) Werte wiederhergestellt, $($r[1]) Fehler"
        Update-TweakStatus | Out-Null
        Set-Status 'Zurückgesetzt' 'Alles ist wieder im Originalzustand. Ein Neustart übernimmt alle Werte vollständig.'
    } catch {
        Write-Log "Fehler beim Zurücksetzen: $($_.Exception.Message)" 'ERR'
    } finally {
        $ui['BtnBoost'].IsEnabled = $true
        $ui['BtnRestore'].IsEnabled = $true
    }
})

$ui['BtnTemp'].Add_Click({
    $ui['BtnTemp'].IsEnabled = $false
    try {
        Set-Status 'Räume auf …' 'Temporäre Dateien werden gelöscht.'
        $mb = Clear-TempFiles
        Write-Log "OK   Temp-Dateien gelöscht: $mb MB freigegeben"
        Set-Status 'Aufgeräumt' "$mb MB temporäre Dateien gelöscht."
    } catch { Write-Log "Temp: $($_.Exception.Message)" 'ERR' }
    finally { $ui['BtnTemp'].IsEnabled = $true }
})

$ui['BtnRam'].Add_Click({
    try {
        $before = [FpsNative]::Memory()[1]
        $n = [FpsNative]::TrimAll([string[]]$GameSkip)
        Start-Sleep -Milliseconds 300
        $after = [FpsNative]::Memory()[1]
        $freed = [math]::Max(0, [math]::Round(($before - $after) * 1024))
        Write-Log "OK   RAM freigegeben: ca. $freed MB ($n Prozesse)"
        Set-Status 'RAM freigegeben' "Ca. $freed MB Arbeitsspeicher freigegeben."
    } catch { Write-Log "RAM: $($_.Exception.Message)" 'ERR' }
})

$ui['BtnDns'].Add_Click({
    if (Clear-Dns) { Write-Log 'OK   DNS-Cache geleert'; Set-Status 'DNS geleert' 'Der DNS-Cache wurde geleert.' }
    else { Write-Log 'DNS-Cache konnte nicht geleert werden' 'WARN' }
})

$script:RestoreJob = $null
$ui['BtnRestorePoint'].Add_Click({
    if ($script:RestoreJob) { return }
    $ui['BtnRestorePoint'].IsEnabled = $false
    Set-Status 'Erstelle Wiederherstellungspunkt …' 'Das kann bis zu einer Minute dauern. Du kannst die App weiter benutzen.'
    Write-Log 'Wiederherstellungspunkt wird erstellt …'
    $script:RestoreJob = Start-Job -ScriptBlock {
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            Checkpoint-Computer -Description 'FPS Booster' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop -WarningAction Stop
            'OK'
        } catch { 'ERR: ' + $_.Exception.Message }
    }
})

function Load-ProcList {
    $ui['ProcList'].Items.Clear()
    foreach ($a in (Get-ClosableApps)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "{0}   ({1} Prozess(e), {2} MB)" -f $a.Name, $a.Count, $a.MB
        $cb.Tag = $a.Name
        $cb.Foreground = $BrushText
        $cb.Margin = '4,3'
        $ui['ProcList'].Items.Add($cb) | Out-Null
    }
    if ($ui['ProcList'].Items.Count -eq 0) { $ui['ProcList'].Items.Add('Keine schließbaren Programme gefunden.') | Out-Null }
}

function Load-GameList {
    $ui['GameList'].Items.Clear()
    foreach ($p in (Get-WindowedProcesses)) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $titleText = $p.MainWindowTitle
        if ($titleText.Length -gt 60) { $titleText = $titleText.Substring(0, 60) + '…' }
        $item.Content = "{0}.exe  -  {1}" -f $p.ProcessName, $titleText
        $item.Tag = $p.Id
        $item.Foreground = $BrushText
        $ui['GameList'].Items.Add($item) | Out-Null
    }
}

$ui['BtnLoadProcs'].Add_Click({ Load-ProcList })
$ui['BtnLoadGames'].Add_Click({ Load-GameList })

$ui['BtnKill'].Add_Click({
    $names = @()
    foreach ($it in $ui['ProcList'].Items) {
        if ($it -is [System.Windows.Controls.CheckBox] -and $it.IsChecked) { $names += [string]$it.Tag }
    }
    if ($names.Count -eq 0) { Set-Status 'Nichts ausgewählt' 'Hake zuerst die Programme an, die geschlossen werden sollen.'; return }
    $ans = [System.Windows.MessageBox]::Show("Diese Programme schließen?`n`n" + ($names -join "`n") + "`n`nNicht gespeicherte Daten gehen verloren.", 'Programme schließen', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }
    $closed = 0
    foreach ($n in $names) {
        try {
            Get-Process -Name $n -ErrorAction Stop | Stop-Process -Force -ErrorAction Stop
            $closed++
            Write-Log "OK   $n geschlossen"
        } catch { Write-Log "$n konnte nicht geschlossen werden: $($_.Exception.Message)" 'WARN' }
    }
    Set-Status 'Programme geschlossen' "$closed von $($names.Count) Programmen beendet."
    Load-ProcList
})

$ui['BtnPriority'].Add_Click({
    $sel = $ui['GameList'].SelectedItem
    if (-not $sel) { Set-Status 'Kein Spiel gewählt' 'Spiel starten, Liste aktualisieren und das Spiel anklicken.'; return }
    try {
        $p = Get-Process -Id ([int]$sel.Tag) -ErrorAction Stop
        $msg = ''
        try {
            $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
            $msg = "$($p.ProcessName) läuft jetzt mit hoher Priorität."
            Write-Log "OK   Priorität Hoch: $($p.ProcessName)"
        } catch {
            if (-not $ui['ChkPermanent'].IsChecked) { throw }
            $msg = 'Live-Setzen vom Anti-Cheat blockiert.'
            Write-Log "Priorität live blockiert ($($p.ProcessName)) - nutze dauerhafte Variante" 'WARN'
        }
        if ($ui['ChkPermanent'].IsChecked) {
            $path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$($p.ProcessName).exe\PerfOptions"
            Apply-RegEntries @( (New-Entry $path 'CpuPriorityClass' 3) )
            $msg += ' Gilt ab jetzt bei jedem Start.'
            Write-Log "OK   Dauerhafte Priorität für $($p.ProcessName).exe gespeichert"
        }
        Set-Status '🎮 Priorität gesetzt' $msg
    } catch {
        Write-Log "Priorität: $($_.Exception.Message)" 'ERR'
        Set-Status 'Hinweis' 'Der Anti-Cheat blockiert das direkte Setzen. Schalter "dauerhaft" an und erneut klicken - dann gilt es beim nächsten Spielstart.'
    }
})

# Live-Anzeige
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(1500)
$timer.Add_Tick({
    try {
        $cpu = [FpsNative]::CpuUsage()
        $ui['TxtCpu'].Text = 'CPU: {0:N0} %' -f $cpu
        $ui['BarCpu'].Value = $cpu
        $m = [FpsNative]::Memory()
        $ui['TxtRam'].Text = 'RAM: {0:N1} / {1:N1} GB' -f $m[1], $m[2]
        $ui['BarRam'].Value = $m[0]
    } catch { }

    if ($script:RestoreJob -and $script:RestoreJob.State -ne 'Running') {
        try {
            $res = (Receive-Job -Job $script:RestoreJob -ErrorAction SilentlyContinue | Out-String).Trim()
            Remove-Job -Job $script:RestoreJob -Force -ErrorAction SilentlyContinue
            if ($res -like 'OK*') {
                Write-Log 'OK   Wiederherstellungspunkt erstellt'
                Set-Status 'Gesichert' 'Wiederherstellungspunkt wurde erstellt.'
            } else {
                Write-Log "Wiederherstellungspunkt: $res" 'WARN'
                Set-Status 'Hinweis' 'Kein Punkt erstellt (Windows erlaubt nur einen pro 24 h oder Systemschutz ist aus). Details im Protokoll.'
            }
        } catch { }
        $script:RestoreJob = $null
        $ui['BtnRestorePoint'].IsEnabled = $true
    }
})

function Write-Crash([string]$text) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $text
    try { Add-Content -Path $CrashFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    try { Write-Log $text 'ERR' } catch { }
}

# Fehler in der Oberfläche abfangen statt die App zu beenden
$win.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    try { Write-Crash ('Abgefangener Fehler: ' + $e.Exception.ToString()) } catch { }
    $e.Handled = $true
})

$win.Add_Closing({
    try { Write-Log 'FPS Booster wurde normal geschlossen' } catch { }
    $timer.Stop()
    if ($script:RestoreJob) { Remove-Job -Job $script:RestoreJob -Force -ErrorAction SilentlyContinue }
})

# ---------------------------------------------------------------
#  Start
# ---------------------------------------------------------------
try {
    $cpuName = (Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).Name.Trim()
    $gpuName = ((Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -notmatch 'Basic|Remote|Virtual' } | Select-Object -ExpandProperty Name) -join ', ')
    $ui['TxtSys'].Text = "$cpuName`n$gpuName"
} catch { }

Show-Page 'PageTweaks'
[FpsNative]::CpuUsage() | Out-Null
$active = Update-TweakStatus
if ($active -gt 0) { Set-Status "$active Optimierungen aktiv" 'Du kannst weitere auswählen und erneut BOOST drücken oder alles zurücksetzen.' }
Write-Log ('FPS Booster gestartet (PowerShell ' + $PSVersionTable.PSVersion + ', PID ' + $PID + ')')
Load-ProcList
Load-GameList
$timer.Start()

try {
    $win.ShowDialog() | Out-Null
} catch {
    Write-Crash ('Absturz: ' + $_.Exception.ToString())
    [System.Windows.MessageBox]::Show("FPS Booster ist auf einen Fehler gestoßen.`nDetails stehen in: $CrashFile", 'FPS Booster', 'OK', 'Error') | Out-Null
}
