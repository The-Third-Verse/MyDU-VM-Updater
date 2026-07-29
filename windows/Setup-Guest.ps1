<#
.SYNOPSIS
    One-time provisioning of the Dual Universe updater Windows guest.

.DESCRIPTION
    Run this ONCE, as Administrator, after installing Windows and while the
    VirtIO-win CD is still attached (i.e. before `create-vm.sh --finalize`).
    It:
      * creates a restricted local user and enables auto-login for it,
      * installs WinFsp + the VirtIO guest tools (viofs, NetKVM, balloon, qemu-ga)
        and starts VirtioFsSvc so the shared game folder appears as a drive,
      * installs the Microsoft Edge WebView2 runtime (needed by the DU launcher),
      * installs Start-Updater.ps1 and registers it to run at that user's login.

    After it finishes: shut Windows down, then run `create-vm.sh --finalize` on
    the host. From then on `du-updater` drives everything automatically.

.NOTES
    Downloads (WinFsp, WebView2) need working internet in the guest - the VM uses
    an e1000e NIC so this works out of the box once Windows is at the desktop.
#>
[CmdletBinding()]
param(
    [string]$UserName    = "duupdater",
    [string]$Password    = "DualUniverse!1",
    [string]$ShareTag    = "dushare",
    [string]$InstallDir  = "$env:ProgramData\du-updater",
    [string]$WinFspUrl   = "https://github.com/winfsp/winfsp/releases/download/v2.0/winfsp-2.0.23075.msi",
    [string]$WebView2Url = "https://go.microsoft.com/fwlink/p/?LinkId=2124703",
    [string]$VCRedistUrl = "https://aka.ms/vc14/vc_redist.x64.exe",
    # Kiosk (default): replace explorer.exe with the boot script for the restricted
    # user, so only the launcher shows - no desktop, no taskbar. -NoKiosk keeps the
    # normal desktop and runs the boot script via a logon scheduled task instead.
    [switch]$NoKiosk,
    # -DeepSlim adds the slow WinSxS /ResetBase + CompactOS steps (~3-4 GB more but
    # 15-25 min). Off by default so provisioning stays fast.
    [switch]$DeepSlim
)

$ErrorActionPreference = "Stop"

function Log  { param([string]$m) Write-Host ("==> " + $m) -ForegroundColor Cyan }
function Warn { param([string]$m) Write-Host ("warning: " + $m) -ForegroundColor Yellow }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }
}

# Locate the attached VirtIO-win CD (has virtio-win-guest-tools.exe / viofs).
function Get-VirtioDrive {
    foreach ($v in Get-Volume | Where-Object { $_.DriveLetter }) {
        $root = "$($v.DriveLetter):\"
        if (Test-Path (Join-Path $root 'virtio-win-guest-tools.exe')) { return $root }
    }
    foreach ($v in Get-Volume | Where-Object { $_.DriveLetter }) {
        $root = "$($v.DriveLetter):\"
        if (Test-Path (Join-Path $root 'viofs')) { return $root }
    }
    return $null
}

function Get-File {
    param([string]$Url, [string]$OutFile)
    Log "Downloading $Url"
    # Faster than Invoke-WebRequest for large files; fall back if BITS is off.
    try   { Start-BitsTransfer -Source $Url -Destination $OutFile -ErrorAction Stop }
    catch { Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing }
}

function New-RestrictedUser {
    $sec = ConvertTo-SecureString $Password -AsPlainText -Force
    if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
        Log "Creating runtime user '$UserName'"
        New-LocalUser -Name $UserName -Password $sec -FullName "DU Updater" `
            -Description "Dual Universe updater user" `
            -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
    } else {
        Log "User '$UserName' already exists"
    }
    # The MyDU installer requires elevation, so the runtime user must be an
    # administrator; combined with Set-SilentElevation this avoids UAC prompts
    # in the hidden appliance. (Disposable, isolated VM - acceptable trade-off.)
    Add-LocalGroupMember -Group "Administrators" -Member $UserName -ErrorAction SilentlyContinue
}

