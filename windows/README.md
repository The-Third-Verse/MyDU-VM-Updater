# Windows guest setup

These scripts turn a freshly installed Windows guest into the disposable Dual
Universe updater runtime. Run them **once**, inside the VM, after Windows is
installed and while the VirtIO-win CD is still attached (before
`create-vm.sh --finalize`).

| Script | When | What it does |
|--------|------|--------------|
| `Setup-Guest.ps1` | once, as Administrator | restricted auto-login user, WinFsp + VirtIO guest tools (viofs/NetKVM/balloon/qemu-ga), VirtioFsSvc, WebView2, and registers the boot task |
| `Start-Updater.ps1` | every login (auto) | mounts share → reads the command file → installs/updates MyDU → runs the launcher → shuts down |
| `autounattend.xml.in` | build-time template | rendered by `create-vm.sh --unattended` onto a config CD; drives a hands-off Windows install that runs `Setup-Guest.ps1` automatically at first logon |

**Two ways to provision.** Run `Setup-Guest.ps1` by hand (below), or let
`create-vm.sh --unattended` do the whole install + provisioning automatically
(it puts these scripts on a config CD and calls `Setup-Guest.ps1` for you).

## How the two sides talk

`du-updater` (Linux) writes a command file into the shared game folder before
starting the VM:

```
<game-dir>/.du-updater/command      # ACTION=run|install, INSTALLER_URL, LAUNCHER_EXE
```

Inside the guest the share appears as a drive (via VirtioFsSvc); `Start-Updater.ps1`
finds it by looking for the `\.du-updater\command` marker, acts on `ACTION`, then
writes `\.du-updater\guest.log` back so you can read the run log from Linux.

## Running the setup

1. Get the scripts into the guest. Easiest: they're already on the shared game
   drive if you copied the repo there, or paste them in via the SPICE clipboard.
2. Open **PowerShell as Administrator** and allow the scripts for this session:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   .\Setup-Guest.ps1
   ```
   Optional parameters: `-UserName`, `-Password`, `-ShareTag` (must match the
   host's `dushare`).
3. When it finishes, **shut Windows down**, then on the host run:
   ```bash
   scripts/create-vm.sh --finalize
   ```

## First launch / installing MyDU

When `dual-launcher.exe` isn't in the game folder yet, `du-updater` sets
`ACTION=install` and the guest runs the official installer **interactively** so
you can point MyDU at the **shared game drive** (the one containing a
`\.du-updater` folder). After that the launcher lives in the share and every
later run is fully automatic (`ACTION=run`).

## Assumptions / tuning points

- **VirtIO-FS needs WinFsp + viofs.** `Setup-Guest.ps1` installs WinFsp from the
  official release and the viofs driver via the guest tools, then starts
  `VirtioFsSvc`. If the share doesn't appear, check that service.
- **Installer flags.** The MyDU installer is launched interactively (no silent
  switches assumed). If a silent/target-path flag exists, wire it into
  `Install-MyDU` in `Start-Updater.ps1`.
- **Auto-shutdown.** `Start-Updater.ps1` shuts the VM down in a `finally` block,
  so the VM always powers off when the launcher closes (or on any error) — which
  is how `du-updater` knows the session is done.
- **Auto-login password** is stored in the registry in plaintext (standard for
  Windows auto-login). Acceptable here because the VM is disposable and isolated;
  change `-Password` if you prefer.
