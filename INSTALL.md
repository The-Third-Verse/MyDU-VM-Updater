# Installation & First-Run Guide

Step-by-step setup for the MyDU VM Updater: create the hidden Windows VM once,
then use `du-updater` like any native Linux app.

> 📹 A video walkthrough is available: _(link coming soon)_

**Flow at a glance**

```
1. Install host dependencies        (once)
2. Get an official Windows ISO       (you provide it)
3. Create the VM                     scripts/create-vm.sh
4. Install Windows                   ← Load the VirtIO disk driver here
5. Set up the guest + finalize       scripts/create-vm.sh --finalize
6. Everyday use                      du-updater
```

---

## 1. Install host dependencies

Install QEMU/KVM, libvirt, `virtiofsd`, `virt-viewer`, and the helper tools —
see the [Dependencies](README.md#dependencies) section of the README for the
one-line command for your distribution.

Both scripts check dependencies at startup and print the exact install command
for anything missing, so you can also just run them and follow the hints.

Make sure libvirt is running and your user can use it:

```bash
systemctl enable --now libvirtd     # if not already running
```

## 2. Get an official Windows ISO

Download your **own** copy from Microsoft (this project never redistributes
Windows):

- Windows 10 (recommended, lighter): <https://www.microsoft.com/en-us/software-download/windows10ISO>
- Windows 11 (needs `--win11`, plus `swtpm` + OVMF): <https://www.microsoft.com/en-us/software-download/windows11>

## 3. Create the VM

Point the script at your ISO and the Linux directory where the game is (or will
be) installed. That directory is shared into the VM over VirtIO-FS.

```bash
scripts/create-vm.sh --win-iso ~/Downloads/Win10_x64.iso \
                     --game-dir ~/Games/DualUniverse
```

For Windows 11 add `--win11` (UEFI + Secure Boot + TPM 2.0; defaults to 6 GB / 64 GB).

By default the disk, ISOs and domain XML live under
`~/.local/share/du-updater` (per Linux user). Put them elsewhere with
`--data-dir /path` (or set `$XDG_DATA_HOME`).

### Fast path: fully automatic install

Add **`--unattended`** and the whole thing is hands-off — no clicking through
Windows Setup, no manual VirtIO driver step, and the guest provisioning
(`Setup-Guest.ps1`) runs by itself:

```bash
scripts/create-vm.sh --unattended \
                     --win-iso ~/Downloads/Win10_x64.iso \
                     --game-dir ~/Games/DualUniverse
```

It builds an `autounattend.xml` config CD, installs Windows, creates the
restricted user, installs WinFsp/WebView2/guest tools, and powers the VM off when
done. Wait for it to shut off, then jump to step 5 (finalize). Needs an ISO
authoring tool (`xorriso`, `genisoimage`, or `mkisofs`). If you'd rather do it by
hand, skip `--unattended` and follow step 4.

This creates the qcow2 disk, downloads the VirtIO-win driver ISO, defines the
libvirt domain, attaches the Windows and VirtIO ISOs as boot CDs, and starts the
VM. Open the console:

```bash
virt-viewer --connect qemu:///session --attach du-updater
```

> On GNOME/Wayland a new window may open **behind** your terminal — press
> **Super** and click the "Remote Viewer" window to bring it forward.

## 4. Install Windows — loading the VirtIO disk driver

Windows Setup will reach **"Where do you want to install Windows?"** showing an
empty list and:

> We couldn't find any drives. To get a storage driver, click Load driver.

This is expected — the VM's disk is VirtIO, and Windows has no built-in driver.
Load it from the VirtIO CD:

1. Click **Load driver** → **Browse**.
2. Select the CD-ROM that contains folders like `NetKVM`, `viostor`, `vioscsi`,
   `Balloon` — that is the **virtio-win** CD (the other CD is your Windows ISO).
3. Open **`viostor` → `w10` → `amd64`** and click **OK**.
   *(For Windows 11 use `w11`. If the disk still doesn't appear, repeat with
   `vioscsi\w10\amd64`.)*
4. Select **"Red Hat VirtIO SCSI controller"** → **Next**.
   *(If the list looks empty, untick "Hide drivers that aren't compatible…".)*
5. Your **32 GB disk** now appears → select it → **Next** to install.

Windows copies files and reboots a few times inside the VM until it reaches the
desktop.

At the OOBE **"Let's connect you to a network"** step, choose **"I don't have
internet" → "Continue with limited setup"** and create a **local account** — this
is the restricted user the updater uses. Networking comes up automatically on the
next full boot (the NIC is emulated **e1000e**, which Windows drives out of the
box; SLIRP provides NAT internet, IP `10.0.2.15`, gateway `10.0.2.2`).

## 5. Set up the guest, then finalize

Inside Windows, run the guest setup (auto-login restricted user, WebView2, the
Dual Universe installer/launcher, auto-start and auto-shutdown).

> ⚠️ The Windows guest setup scripts are still in development. This section will
> be expanded once they land.

When the guest is ready, shut the VM down and finalize the host side — this ejects
the install media and snapshots a clean baseline:

```bash
scripts/create-vm.sh --finalize
```

## 6. Everyday use

The first time, tell `du-updater` where the game lives (it remembers it after):

```bash
du-updater --game-dir ~/Games/DualUniverse
```

After that, just run:

```bash
du-updater
```

It boots the hidden VM, shows only the launcher, updates the shared game folder,
and shuts everything down when you close the launcher. If `dual-launcher.exe`
isn't in the game folder yet, it offers to install MyDU from the official
installer first.

---

## Troubleshooting

**`error: unsupported configuration: Unable to find a satisfying virtiofsd`**
The VirtIO-FS daemon isn't installed. Install the `virtiofsd` package (see
Dependencies), then start the VM again.

**`error: domain 'du-updater' already exists`**
The VM is already defined — you don't need to create it again. Just start it:

```bash
virsh --connect qemu:///session start du-updater
virt-viewer --connect qemu:///session --attach du-updater
```

To rebuild from scratch instead, add `--recreate` to `create-vm.sh`.

**The console window won't come to the front (Wayland/GNOME)**
Wayland doesn't let apps raise their own windows. Press **Super** and click the
window, or find it in the dock.

**Windows Setup shows no disk**
You skipped the VirtIO driver — see step 4 (Load driver → `viostor\w10\amd64`).

**No internet in the guest**
The VM uses an emulated **e1000e** NIC with SLIRP NAT, which works in Windows with
no extra driver. If you changed the NIC to `virtio`, install **NetKVM** from the
VirtIO CD (`NetKVM\w10\amd64`). Note a NIC-model change only takes effect after a
**full power-off** of the VM (a guest reboot is not enough). Check the host has a
user-net backend: `ldconfig -p | grep libslirp`.

**Missing dependencies**
Run the script; it lists everything missing at once with the install command for
your distribution.
