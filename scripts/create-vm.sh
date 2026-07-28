#!/usr/bin/env bash
#
# create-vm.sh — provision the Dual Universe updater VM (libvirt / qemu:///session).
#
# Provisioning (default):
#   1. Create the qcow2 disk.
#   2. Fetch the VirtIO-win driver ISO (unless supplied).
#   3. Render libvirt/du-updater.xml.in and `virsh define` the runtime domain.
#   4. Attach the Windows ISO + VirtIO-win ISO as boot CD-ROMs and start the VM
#      so you can install Windows (load 'viostor' from the VirtIO ISO when the
#      installer asks where to install).
#
# Finalize (--finalize), after Windows + drivers + the DU launcher are set up:
#   - Re-define the clean runtime domain (ejects the install media).
#   - Create a 'clean' snapshot used as the disposable baseline.
#
# You must provide your own official Windows ISO. This script never downloads
# or redistributes Windows.

set -euo pipefail

readonly PROG="create-vm.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly TEMPLATE="$REPO_DIR/libvirt/du-updater.xml.in"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/du-updater"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/du-updater/config"

readonly VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
readonly WIN10_ISO_URL="https://www.microsoft.com/en-us/software-download/windows10ISO"
readonly WIN11_ISO_URL="https://www.microsoft.com/en-us/software-download/windows11"

# Defaults (overridable by flags / existing config).
VM_NAME="du-updater"
LIBVIRT_URI="qemu:///session"
SHARE_TAG="dushare"
VCPUS=2
MEM_MIB=4096
DISK_SIZE="32G"
DISK_PATH=""
GAME_DIR=""
WIN_ISO=""
VIRTIO_ISO=""
FINALIZE=0
RECREATE=0
WIN11=0
RAM_SET=0
DISK_SET=0
SNAPSHOT_NAME="clean"

# Firmware/TPM XML fragments injected into the template. Empty = Windows 10 (BIOS).
OS_FIRMWARE_ATTR=""
FIRMWARE_BLOCK=""
SMM_FEATURE=""
TPM_DEVICE=""

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $PROG --win-iso PATH [options]
       $PROG --finalize [options]

Provision the Dual Universe updater VM, or finalize it into a clean baseline.

Required for provisioning:
  --win-iso PATH        Your own official Windows ISO (10 x64, or 11 with --win11).

Options:
  --win11               Provision for Windows 11: UEFI + Secure Boot + TPM 2.0.
                        Requires swtpm and OVMF on the host. Bumps the default
                        RAM to 6144 MiB and disk to 64G unless overridden.
  --game-dir DIR        Linux game directory to share into the guest.
                        (Defaults to GAME_DIR from du-updater's config.)
  --virtio-iso PATH     VirtIO-win ISO. Downloaded automatically if omitted.
  --disk PATH           qcow2 disk path (default: $DATA_HOME/<name>.qcow2)
  --disk-size SIZE      Disk size, qemu-img syntax (default: $DISK_SIZE)
  --vcpus N             vCPUs (default: $VCPUS)
  --ram MIB             RAM in MiB (default: $MEM_MIB)
  --vm NAME             Domain name (default: $VM_NAME)
  --uri URI             libvirt URI (default: $LIBVIRT_URI)
  --recreate            Overwrite an existing disk / redefine the domain.
  --finalize            Eject install media and create the '$SNAPSHOT_NAME' snapshot.
  -h, --help            Show this help.

Typical flow:
  scripts/create-vm.sh --win-iso ~/Win10.iso --game-dir ~/Games/DualUniverse
  # ... install Windows in the SPICE window, run the Windows setup scripts ...
  scripts/create-vm.sh --finalize
EOF
}

# --------------------------------------------------------------------------- #
load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    # shellcheck disable=SC1090
    . "$CONFIG_FILE" 2>/dev/null || true
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --win-iso)     WIN_ISO="${2:?}"; shift 2 ;;
            --virtio-iso)  VIRTIO_ISO="${2:?}"; shift 2 ;;
            --game-dir)    GAME_DIR="${2:?}"; shift 2 ;;
            --disk)        DISK_PATH="${2:?}"; shift 2 ;;
            --disk-size)   DISK_SIZE="${2:?}"; DISK_SET=1; shift 2 ;;
            --vcpus)       VCPUS="${2:?}"; shift 2 ;;
            --ram)         MEM_MIB="${2:?}"; RAM_SET=1; shift 2 ;;
            --win11)       WIN11=1; shift ;;
            --vm)          VM_NAME="${2:?}"; shift 2 ;;
            --uri)         LIBVIRT_URI="${2:?}"; shift 2 ;;
            --recreate)    RECREATE=1; shift ;;
            --finalize)    FINALIZE=1; shift ;;
            -h|--help)     usage; exit 0 ;;
            *)             die "unknown argument: $1 (try --help)" ;;
        esac
    done
}

