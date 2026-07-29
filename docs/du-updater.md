# `du-updater` — manual

Run the updater: boot the hidden VM, run the Dual Universe launcher to update the
game, and shut down when done. This is the day-to-day command; build the VM first
with [`create-vm`](create-vm.md). Invoke it as `bin/du-updater`, or symlink it onto
your `PATH` (see [INSTALL.md](INSTALL.md)) to call it as `du-updater`.

## Synopsis

```
du-updater [options]
```

## Description

Resolves the game directory, checks the guest can read/write it, decides whether to
run or install the launcher (writing a command file the guest reads), optionally
reverts the `clean` snapshot, points the VM's VirtIO-FS share at the game directory,
starts the VM, and shows the launcher over SPICE. The session ends — and the VM
shuts down — when you close the launcher **or** the viewer window.

## Options

### Game directory

| Option | Description |
|--------|-------------|
| `-g`, `--game-dir DIR` | Parent folder for the game (created if missing, persisted to config). MyDU installs into a `DualUniverse` subfolder; the launcher is found there recursively. |
| `--set-game-dir DIR` | Save `DIR` as the game directory and exit (no launch). |

### Behavior

| Option | Description |
|--------|-------------|
| `--install` | If the launcher isn't found, install MyDU without prompting. |
| `--desktop` | Boot to a Windows desktop for inspection/debugging instead of the launcher. Does not revert; shut Windows down (or close the window) when done. |
| `--no-revert` | Don't restore the clean snapshot before launching (overrides `CLEAN_SNAPSHOT`). |
| `--silent` | Headless: no SPICE window; wait for the guest to power off. |
| `-y`, `--yes` | Assume "yes" for all prompts (non-interactive). |

### Access check

| Option | Description |
|--------|-------------|
| `--check-access` | Report game-dir files the VM can't fully read/write, then exit. |
| `--fix-access` | Repair restricted permissions (`chmod u+rwX`) without prompting. |
| `--no-check` | Skip the access check entirely. |

### libvirt

| Option | Default | Description |
|--------|---------|-------------|
| `--vm NAME` | `du-updater` | libvirt domain name. |
| `--uri URI` | `qemu:///session` | libvirt connection URI. |
| `-h`, `--help` | | Show help and exit. |

## Environment variables

Each overrides the corresponding default:

| Variable | Default |
|----------|---------|
| `DU_GAME_DIR` | *(unset)* |
| `DU_VM_NAME` | `du-updater` |
| `DU_LIBVIRT_URI` | `qemu:///session` |
| `DU_SHARE_TAG` | `dushare` |
| `DU_CLEAN_SNAPSHOT` | *(empty — VM keeps state; set to `clean` for a disposable VM)* |
| `DU_LAUNCHER_EXE` | `dual-launcher.exe` |
| `DU_INSTALLER_URL` | official MyDU installer URL |

## Files

| Path | Purpose |
|------|---------|
| `~/.config/du-updater/config` | persisted settings (`GAME_DIR`, `VM_NAME`, `LIBVIRT_URI`, `SHARE_TAG`, `CLEAN_SNAPSHOT`) |
| `~/.local/state/du-updater/du-updater.log` | run log |

## Guest control files (on the share)

`du-updater` and the guest talk through `<game-dir>/.du-updater/`:

| File | Written by | Purpose |
|------|-----------|---------|
| `command` | du-updater | `ACTION=run\|install\|desktop`, `INSTALLER_URL`, `LAUNCHER_EXE` |
| `guest.log` | guest boot script | the guest run log (readable from Linux) |
| `mydu-install.log` | MyDU installer | install log (first run) |

## Disposable vs persistent

By default the VM **keeps its state** between runs (launcher install, VC++ runtime,
DU login persist). To make it disposable — reverting to the `clean` snapshot each
run — set `CLEAN_SNAPSHOT="clean"` in the config (note: that re-runs first-time
installs and re-prompts for the DU login every run).

## Examples

```bash
du-updater --game-dir ~/Games/DualUniverse   # first run (remembers the dir)
du-updater                                    # subsequent runs
du-updater --install --yes                    # non-interactive install
du-updater --desktop                          # inspect the VM's Windows desktop
du-updater --check-access                     # audit share permissions
du-updater --no-revert                        # keep VM changes this run
```

## See also

[`create-vm`](create-vm.md) · [INSTALL.md](INSTALL.md)
