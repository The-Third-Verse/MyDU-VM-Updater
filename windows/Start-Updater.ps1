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
    [int]   $Width           = 1280,
    [int]   $Height          = 720
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
    if ($script:Share) {
        try {
            $dir = Join-Path $script:Share $ControlDir
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
            $script:LogLines | Set-Content -Path (Join-Path $dir 'guest.log') -ErrorAction SilentlyContinue
        } catch { }
    }
    Log "Shutting down."
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

function Install-MyDU {
    param([string]$Url, [string]$ShareRoot)
    $inst = Join-Path $env:TEMP 'dual-installer.exe'
    Log "Downloading MyDU installer: $Url"
    try   { Start-BitsTransfer -Source $Url -Destination $inst -ErrorAction Stop }
    catch { Invoke-WebRequest -Uri $Url -OutFile $inst -UseBasicParsing }
    # Inno Setup silent install straight to the shared game folder, so first-time
    # setup needs no wizard. $ShareRoot is a drive root ("Z:\") with no spaces, so
    # /DIR is passed unquoted (a trailing "\" inside quotes would escape the quote).
    # Inno rejects a bare drive root ("Z:\") as the install dir, so use a subfolder
    # of the share. The launcher is found afterwards by recursive search.
    $dir = Join-Path $ShareRoot 'DualUniverse'
    $log = Join-Path $ShareRoot "$ControlDir\mydu-install.log"
    Log "Installing MyDU silently to $dir"
    # /LANG avoids the "Select Setup Language" dialog, which Inno can still show in
    # silent mode with multiple languages. /LOG captures the install for diagnosis.
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

# Locate the launcher anywhere under the share (the installer puts it in a
# subfolder), returning its full path or $null.
function Find-Launcher {
    param([string]$Root, [string]$Exe)
    $f = Get-ChildItem -Path $Root -Filter $Exe -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

# --------------------------------------------------------------------------- #
try {
    Log "DU updater guest starting (tag '$ShareTag')."
    Set-Resolution -W $Width -H $Height

    $script:Share = Find-ShareDrive
    if (-not $script:Share) { Log "Game share never mounted (VirtioFsSvc?). Aborting."; return }
    Log "Game share: $script:Share"

    $cfg      = Read-Command -Path (Join-Path $script:Share "$ControlDir\command")
    $exe      = $cfg['LAUNCHER_EXE']
    $launcher = Find-Launcher $script:Share $exe
    Log ("Command: ACTION={0} LAUNCHER_EXE={1}" -f $cfg['ACTION'], $exe)

    if ($cfg['ACTION'] -eq 'install' -or -not $launcher) {
        Install-MyDU -Url $cfg['INSTALLER_URL'] -ShareRoot $script:Share
        $launcher = Find-Launcher $script:Share $exe
    }

    if ($launcher) {
        Log "Launching $launcher"
        $p = Start-Process -FilePath $launcher -WorkingDirectory (Split-Path $launcher -Parent) -PassThru
        $p.WaitForExit()
        Log "Launcher exited (code $($p.ExitCode))."
    } else {
        Log "Launcher still not present after install; nothing to run."
    }
}
catch {
    Log ("ERROR: " + $_.Exception.Message)
}
finally {
    Stop-Guest
}
