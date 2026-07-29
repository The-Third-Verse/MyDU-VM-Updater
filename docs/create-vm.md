# `create-vm` — manual

Build the Dual Universe updater VM, or finalize it into a clean baseline. Run
occasionally (to create or rebuild the VM); day-to-day you use
[`du-updater`](du-updater.md). Invoke it from the repo root as `bin/create-vm`.

## Synopsis

```
bin/create-vm --win-iso PATH [options]     # create / provision
bin/create-vm --finalize [options]         # finalize an installed VM
```

## Description

In its default (provisioning) mode it creates the qcow2 disk, obtains the
VirtIO-win driver ISO, renders and defines the libvirt domain, attaches the
install media, and starts the VM. With `--unattended` it also builds an
`autounattend.xml` config CD so Windows installs and provisions itself; with
`--finalize` it ejects the install media and snapshots a `clean` baseline.

Dependencies are checked at startup; missing ones are printed with the install
command for your distro.

## Options

### Mode

| Option | Description |
|--------|-------------|
| `--win-iso PATH` | **Required for provisioning.** Your own official Windows ISO (10 x64, or 11 with `--win11`). Never downloaded — you supply it. |
| `--finalize` | Finalize an already-installed VM: redefine the clean runtime domain (removing install CD-ROMs) and create the `clean` snapshot. Run after Windows + the guest setup are done and the VM is shut off. |
| `--unattended` | Fully automatic install. Builds a config CD containing `autounattend.xml` + the guest scripts, so Windows installs and runs `Setup-Guest.ps1` hands-off. Needs an ISO tool (`xorriso`, `genisoimage`, or `mkisofs`). |
| `--auto-finalize` | After starting the VM, block until it powers off (end of unattended install/provisioning), then finalize automatically. Combine with `--unattended` for a one-command build. |
| `--recreate` | Overwrite an existing disk and redefine the domain. Required when the domain already exists. **Destroys the current VM.** |

### Guest / Windows

| Option | Default | Description |
|--------|---------|-------------|
| `--win11` | off (Windows 10) | Provision Windows 11: UEFI + Secure Boot + emulated TPM 2.0 (needs `swtpm` + OVMF on the host). Also bumps the defaults to 6144 MiB RAM and 64 G disk unless overridden. |
| `--locale LOC` | `en-US` | Unattended-install locale / keyboard layout. |
| `--product-key KEY` | Win 10/11 Pro generic | Edition-selection key for `--unattended`. The default selects the Pro edition; it does **not** activate Windows. |

### Sizing

| Option | Default | Description |
|--------|---------|-------------|
| `--vcpus N` | `2` | Virtual CPUs. |
| `--ram MIB` | `4096` (`6144` with `--win11`) | RAM in MiB. |
| `--disk-size SIZE` | `32G` (`64G` with `--win11`) | Disk size in `qemu-img` syntax. |

### Paths

| Option | Default | Description |
|--------|---------|-------------|
| `--game-dir DIR` | `GAME_DIR` from du-updater's config | Linux folder shared into the guest via VirtIO-FS. The game installs into a `DualUniverse` subfolder of it. |
| `--data-dir DIR` | `$XDG_DATA_HOME`/`~/.local/share/du-updater` | Where the disk, ISOs and domain XML are stored. |
| `--disk PATH` | `<data-dir>/<vm>.qcow2` | Explicit qcow2 disk path. |
| `--virtio-iso PATH` | auto-downloaded | VirtIO-win ISO. Downloaded (and cached) if omitted. |

### libvirt

| Option | Default | Description |
|--------|---------|-------------|
| `--vm NAME` | `du-updater` | libvirt domain name. |
| `--uri URI` | `qemu:///session` | libvirt connection URI. |
| `-h`, `--help` | | Show help and exit. |

## Fixed defaults

- VirtIO-FS share tag: `dushare`
- Clean snapshot name: `clean`
- Provisioning admin account: `provision` / `Provision!1` (temporary, unattended only)

## Files it creates (under `--data-dir`)

| File | Purpose |
|------|---------|
| `<vm>.qcow2` | the VM disk |
| `virtio-win.iso` | cached VirtIO driver ISO |
| `<vm>.xml` | rendered libvirt domain definition |
| `du-guest.iso` | guest scripts CD (+ `autounattend.xml` when `--unattended`) |

## Dependencies

`virsh`, `qemu-img`, `virt-xml`, `envsubst`, `virtiofsd`; `curl` (to download the
VirtIO ISO); `swtpm` + OVMF (with `--win11`); `xorriso`/`genisoimage`/`mkisofs`
(with `--unattended`).

## Examples

```bash
# Fully automatic Windows 10 build (recommended)
bin/create-vm --unattended --auto-finalize \
              --win-iso ~/Win10.iso --game-dir ~/Games/DualUniverse

# Windows 11, automatic
bin/create-vm --win11 --unattended --auto-finalize \
              --win-iso ~/Win11.iso --game-dir ~/Games/DualUniverse

# Manual install, then finalize by hand
bin/create-vm --win-iso ~/Win10.iso --game-dir ~/Games/DualUniverse
# ... install Windows, run Setup-Guest.ps1 from the DUCFG CD, shut down ...
bin/create-vm --finalize

# Rebuild from scratch, storing everything on a bigger disk
bin/create-vm --recreate --win-iso ~/Win10.iso --game-dir ~/Games/DU \
              --data-dir /mnt/vms/du --disk-size 40G
```

## See also

[`du-updater`](du-updater.md) · [INSTALL.md](INSTALL.md)