# Auto-elevate admin apps without a UAC prompt, so the launcher/installer never
# blocks the hidden VM waiting for a click or password.
function Set-SilentElevation {
    Log "Disabling UAC prompts (silent elevation) for the appliance"
    $sys = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    # 0 = admins elevate without any prompt; keep installer detection on so the
    # MyDU installer still auto-elevates.
    Set-ItemProperty $sys ConsentPromptBehaviorAdmin 0
    Set-ItemProperty $sys PromptOnSecureDesktop 0
}

function Set-AutoLogon {
    Log "Enabling auto-login for '$UserName'"
    $win = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty $win AutoAdminLogon   "1"
    Set-ItemProperty $win DefaultUserName   $UserName
    Set-ItemProperty $win DefaultPassword   $Password           # plaintext: OK for a disposable VM
    Set-ItemProperty $win DefaultDomainName $env:COMPUTERNAME
    Remove-ItemProperty $win -Name AutoLogonCount -ErrorAction SilentlyContinue
}

function Install-WinFsp {
    # Note: reference the "(x86)" path via literal text, not $env:ProgramFiles(x86)
    # - a variable immediately followed by "(" is a PowerShell parse error.
    if (Test-Path "$env:SystemDrive\Program Files (x86)\WinFsp") { Log "WinFsp already installed"; return }
    $msi = Join-Path $env:TEMP "winfsp.msi"
    Get-File -Url $WinFspUrl -OutFile $msi
    Log "Installing WinFsp"
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
}

function Install-VirtioGuestTools {
    param([string]$VirtioDrive)
    if (-not $VirtioDrive) { Warn "VirtIO-win CD not found; skipping guest tools (share/NIC drivers may be missing)"; return }
    $gt = Join-Path $VirtioDrive 'virtio-win-guest-tools.exe'
    Log "Installing VirtIO guest tools from $gt"
    Start-Process $gt -ArgumentList "/install /passive /norestart" -Wait
}

function Enable-VirtioFs {
    $svc = Get-Service -Name VirtioFsSvc -ErrorAction SilentlyContinue
    if ($svc) {
        Log "Enabling and starting VirtioFsSvc (game share)"
        Set-Service -Name VirtioFsSvc -StartupType Automatic
        Start-Service -Name VirtioFsSvc -ErrorAction SilentlyContinue
    } else {
        Warn "VirtioFsSvc not found - the VirtIO-FS share won't mount. Ensure the guest tools installed viofs, and WinFsp is present."
    }
}

function Install-VCRedist {
    # The DU launcher's own VC++ install step fails on some Windows builds (notably
    # Windows 11), so pre-install the x64 runtime. /quiet auto-accepts the licence.
    $exe = Join-Path $env:TEMP "vc_redist.x64.exe"
    Get-File -Url $VCRedistUrl -OutFile $exe
    Log "Installing Visual C++ Redistributable (x64)"
    Start-Process $exe -ArgumentList '/install','/quiet','/norestart' -Wait
}

function Install-WebView2 {
    # Skip if an Evergreen runtime is already registered.
    $key = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    if (Test-Path $key) { Log "WebView2 runtime already installed"; return }
    $exe = Join-Path $env:TEMP "MicrosoftEdgeWebView2Setup.exe"
    Get-File -Url $WebView2Url -OutFile $exe
    Log "Installing WebView2 runtime"
    Start-Process $exe -ArgumentList "/silent /install" -Wait
}

function Deploy-BootScript {
    Log "Installing boot script to $InstallDir"
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'Start-Updater.ps1') (Join-Path $InstallDir 'Start-Updater.ps1') -Force
}

# The command Windows runs as the shell / logon task.
function Get-BootCommand {
    $boot = Join-Path $InstallDir 'Start-Updater.ps1'
    return 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $boot + '" -ShareTag "' + $ShareTag + '"'
}

# Non-kiosk mode: run the boot script at logon while keeping the normal desktop.
function Install-BootTask {
    Log "Registering logon task 'DU-Updater' for '$UserName'"
    $boot      = Join-Path $InstallDir 'Start-Updater.ps1'
    $arg       = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$boot`" -ShareTag `"$ShareTag`""
    $action    = New-ScheduledTaskAction    -Execute 'powershell.exe' -Argument $arg
    $trigger   = New-ScheduledTaskTrigger   -AtLogOn -User $UserName
    $principal = New-ScheduledTaskPrincipal -UserId $UserName -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName 'DU-Updater' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
}

