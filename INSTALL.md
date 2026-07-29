# Installation & First-Run Guide

Set up the hidden Windows VM once, then use `du-updater` like any native Linux
app — it boots the VM in the background, runs the official Dual Universe launcher
to update the game into your Linux game folder, and shuts the VM down when you're
done. You keep playing on the native Linux client.

There are two ways to build the VM:

- **[Easy install](#easy-install-recommended)** — one command does everything,
  fully hands-off. **Recommended.**
- **[Manual install](#manual-install)** — you click through Windows Setup and run
  the guest setup yourself. Use this if the unattended install doesn't fit your
  ISO, or you want to see each step.

Both end at the same place: **[Everyday use](#everyday-use)**.

> 📹 Video walkthrough: _(link coming soon)_

---

## Prerequisites (both paths)

### 1. Host dependencies

Install QEMU/KVM, libvirt, `virtiofsd`, `virt-viewer`, and the helpers — see the
[Dependencies](README.md#dependencies) section of the README for the one-line
command for your distro. The scripts also check at startup and print the exact
install command for anything missing.

Make sure libvirt is running and your user can use it:

```bash
systemctl enable --now libvirtd
```

### 2. Your own Windows ISO

Download an official ISO from Microsoft (this project never redistributes
Windows):

- **Windows 10** (recommended — lighter): <https://www.microsoft.com/en-us/software-download/windows10ISO>
- **Windows 11** (add `--win11`, needs `swtpm` + OVMF): <https://www.microsoft.com/en-us/software-download/windows11>

---

## Easy install (recommended)

One command builds the VM, installs Windows unattended, provisions the guest, and
finalizes a clean baseline — no clicking, no VirtIO-driver step, no manual guest
setup. It needs an ISO-authoring tool (`xorriso`, `genisoimage`, or `mkisofs`).

### Step 1 — Run it

Point it at your ISO and the Linux folder where the game should live (this folder
is shared into the VM and is where the game files end up):

```bash
scripts/create-vm.sh --unattended --auto-finalize \
                     --win-iso ~/Downloads/Win10_x64.iso \
                     --game-dir ~/Games/DualUniverse
```

For Windows 11, add `--win11`. To store the VM disk/ISOs elsewhere, add
`--data-dir /path` (default: `~/.local/share/du-updater`).

### Step 2 — Wait

The command runs unattended and **blocks until the VM finishes and powers off**,
then finalizes automatically (ejects install media, takes the `clean` snapshot).
Expect roughly 15–25 minutes. You can watch if you like:

```bash
virt-viewer --connect qemu:///session --attach du-updater
```

> On GNOME/Wayland the window may open **behind** your terminal — press **Super**
> and click the "Remote Viewer" window.

What's happening on its own: Windows installs → a temporary admin auto-logs in →
`Setup-Guest.ps1` runs (creates the runtime user, installs WinFsp + VirtIO guest
tools + WebView2, sets auto-login + the kiosk shell, slims the disk) → the VM
powers off. If anything goes wrong, it's logged to `C:\du-setup.log` in the guest.

### Step 3 — Use it

When the command returns, you're done building. Go to
**[Everyday use](#everyday-use)**.

---

## Manual install

Same result, but you drive Windows Setup and the guest provisioning yourself.

### Step 1 — Create the VM and boot the installer

```bash
scripts/create-vm.sh --win-iso ~/Downloads/Win10_x64.iso \
                     --game-dir ~/Games/DualUniverse
```

(Add `--win11` for Windows 11; `--data-dir /path` to relocate the files.)

This creates the disk, downloads the VirtIO driver ISO, defines the domain,
attaches the Windows ISO + VirtIO CD + a small **DUCFG scripts CD**, and starts
the VM. Open the console:

```bash
virt-viewer --connect qemu:///session --attach du-updater
```

### Step 2 — Install Windows (load the VirtIO disk driver)

Windows Setup reaches **"Where do you want to install Windows?"** with an empty
list and *"We couldn't find any drives."* — expected, because the disk is VirtIO.
Load the driver:

1. **Load driver** → **Browse**.
2. Pick the CD with `NetKVM`, `viostor`, `vioscsi`, `Balloon` folders (the
   **virtio-win** CD).
3. Open **`viostor` → `w10` → `amd64`** → **OK**. *(Windows 11: `w11`. If the disk
   still doesn't show, try `vioscsi\w10\amd64`.)*
4. Select **"Red Hat VirtIO SCSI controller"** → **Next**. *(If the list is empty,
   untick "Hide drivers that aren't compatible…".)*
5. The disk now appears → select it → **Next**.

Windows copies files and reboots a few times. At OOBE **"Let's connect you to a
network"**, choose **"I don't have internet" → "Continue with limited setup"** and
create any local account (it's temporary — the guest setup creates the real one).

### Step 3 — Run the guest setup

At the Windows desktop, open **PowerShell as Administrator** and run
`Setup-Guest.ps1` from the **DUCFG** CD (the drive that contains it):

```powershell
$cd = (Get-PSDrive -PSProvider FileSystem | ? { Test-Path "$($_.Root)Setup-Guest.ps1" }).Root
Set-ExecutionPolicy -Scope Process Bypass -Force
& "${cd}Setup-Guest.ps1"
```

It creates the `duupdater` runtime user, enables auto-login, installs WinFsp +
VirtIO guest tools + WebView2, sets the kiosk shell, slims the disk, and prints
**"Guest provisioning complete."** (The VirtIO guest-tools installer may flash a
window — let it finish.)

### Step 4 — Shut down and finalize

Shut Windows down (Start → Power → Shut down), then on the host:

```bash
scripts/create-vm.sh --finalize
```

This ejects the install media and snapshots the `clean` baseline. Go to
**[Everyday use](#everyday-use)**.

---

## Everyday use

The first time, tell `du-updater` where the game lives (it remembers afterwards):

```bash
du-updater --game-dir ~/Games/DualUniverse
```

After that, just:

```bash
du-updater
```

It reverts the VM to the clean snapshot, boots it hidden, and the kiosk shell runs
the launcher — no Windows desktop is ever shown. When you close the launcher, the
VM powers off and `du-updater` exits.

- **First run** installs MyDU: it silently installs the launcher to the shared
  drive (`…\DualUniverse`) and starts it. The launcher then downloads the game
  **into your Linux game folder** (`~/Games/DualUniverse/DualUniverse`).
- **Later runs** find the launcher and just start it to update.

By default the VM is disposable — it reverts to the `clean` snapshot each run, so
the Windows side stays pristine and only the game files (on the Linux share)
persist. Opt out per run with `--no-revert`.

---

## Guest accounts & keyboard

| Account | Password | Role |
|---------|----------|------|
| `duupdater` | `DualUniverse!1` | runtime user (auto-login, runs the launcher) |
| `provision` | `Provision!1` | temporary admin used during the unattended install |

The guest keyboard layout is **US (QWERTY)** (`en-US`; change with
`create-vm.sh --locale`). On a physical AZERTY keyboard, type the passwords **as if
on a US keyboard** (`!` is Shift+1, `1` is the top-row digit).

Change defaults via `create-vm.sh` (`--locale`, `--product-key`) and
`Setup-Guest.ps1` (`-UserName`, `-Password`).

---

## Troubleshooting

**"Dual Universe - Low Memory" dialog on launch — normal, click Continue.**
The launcher checks whether the machine can *play* the game and warns about RAM /
video RAM. The VM only *updates* the game (you play on Linux), so this is harmless —
click **Continue**.

**Windows Setup shows no disk.** You skipped the VirtIO driver — see manual
step 2 (Load driver → `viostor\w10\amd64`).

**`error: Unable to find a satisfying virtiofsd`.** Install the `virtiofsd`
package (see Dependencies), then retry.

**`error: domain 'du-updater' already exists`.** It's already built — just run
`du-updater`. To rebuild from scratch, add `--recreate` to `create-vm.sh`.

**The console window won't come to the front (Wayland/GNOME).** Wayland won't let
apps raise their own windows — press **Super** and click it.

**No internet in the guest.** The NIC is emulated **e1000e** with SLIRP NAT
(works with no driver). A NIC change only applies after a **full power-off**.
Check the host has a backend: `ldconfig -p | grep libslirp`.

**Provisioning didn't run (unattended).** Log in as `provision` / `Provision!1`
and read `C:\du-setup.log` — it captures the guest setup, including any error.

**Missing dependencies.** Run the script; it lists everything missing at once with
the install command for your distro.
