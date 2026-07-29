<#
.SYNOPSIS
    Per-login boot script for the Dual Universe updater guest.

.DESCRIPTION
    Registered by Setup-Guest.ps1 to run at the restricted user's login. It:
      1. waits for the VirtIO-FS game share to mount,
      2. reads the command file du-updater wrote to <share>\.du-updater\command,
      3. installs MyDU from the official installer if requested / the launcher is
         missing, then
      4. launches the DU launcher and waits for it to close, and
      5. shuts Windows down - always - so the VM powers off and du-updater exits.

    The whole run is wrapped so that ANY failure still shuts the VM down; the
    launcher window closing is the normal signal to power off.
#>
[CmdletBinding()]
param(
    [string]$ShareTag        = "dushare",
    [string]$ControlDir      = ".du-updater",
    [string]$DefaultInstaller = "https://installer-prod.dualthegame.com/mydu/dual-installer.exe",
    [string]$DefaultLauncher  = "dual-launcher.exe",
    [int]   $MountTimeoutSec = 120,
    [int]   $Width           = 1440,
    [int]   $Height          = 900
)

$ErrorActionPreference = "Stop"
$script:LogLines = @()
$script:Share    = $null

function Log {
    param([string]$m)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
    $script:LogLines += $line
    Write-Host $line
}

# Flush the run log to the share so the Linux side can read it, then power off.
function Stop-Guest {
    Log "Shutting down."
    if ($script:Share) {
        try {
            $dir = Join-Path $script:Share $ControlDir
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
            $script:LogLines | Set-Content -Path (Join-Path $dir 'guest.log') -ErrorAction SilentlyContinue
        } catch { }
    }
    Start-Process shutdown.exe -ArgumentList "/s /t 0" -ErrorAction SilentlyContinue
}

# Find the drive whose root contains our control folder - robust to whatever
# letter VirtioFsSvc assigns.
function Find-ShareDrive {
    for ($i = 0; $i -lt $MountTimeoutSec; $i++) {
        foreach ($d in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
            if (Test-Path (Join-Path $d.Root "$ControlDir\command")) { return $d.Root }
        }
        Start-Sleep -Seconds 1
    }
    return $null
}

function Read-Command {
    param([string]$Path)
    $cfg = @{ ACTION = "run"; INSTALLER_URL = $DefaultInstaller; LAUNCHER_EXE = $DefaultLauncher }
    foreach ($line in Get-Content -Path $Path) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.+?)\s*$') { $cfg[$matches[1].ToUpper()] = $matches[2] }
    }
    return $cfg
}

