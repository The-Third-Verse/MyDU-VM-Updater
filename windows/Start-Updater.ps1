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
    [int]   $MountTimeoutSec = 120
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
    Log "Running MyDU installer (choose the shared game drive: $ShareRoot)"
    # Interactive: the first-time install lets the user point MyDU at the share.
    Start-Process -FilePath $inst -Wait
}

# --------------------------------------------------------------------------- #
try {
    Log "DU updater guest starting (tag '$ShareTag')."

    $script:Share = Find-ShareDrive
    if (-not $script:Share) { Log "Game share never mounted (VirtioFsSvc?). Aborting."; return }
    Log "Game share: $script:Share"

    $cfg      = Read-Command -Path (Join-Path $script:Share "$ControlDir\command")
    $launcher = Join-Path $script:Share $cfg['LAUNCHER_EXE']
    Log ("Command: ACTION={0} LAUNCHER_EXE={1}" -f $cfg['ACTION'], $cfg['LAUNCHER_EXE'])

    if ($cfg['ACTION'] -eq 'install' -or -not (Test-Path $launcher)) {
        Install-MyDU -Url $cfg['INSTALLER_URL'] -ShareRoot $script:Share
    }

    if (Test-Path $launcher) {
        Log "Launching $launcher"
        $p = Start-Process -FilePath $launcher -WorkingDirectory $script:Share -PassThru
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