# Write the per-user shell override into an offline user hive.
function Set-ShellInHive {
    param([string]$HivePath, [string]$Shell)
    if (-not (Test-Path $HivePath)) { return }
    $tag = "DUKiosk"
    $sub = "Software\Microsoft\Windows NT\CurrentVersion\Winlogon"
    try {
        reg load "HKU\$tag" "$HivePath" | Out-Null
        $key = "Registry::HKEY_USERS\$tag\$sub"
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -Path $key -Name Shell -Value $Shell -PropertyType String -Force | Out-Null
    } finally {
        [gc]::Collect(); Start-Sleep -Milliseconds 200
        reg unload "HKU\$tag" | Out-Null
    }
}

# Kiosk mode: replace explorer.exe with the boot script for the restricted user.
# Applied to the Default profile (so the restricted user's future profile inherits
# it) and to that user's hive if it already exists. Other accounts (e.g. an admin
# for debugging) keep the normal desktop.
function Set-KioskShell {
    Log "Enabling kiosk shell for '$UserName' (no desktop; launcher only)"
    $cmd = Get-BootCommand
    Set-ShellInHive -HivePath "$env:SystemDrive\Users\Default\NTUSER.DAT" -Shell $cmd
    Set-ShellInHive -HivePath "$env:SystemDrive\Users\$UserName\NTUSER.DAT" -Shell $cmd
}

# Disable services this launcher-only VM never needs, for a faster boot and less
# background CPU. Safe on a disposable, isolated guest.
function Disable-Services {
    Log "Disabling unnecessary services (faster boot)..."
    $svcs = 'SysMain','WSearch','wuauserv','DiagTrack','dmwappushservice','Spooler','WerSvc','MapsBroker'
    foreach ($s in $svcs) {
        Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
        Set-Service  -Name $s -StartupType Disabled -ErrorAction SilentlyContinue
    }
}

# Reclaim disk space Windows doesn't need for a launcher-only, disposable VM.
# Runs before the snapshot so every build stays lean. Each step is best-effort.
function Optimize-DiskSpace {
    Log "Slimming Windows (reclaiming disk space)..."
    # No hibernation file (~1.6 GB).
    cmd.exe /c "powercfg.exe /h off" 2>$null
    # Reclaim the ~7 GB Windows Update reserved storage (we never update). Fast.
    try { Dism.exe /Online /Set-ReservedStorageState /State:Disabled | Out-Null } catch {}
    # Clear Windows Update cache and installer temp files. Fast.
    foreach ($p in "$env:WINDIR\SoftwareDistribution\Download\*", "$env:TEMP\*", "$env:WINDIR\Temp\*") {
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Slow extras (~3-4 GB, 15-25 min) - only with -DeepSlim.
    if ($DeepSlim) {
        Log "  deep slim: WinSxS /ResetBase + CompactOS (slow)..."
        try { Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null } catch {}
        try { compact.exe /CompactOS:always | Out-Null } catch {}
    }
    # TRIM so the freed blocks are released back to the (discard='unmap') qcow2,
    # actually shrinking the disk image rather than just NTFS free space.
    try { Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue | Out-Null } catch {}
}

# --------------------------------------------------------------------------- #
Assert-Admin
Log "Provisioning Dual Universe updater guest"

$virtio = Get-VirtioDrive
if ($virtio) { Log "VirtIO-win CD: $virtio" } else { Warn "VirtIO-win CD not detected" }

New-RestrictedUser
Set-SilentElevation
Set-AutoLogon
Install-WinFsp
Install-VirtioGuestTools -VirtioDrive $virtio
Enable-VirtioFs
Install-WebView2
Install-VCRedist
Deploy-BootScript
if ($NoKiosk) { Install-BootTask } else { Set-KioskShell }
Disable-Services
Optimize-DiskSpace

Write-Host ""
Log "Guest provisioning complete."
Write-Host @"

Next steps:
  1. Shut Windows down completely (Start > Power > Shut down).
  2. On the Linux host, finalize the VM:
         scripts/create-vm.sh --finalize
  3. From then on just run:  du-updater

The first time the launcher is missing from the game folder, du-updater will
offer to install MyDU; the installer window appears so you can point it at the
shared game drive (the one that contains a \.du-updater folder).
"@ -ForegroundColor Green
