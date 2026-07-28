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

- A Linux host with QEMU, KVM, and libvirt
- An **official Windows ISO that you provide yourself**, downloaded from Microsoft:
  - Windows 10: <https://www.microsoft.com/en-us/software-download/windows10ISO>
  - Windows 11: <https://www.microsoft.com/en-us/software-download/windows11> (use `create-vm.sh --win11`; also needs `swtpm` + OVMF for TPM 2.0 / Secure Boot)
- Suggested VM sizing: 2 vCPU, 4 GB RAM, 32 GB dynamic qcow2 disk (Windows 11 defaults to 6 GB / 64 GB)

## Status

Early stage — actively under development.

## Licensing note

This project is MIT-licensed (see [LICENSE](LICENSE)), but it does **not**
redistribute Windows, WebView2, or the Dual Universe launcher. You must supply
your own official Windows ISO and comply with Microsoft's and Novaquark's terms.