# The DUGAME NTFS disk (Windows 11), or $null (Windows 10 uses the share directly).
function Find-GameDisk {
    $v = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq 'DUGAME' -and $_.DriveLetter } | Select-Object -First 1
    if ($v) { return ($v.DriveLetter + ':\') }
    return $null
}

# Windows 11: mirror the game from the NTFS disk to the VirtIO-FS share so the
# files land on Linux (where they play), the same place Windows 10 puts them.
function Mirror-ToShare {
    param([string]$GameRoot, [string]$ShareRoot)
    $src = Join-Path $GameRoot 'DualUniverse'
    $dst = Join-Path $ShareRoot 'DualUniverse'
    if (-not (Test-Path $src)) { return }
    Log "Mirroring game to the share for Linux: $src -> $dst"
    robocopy $src $dst /MIR /NFL /NDL /NP /R:1 /W:1 | Out-Null   # robocopy exit 0-7 = success
    Log "Mirror complete."
}

function Install-MyDU {
    param([string]$Url, [string]$Root)
    $inst = Join-Path $env:TEMP 'dual-installer.exe'
    Log "Downloading MyDU installer: $Url"
    try   { Start-BitsTransfer -Source $Url -Destination $inst -ErrorAction Stop }
    catch { Invoke-WebRequest -Uri $Url -OutFile $inst -UseBasicParsing }
    # Inno Setup silent install. Inno rejects a bare drive root, so use a subfolder;
    # the launcher is found afterwards by recursive search. The install log always
    # goes to the share's control folder (readable from Linux).
    $dir = Join-Path $Root 'DualUniverse'
    $log = Join-Path $script:Share "$ControlDir\mydu-install.log"
    Log "Installing MyDU silently to $dir"
    Start-Process -FilePath $inst -Wait -ArgumentList `
        '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOCANCEL','/LANG=english',"/DIR=$dir","/LOG=$log"
}

# Set a usable screen resolution. In kiosk mode explorer.exe is gone, so the
# SPICE agent's auto-resize doesn't run and the guest can be stuck at a tiny
# default where the launcher window doesn't fit. Best-effort only.
function Set-Resolution {
    param([int]$W, [int]$H)
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DU_Display {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
        public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public uint dmFields;
        public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
        public ushort dmLogPixels;
        public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2;
        public uint dmPanningWidth, dmPanningHeight;
    }
    [DllImport("user32.dll")] public static extern int EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll")] public static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
}
'@ -ErrorAction Stop
        $dm = New-Object DU_Display+DEVMODE
        if ([DU_Display]::EnumDisplaySettings($null, -1, [ref]$dm) -ne 0) {
            $dm.dmPelsWidth = $W; $dm.dmPelsHeight = $H
            $dm.dmFields = 0x80000 -bor 0x100000   # DM_PELSWIDTH | DM_PELSHEIGHT
            [void][DU_Display]::ChangeDisplaySettings([ref]$dm, 0)
            Log "Set resolution to ${W}x${H}"
        }
    } catch { Log "Resolution set skipped: $($_.Exception.Message)" }
}

# Best-effort window manager for the launcher: the DU launcher pops a "Low Memory"
# dialog FIRST (so a naive maximize hits that popup), and that dialog also blocks a
# hands-off run. So we enumerate the launcher's visible windows, auto-dismiss the
# "Low Memory" popup (Enter = its default "Continue"/OK button), and maximize the
# real main window.
function Manage-LauncherWindow {
    param([string]$Name)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        Add-Type -TypeDefinition @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class DUWinMgr {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    public static List<IntPtr> WindowsOf(uint pid) {
        var list = new List<IntPtr>();
        EnumWindows((h,l)=>{ uint p; GetWindowThreadProcessId(h, out p); if(p==pid && IsWindowVisible(h)) list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }
    public static string Title(IntPtr h){ var sb=new StringBuilder(256); GetWindowText(h, sb, 256); return sb.ToString(); }
}
'@ -ErrorAction SilentlyContinue

        $deadline = (Get-Date).AddSeconds(90)
        $maxed = $false
        while ((Get-Date) -lt $deadline -and -not $maxed) {
            foreach ($p in @(Get-Process -Name $Name -ErrorAction SilentlyContinue)) {
                foreach ($h in [DUWinMgr]::WindowsOf([uint32]$p.Id)) {
                    $t = [DUWinMgr]::Title($h)
                    if ($t -match '(?i)low memory') {
                        [void][DUWinMgr]::SetForegroundWindow($h)
                        Start-Sleep -Milliseconds 200
                        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
                        Log "Dismissed Low Memory dialog"
                    } elseif ($t.Trim().Length -gt 0) {
                        [void][DUWinMgr]::ShowWindow($h, 3)   # 3 = SW_MAXIMIZE
                        Log "Maximized launcher window: $t"
                        $maxed = $true
                    }
                }
            }
            Start-Sleep -Milliseconds 500
        }
    } catch { Log "Window management skipped: $($_.Exception.Message)" }
}

# Locate the launcher anywhere under the share (the installer puts it in a
# subfolder), returning its full path or $null.
function Find-Launcher {
    param([string]$Root, [string]$Exe)
    $f = Get-ChildItem -Path $Root -Filter $Exe -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

# Wait until the launcher session is genuinely over. We can't just wait on the one
# process we started: the DU launcher spawns a SEPARATE update daemon (same exe name)
# that downloads/extracts the game, and its UI process can exit early and relaunch
# under a watchdog (observed on Windows 11 - the first UI instance dies with a .NET
# exception 0xE0434352 while the daemon keeps updating in the background). Waiting on
# that single PID returns mid-update, so we'd mirror an empty game folder and power
# off while the download is still running. Instead we wait until NO process of this
# name has existed for a sustained grace window - i.e. the whole launcher tree
# (UI + update daemon) is gone, which is the real "user closed it / update finished"
# signal, the same thing that ends a Windows 10 session.
function Wait-LauncherClosed {
    param([string]$Name, [int]$GraceSec = 45, [int]$StartupSec = 90)
    # Let the launcher (or a watchdog relaunch) come up before "no process" counts as closed.
    $deadline = (Get-Date).AddSeconds($StartupSec)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-Process -Name $Name -ErrorAction SilentlyContinue).Count -gt 0) { break }
        Start-Sleep -Seconds 2
    }
    # Now wait for the whole tree to stay gone for GraceSec (rides quick crash/relaunch gaps).
    $goneSince = $null
    while ($true) {
        if (@(Get-Process -Name $Name -ErrorAction SilentlyContinue).Count -gt 0) {
            $goneSince = $null
        } else {
            if ($null -eq $goneSince) { $goneSince = Get-Date }
            elseif (((Get-Date) - $goneSince).TotalSeconds -ge $GraceSec) { return }
        }
        Start-Sleep -Seconds 3
    }
}

# --------------------------------------------------------------------------- #
try {
    Log "DU updater guest starting (tag '$ShareTag')."
    Set-Resolution -W $Width -H $Height

    $script:Share = Find-ShareDrive
    if (-not $script:Share) { Log "Game share never mounted (VirtioFsSvc?). Aborting."; return }
    Log "Game share: $script:Share"

    # Windows 11: the game lives on a local NTFS disk (the updater needs a real
    # NTFS volume). Windows 10 uses the share directly.
    $gameDisk = Find-GameDisk
    $gameRoot = if ($gameDisk) { $gameDisk } else { $script:Share }
    if ($gameDisk) { Log "Game disk (NTFS): $gameRoot; share is the Linux export target." }

    $cfg      = Read-Command -Path (Join-Path $script:Share "$ControlDir\command")
    $exe      = $cfg['LAUNCHER_EXE']
    $launcher = Find-Launcher $gameRoot $exe
    Log ("Command: ACTION={0} LAUNCHER_EXE={1}" -f $cfg['ACTION'], $exe)

    # Inspection mode: give a normal desktop instead of the launcher, and stay
    # alive so the session persists. The user shuts Windows down manually.
    if ($cfg['ACTION'] -eq 'desktop') {
        Log "Desktop mode: launching Explorer. Shut Windows down (Start > Power) when done."
        Start-Process explorer.exe
        while ($true) { Start-Sleep -Seconds 3600 }
    }

    if ($cfg['ACTION'] -eq 'install' -or -not $launcher) {
        Install-MyDU -Url $cfg['INSTALLER_URL'] -Root $gameRoot
        $launcher = Find-Launcher $gameRoot $exe
    }

    if ($launcher) {
        Log "Launching $launcher"
        $exeBase = [IO.Path]::GetFileNameWithoutExtension($launcher)
        Start-Process -FilePath $launcher -WorkingDirectory (Split-Path $launcher -Parent) -WindowStyle Maximized | Out-Null
        Manage-LauncherWindow -Name $exeBase
        # Wait for the full launcher tree (UI + background update daemon) to close,
        # not just the first process - the update runs in a detached daemon.
        Wait-LauncherClosed -Name $exeBase
        Log "Launcher closed (update session finished)."
    } else {
        Log "Launcher still not present after install; nothing to run."
    }

    # Windows 11: export the updated game to the share so Linux can play it.
    if ($gameDisk) { Mirror-ToShare -GameRoot $gameRoot -ShareRoot $script:Share }
}
catch {
    Log ("ERROR: " + $_.Exception.Message)
}
finally {
    Stop-Guest
}
