# MyDU VM Updater

Seamless Linux updater for **Dual Universe** — runs the official Windows launcher
inside a hidden QEMU/KVM Windows VM so Linux users can update the game, then play
the native Linux client.

The official launcher depends on **Microsoft WebView2**, which isn't available on
Linux. Rather than forcing WebView2 through Wine, this project runs the launcher
in a lightweight, invisible Windows virtual machine that behaves like a native
Linux application.

## How it works

```
du-updater (Linux script)
  → start QEMU/KVM VM via libvirt
  → open a SPICE window showing only the launcher
  → Windows auto-logs-in a restricted user and auto-starts the DU launcher
  → the launcher updates the shared game directory
  → on launcher exit, Windows shuts down automatically
  → the VM stops and the window closes
```

- **No GPU passthrough** — VirtIO GPU + SPICE display.
- **Game files stay on Linux** — the Linux game directory is shared into the guest
  via VirtIO-FS (fallback: SMB). Windows never permanently stores the game.
- **Windows is a disposable runtime** — the desktop is never left visible.

## Requirements

- A Linux host with QEMU + KVM and libvirt
- An **official Windows ISO that you provide yourself**, downloaded from Microsoft:
  - Windows 10: <https://www.microsoft.com/en-us/software-download/windows10ISO>
  - Windows 11: <https://www.microsoft.com/en-us/software-download/windows11> (use `create-vm.sh --win11`; also needs `swtpm` + OVMF for TPM 2.0 / Secure Boot)
- Suggested VM sizing: 2 vCPU, 4 GB RAM, 32 GB dynamic qcow2 disk (Windows 11 defaults to 6 GB / 64 GB)

## Dependencies

Host packages needed by the scripts (both scripts check at startup and print a
distro-specific install command for anything missing):

| Tool | Provides | Used by |
|------|----------|---------|
| `qemu-system-x86_64`, KVM | the hypervisor | runtime |
| `virsh` | libvirt CLI | both |
| `virt-viewer` | SPICE window | `du-updater` |
| `virt-xml` | edit the domain (share path, install media) | `create-vm.sh`, `du-updater` |
| `qemu-img` | create the qcow2 disk | `create-vm.sh` |
| `envsubst` | render the domain template | `create-vm.sh` |
| `curl` | download the VirtIO-win ISO | `create-vm.sh` |
| `swtpm` + OVMF | TPM 2.0 + UEFI/Secure Boot | `create-vm.sh --win11` |

Install everything in one go:

```bash
# Debian / Ubuntu
sudo apt install qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients \
                 virt-viewer virtinst gettext-base curl swtpm ovmf

# Fedora / RHEL
sudo dnf install qemu-kvm qemu-img libvirt libvirt-client virt-viewer virt-install \
                 gettext curl swtpm edk2-ovmf

# Arch
sudo pacman -S qemu-full libvirt virt-viewer virt-install gettext curl swtpm edk2-ovmf

# openSUSE
sudo zypper install qemu-kvm qemu-tools libvirt-client virt-viewer virt-install \
                    gettext-runtime curl swtpm qemu-ovmf-x86_64
```

Then make sure `libvirtd` is running (`systemctl enable --now libvirtd`) and your
user is in the `libvirt`/`kvm` groups.

## Status

Early stage — actively under development.

## Licensing note

This project is MIT-licensed (see [LICENSE](LICENSE)), but it does **not**
redistribute Windows, WebView2, or the Dual Universe launcher. You must supply
your own official Windows ISO and comply with Microsoft's and Novaquark's terms.
