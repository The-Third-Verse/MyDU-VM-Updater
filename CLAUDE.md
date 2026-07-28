# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current State

Implementation in progress. `doc/Dual_Universe_Linux_Updater_VM_Proposal.md` holds the full spec (the `doc/` folder is git-ignored). Built so far:

- `bin/du-updater` — the Linux CLI launcher (VM lifecycle, game-dir config, access check, run-vs-install decision).
- `libvirt/du-updater.xml.in` — envsubst template for the runtime libvirt domain (authoritative runtime definition).
- `scripts/create-vm.sh` — provisions the VM (disk, VirtIO ISO, define domain, attach Windows install media) and `--finalize` (eject media + clean snapshot). Windows 10 (BIOS) by default; `--win11` fills the template's firmware slots with UEFI + Secure Boot + emulated TPM 2.0 (needs `swtpm` + OVMF) and bumps defaults to 6 GB / 64 G.

Still to build: the Windows guest setup PowerShell scripts, and a `.desktop` shortcut.

## Guest control-file contract

`du-updater` writes `<game-dir>/.du-updater/command` (KEY=VALUE) for the Windows guest to read on boot:
- `ACTION=run|install` — run the launcher, or install MyDU first then run.
- `INSTALLER_URL` — official DU installer (`https://installer-prod.dualthegame.com/mydu/dual-installer.exe`); the guest also needs WebView2.
- `LAUNCHER_EXE` — launcher exe expected in the game dir (default `dual-launcher.exe`).

The game directory is shared into the guest via VirtIO-FS tag `dushare`, so it's visible identically on both sides (the launcher checks/writes it directly on the Linux side). Session-mode VirtIO-FS exposes files as the invoking user, which is why `du-updater` runs an access (read+write) check before launch.

## Project Goal

Build a Linux updater for **Dual Universe** that runs the official Windows game launcher inside a hidden Windows VM, so Linux users can update the game (via the Windows-only launcher, which depends on Microsoft WebView2) while playing the native Linux client. The VM must be invisible to the user and behave like a native Linux app invoked as `du-updater`.

## Architecture (as specified)

The flow is a single-purpose VM lifecycle wrapped by a Linux launcher script:

```
du-updater (Linux script)
  → start QEMU/KVM VM via libvirt
  → open SPICE window (launcher only, no Windows desktop)
  → Windows auto-logs-in a restricted user, auto-starts the DU launcher
  → launcher updates the shared game directory
  → on launcher exit: `shutdown.exe /s /t 0` inside guest
  → VM stops, SPICE window closes, du-updater exits
```

Key design decisions driven by the proposal:

- **No WebView2-under-Wine.** WebView2 runs natively inside the Windows guest instead.
- **No GPU passthrough.** Use VirtIO GPU + SPICE display. Target guest is Windows 10 x64; VM sized at 2 vCPU / 4 GB RAM / 32 GB dynamic qcow2.
- **Game files live on the Linux side, not in the VM.** Share the Linux game directory into the guest via **VirtIO-FS** (fallback: SMB share; last resort if NTFS is required: a dedicated virtual disk). The Windows VM should not permanently store the game.
- **Windows is a disposable runtime.** Nice-to-have: restore a clean VM snapshot before each launch and auto-recover a corrupted VM.

## Expected Deliverables

- Linux installer + VM creation scripts
- libvirt XML domain definition
- Windows setup PowerShell scripts (auto-login, restricted user, WebView2 install, DU launcher install, auto-start-on-login, auto-shutdown-on-launcher-exit)
- Desktop launcher (`.desktop` shortcut) and CLI launcher (`du-updater`)
- Documentation and build instructions

## Constraints

- **Do not redistribute Windows.** The user must supply their own official Windows ISO. Keep licensing compliant.
- Minimize the amount of Windows ever visible to the user — the Windows desktop should never remain on screen after the launcher closes.