virsh_() { virsh --connect "$LIBVIRT_URI" "$@"; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

check_deps() {
    require_cmd virsh
    require_cmd qemu-img
    require_cmd virt-xml
    require_cmd envsubst
    if [ "$WIN11" -eq 1 ]; then
        require_cmd swtpm  # emulated TPM 2.0 backend
        have_ovmf || warn "Could not find OVMF UEFI firmware; install 'edk2-ovmf'/'ovmf' if the VM fails to boot."
    fi
}

have_ovmf() {
    ls /usr/share/OVMF/OVMF_CODE*.fd \
       /usr/share/edk2*/*/OVMF_CODE*.fd \
       /usr/share/qemu/firmware/*.json >/dev/null 2>&1
}

# Fill the firmware/TPM template slots for Windows 11 (UEFI + Secure Boot + TPM).
# Left empty for Windows 10 (legacy BIOS).
configure_firmware() {
    [ "$WIN11" -eq 1 ] || return 0
    info "Windows 11 mode: UEFI + Secure Boot + emulated TPM 2.0"
    OS_FIRMWARE_ATTR=" firmware='efi'"
    FIRMWARE_BLOCK=$'    <firmware>\n      <feature enabled=\'yes\' name=\'enrolled-keys\'/>\n      <feature enabled=\'yes\' name=\'secure-boot\'/>\n    </firmware>\n    <loader secure=\'yes\'/>\n'
    SMM_FEATURE=$'    <smm state=\'on\'/>\n'
    TPM_DEVICE=$'    <tpm model=\'tpm-crd\'>\n      <backend type=\'emulator\' version=\'2.0\'/>\n    </tpm>\n'

    # Windows 11 needs more room than the Win10 defaults.
    [ "$RAM_SET" -eq 0 ]  && MEM_MIB=6144
    [ "$DISK_SET" -eq 0 ] && DISK_SIZE="64G"
}

resolve_paths() {
    [ -n "$DISK_PATH" ] || DISK_PATH="$DATA_HOME/$VM_NAME.qcow2"
    if [ -n "$GAME_DIR" ]; then
        mkdir -p "$GAME_DIR"
        GAME_DIR="$(cd "$GAME_DIR" && pwd -P)"
    fi
}

# --------------------------------------------------------------------------- #
create_disk() {
    if [ -f "$DISK_PATH" ] && [ "$RECREATE" -eq 0 ]; then
        info "Disk already exists: $DISK_PATH (use --recreate to overwrite)"
        return 0
    fi
    mkdir -p "$(dirname "$DISK_PATH")"
    info "Creating ${DISK_SIZE} qcow2 disk at $DISK_PATH"
    qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE" >/dev/null
}

fetch_virtio_iso() {
    if [ -n "$VIRTIO_ISO" ]; then
        [ -f "$VIRTIO_ISO" ] || die "VirtIO ISO not found: $VIRTIO_ISO"
        return 0
    fi
    VIRTIO_ISO="$DATA_HOME/virtio-win.iso"
    if [ -f "$VIRTIO_ISO" ]; then
        info "Using cached VirtIO-win ISO: $VIRTIO_ISO"
        return 0
    fi
    require_cmd curl
    info "Downloading VirtIO-win ISO -> $VIRTIO_ISO"
    curl -fL --progress-bar "$VIRTIO_URL" -o "$VIRTIO_ISO.part" \
        || die "failed to download VirtIO-win ISO from $VIRTIO_URL"
    mv "$VIRTIO_ISO.part" "$VIRTIO_ISO"
}

render_and_define() {
    [ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"
    [ -n "$GAME_DIR" ] || die "no game directory. Pass --game-dir or set it via 'du-updater --set-game-dir'."

    local xml="$DATA_HOME/$VM_NAME.xml"
    local mem_kib=$(( MEM_MIB * 1024 ))
    mkdir -p "$DATA_HOME"

    info "Rendering domain XML -> $xml"
    VM_NAME="$VM_NAME" MEM_KIB="$mem_kib" VCPUS="$VCPUS" \
    DISK_PATH="$DISK_PATH" GAME_DIR="$GAME_DIR" SHARE_TAG="$SHARE_TAG" \
    OS_FIRMWARE_ATTR="$OS_FIRMWARE_ATTR" FIRMWARE_BLOCK="$FIRMWARE_BLOCK" \
    SMM_FEATURE="$SMM_FEATURE" TPM_DEVICE="$TPM_DEVICE" \
        envsubst '${VM_NAME} ${MEM_KIB} ${VCPUS} ${DISK_PATH} ${GAME_DIR} ${SHARE_TAG} ${OS_FIRMWARE_ATTR} ${FIRMWARE_BLOCK} ${SMM_FEATURE} ${TPM_DEVICE}' \
        <"$TEMPLATE" >"$xml"

    info "Defining libvirt domain '$VM_NAME'"
    virsh_ define "$xml" >/dev/null
    printf '%s' "$xml"
}

attach_install_media_and_start() {
    info "Attaching install media (Windows + VirtIO-win) as boot CD-ROMs"
    # Windows ISO first, VirtIO ISO second; the OS disk (boot order 3) comes last.
    virt-xml --connect "$LIBVIRT_URI" "$VM_NAME" --add-device \
        --disk "path=$WIN_ISO,device=cdrom,target.bus=sata,readonly=on,boot.order=1" >/dev/null
    virt-xml --connect "$LIBVIRT_URI" "$VM_NAME" --add-device \
        --disk "path=$VIRTIO_ISO,device=cdrom,target.bus=sata,readonly=on,boot.order=2" >/dev/null

    info "Starting VM for Windows installation"
    virsh_ start "$VM_NAME" >/dev/null

    cat <<EOF

Windows installer is booting. Open the console with:

    virt-viewer --connect $LIBVIRT_URI --attach "$VM_NAME"

During setup, when asked where to install Windows, choose "Load driver" and
pick the viostor driver for Windows 10 (amd64) from the VirtIO-win CD.

When Windows is installed, run the Windows setup scripts (auto-login,
WebView2, DU launcher, auto-start / auto-shutdown), then finalize:

    scripts/create-vm.sh --finalize --vm "$VM_NAME"
EOF
}

# --------------------------------------------------------------------------- #
finalize() {
    virsh_ dominfo "$VM_NAME" >/dev/null 2>&1 || die "domain '$VM_NAME' not found."

    local state; state="$(virsh_ domstate "$VM_NAME" 2>/dev/null || echo unknown)"
    if [ "$state" = "running" ]; then
        warn "domain is running; shut it down before finalizing."
        die "run: virsh --connect $LIBVIRT_URI shutdown $VM_NAME"
    fi

    local xml="$DATA_HOME/$VM_NAME.xml"
    [ -f "$xml" ] || die "rendered runtime XML not found: $xml (re-run provisioning)."

    info "Re-defining clean runtime domain (removes install CD-ROMs)"
    virsh_ define "$xml" >/dev/null

    if virsh_ snapshot-info "$VM_NAME" "$SNAPSHOT_NAME" >/dev/null 2>&1; then
        info "Snapshot '$SNAPSHOT_NAME' already exists; leaving it in place."
    else
        info "Creating clean baseline snapshot '$SNAPSHOT_NAME'"
        virsh_ snapshot-create-as --domain "$VM_NAME" "$SNAPSHOT_NAME" \
            --description "Clean DU updater baseline" >/dev/null \
            || warn "snapshot creation failed; you can still use the VM without it."
    fi

    cat <<EOF

Done. To have du-updater restore this clean state before each run, set:

    DU_CLEAN_SNAPSHOT=$SNAPSHOT_NAME
    (or add CLEAN_SNAPSHOT="$SNAPSHOT_NAME" to $CONFIG_FILE)
EOF
}

# --------------------------------------------------------------------------- #
main() {
    load_config
    parse_args "$@"
    check_deps
    resolve_paths

    if [ "$FINALIZE" -eq 1 ]; then
        finalize
        return 0
    fi

    if [ -z "$WIN_ISO" ]; then
        die "provisioning requires --win-iso PATH (your own official Windows ISO).
Download one from Microsoft:
  Windows 10: $WIN10_ISO_URL
  Windows 11: $WIN11_ISO_URL  (use with --win11)"
    fi
    [ -f "$WIN_ISO" ] || die "Windows ISO not found: $WIN_ISO"

    configure_firmware

    if virsh_ dominfo "$VM_NAME" >/dev/null 2>&1 && [ "$RECREATE" -eq 0 ]; then
        die "domain '$VM_NAME' already exists. Use --recreate to redefine it, or --finalize."
    fi
    [ "$RECREATE" -eq 1 ] && virsh_ dominfo "$VM_NAME" >/dev/null 2>&1 \
        && { virsh_ destroy "$VM_NAME" >/dev/null 2>&1 || true; }

    create_disk
    fetch_virtio_iso
    render_and_define >/dev/null
    attach_install_media_and_start
}

main "$@"
