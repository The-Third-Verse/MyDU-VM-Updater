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
AUTO_FINALIZE=0
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

# Unattended-install options and rendered fragments.
UNATTENDED=0
LOCALE="en-US"
# Generic edition-selection key (Windows 10/11 Pro). Selects the edition so setup
# doesn't prompt; it does NOT activate Windows.
PRODUCT_KEY="VK7JG-NPHTM-C97JM-9MPGT-3V66T"
PROV_USER="provision"
PROV_PASS="Provision!1"
WINPE_DRIVER_DIR="w10"
OS_PARTITION_ID="1"
DISK_CONFIG=""
CONFIG_ISO=""
UNATTEND_TEMPLATE="$REPO_DIR/windows/autounattend.xml.in"

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
  --unattended          Fully automatic: build an autounattend config CD so
                        Windows installs and provisions itself hands-off (needs
                        xorriso/genisoimage/mkisofs).
  --game-dir DIR        Linux game directory to share into the guest.
                        (Defaults to GAME_DIR from du-updater's config.)
  --data-dir DIR        Where to store the disk, ISOs and domain XML
                        (default: $DATA_HOME). Also honors \$XDG_DATA_HOME.
  --virtio-iso PATH     VirtIO-win ISO. Downloaded automatically if omitted.
  --disk PATH           qcow2 disk path (default: <data-dir>/<name>.qcow2)
  --disk-size SIZE      Disk size, qemu-img syntax (default: $DISK_SIZE)
  --locale LOC          Unattended install locale (default: $LOCALE).
  --product-key KEY     Edition-selection key for --unattended (default: Pro).
  --vcpus N             vCPUs (default: $VCPUS)
  --ram MIB             RAM in MiB (default: $MEM_MIB)
  --vm NAME             Domain name (default: $VM_NAME)
  --uri URI             libvirt URI (default: $LIBVIRT_URI)
  --recreate            Overwrite an existing disk / redefine the domain.
  --finalize            Eject install media and create the '$SNAPSHOT_NAME' snapshot.
  --auto-finalize       After starting, wait for the VM to power off (end of the
                        unattended install/provisioning) and finalize it.
  -h, --help            Show this help.

Typical flow (manual):
  scripts/create-vm.sh --win-iso ~/Win10.iso --game-dir ~/Games/DualUniverse
  # ... install Windows in the SPICE window, run the Windows setup scripts ...
  scripts/create-vm.sh --finalize

Typical flow (automatic):
  scripts/create-vm.sh --unattended --win-iso ~/Win10.iso --game-dir ~/Games/DualUniverse
  # ... VM installs + provisions itself, then powers off ...
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
            --data-dir)    DATA_HOME="${2:?}"; shift 2 ;;
            --unattended)  UNATTENDED=1; shift ;;
            --locale)      LOCALE="${2:?}"; shift 2 ;;
            --product-key) PRODUCT_KEY="${2:?}"; shift 2 ;;
            --disk)        DISK_PATH="${2:?}"; shift 2 ;;
            --disk-size)   DISK_SIZE="${2:?}"; DISK_SET=1; shift 2 ;;
            --vcpus)       VCPUS="${2:?}"; shift 2 ;;
            --ram)         MEM_MIB="${2:?}"; RAM_SET=1; shift 2 ;;
            --win11)       WIN11=1; shift ;;
            --vm)          VM_NAME="${2:?}"; shift 2 ;;
            --uri)         LIBVIRT_URI="${2:?}"; shift 2 ;;
            --recreate)      RECREATE=1; shift ;;
            --finalize)      FINALIZE=1; shift ;;
            --auto-finalize) AUTO_FINALIZE=1; shift ;;
            -h|--help)     usage; exit 0 ;;
            *)             die "unknown argument: $1 (try --help)" ;;
        esac
    done
}

virsh_() { virsh --connect "$LIBVIRT_URI" "$@"; }

# Suggest a distro-appropriate install command for a required tool.
install_hint() {
    local tool="$1" apt dnf pacman zypper osinfo id like
    case "$tool" in
        virsh)        apt="libvirt-clients"; dnf="libvirt-client"; pacman="libvirt";       zypper="libvirt-client" ;;
        virt-viewer)  apt="virt-viewer";     dnf="virt-viewer";    pacman="virt-viewer";   zypper="virt-viewer" ;;
        virt-xml)     apt="virtinst";        dnf="virt-install";   pacman="virt-install";  zypper="virt-install" ;;
        qemu-img)     apt="qemu-utils";      dnf="qemu-img";       pacman="qemu-img";      zypper="qemu-tools" ;;
        envsubst)     apt="gettext-base";    dnf="gettext";        pacman="gettext";       zypper="gettext-runtime" ;;
        swtpm)        apt="swtpm";           dnf="swtpm";          pacman="swtpm";         zypper="swtpm" ;;
        virtiofsd)    apt="virtiofsd";       dnf="virtiofsd";      pacman="virtiofsd";     zypper="virtiofsd" ;;
        curl)         apt="curl";            dnf="curl";           pacman="curl";          zypper="curl" ;;
        xorriso)      apt="xorriso";         dnf="xorriso";        pacman="libisoburn";    zypper="xorriso" ;;
        *)            apt="$tool"; dnf="$tool"; pacman="$tool"; zypper="$tool" ;;
    esac
    if [ -r /etc/os-release ]; then
        osinfo="$( . /etc/os-release 2>/dev/null; printf '%s|%s' "${ID:-}" "${ID_LIKE:-}" )"
        id="${osinfo%%|*}"; like="${osinfo#*|}"
    fi
    case " ${id:-} ${like:-} " in
        *" debian "*|*" ubuntu "*)            printf 'sudo apt install %s'      "$apt" ;;
        *" fedora "*|*" rhel "*|*" centos "*) printf 'sudo dnf install %s'      "$dnf" ;;
        *" arch "*)                           printf 'sudo pacman -S %s'        "$pacman" ;;
        *" suse "*|*" opensuse "*)            printf 'sudo zypper install %s'   "$zypper" ;;
        *)                                    printf 'install the "%s" package for your distribution' "$tool" ;;
    esac
}

# Verify all required tools are present, reporting every missing one at once.
check_deps() {
    local missing=() tool needed=(virsh qemu-img virt-xml envsubst)
    [ -z "$VIRTIO_ISO" ] && needed+=(curl)  # only needed to download the VirtIO ISO
    [ "$WIN11" -eq 1 ]   && needed+=(swtpm) # emulated TPM 2.0 backend
    for tool in "${needed[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    have_virtiofsd || missing+=("virtiofsd")  # required for the VirtIO-FS game share
    [ "$UNATTENDED" -eq 1 ] && ! have_iso_tool && missing+=("xorriso")  # build the config CD
    if [ "${#missing[@]}" -gt 0 ]; then
        { printf 'error: missing required dependencies:\n'
          for tool in "${missing[@]}"; do printf '  - %-12s install: %s\n' "$tool" "$(install_hint "$tool")"; done
          printf 'See the README (Dependencies) for the full list.\n'
        } >&2
        exit 1
    fi
    if [ "$WIN11" -eq 1 ] && ! have_ovmf; then
        warn "Could not find OVMF UEFI firmware; install 'edk2-ovmf'/'ovmf' if the VM fails to boot."
    fi
}

# Return success if any listed path exists. Uses a per-path test rather than a
# single `ls a b c`, which fails when *any* argument is missing even if others
# exist. Unmatched globs stay literal and simply fail the -e test.
any_exists() {
    local p
    for p in "$@"; do [ -e "$p" ] && return 0; done
    return 1
}

have_ovmf() {
    any_exists /usr/share/OVMF/OVMF_CODE*.fd \
               /usr/share/edk2*/*/OVMF_CODE*.fd \
               /usr/share/qemu/firmware/*.json
}

# The standalone (Rust) VirtIO-FS daemon usually lives outside $PATH (libexec),
# so probe its known locations too. Deliberately excludes the deprecated
# /usr/lib/qemu/virtiofsd, which modern libvirt rejects as "unsatisfying".
have_virtiofsd() {
    command -v virtiofsd >/dev/null 2>&1 && return 0
    any_exists /usr/libexec/virtiofsd /usr/lib/virtiofsd /usr/bin/virtiofsd
}

# Any tool that can author an ISO9660 image for the unattended config CD.
have_iso_tool() {
    command -v xorriso >/dev/null 2>&1 || command -v genisoimage >/dev/null 2>&1 \
        || command -v mkisofs >/dev/null 2>&1
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
    case "$DATA_HOME" in
        "~")   DATA_HOME="$HOME" ;;
        "~/"*) DATA_HOME="$HOME/${DATA_HOME#\~/}" ;;
    esac
    mkdir -p "$DATA_HOME"
    DATA_HOME="$(cd "$DATA_HOME" && pwd -P)"
    UNATTEND_TEMPLATE="$REPO_DIR/windows/autounattend.xml.in"

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

# Disk-layout answer-file fragment for the target firmware.
bios_disk_config() {
    cat <<'XML'
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Active>true</Active><Format>NTFS</Format><Label>Windows</Label></ModifyPartition>
          </ModifyPartitions>
        </Disk>
XML
}

uefi_disk_config() {
    cat <<'XML'
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label></ModifyPartition>
          </ModifyPartitions>
        </Disk>
XML
}

configure_unattend() {
    if [ "$WIN11" -eq 1 ]; then
        WINPE_DRIVER_DIR="w11"; OS_PARTITION_ID="3"; DISK_CONFIG="$(uefi_disk_config)"
    else
        WINPE_DRIVER_DIR="w10"; OS_PARTITION_ID="1"; DISK_CONFIG="$(bios_disk_config)"
    fi
}

# Render autounattend.xml + bundle the guest scripts onto a small ISO9660 CD that
# Windows Setup auto-detects.
build_config_iso() {
    [ -f "$UNATTEND_TEMPLATE" ] || die "unattended template not found: $UNATTEND_TEMPLATE"
    configure_unattend
    local stage="$DATA_HOME/unattend"
    rm -rf "$stage"; mkdir -p "$stage"

    info "Rendering autounattend.xml (locale $LOCALE, drivers $WINPE_DRIVER_DIR)"
    LOCALE="$LOCALE" PRODUCT_KEY="$PRODUCT_KEY" COMPUTER_NAME="$VM_NAME" \
    PROV_USER="$PROV_USER" PROV_PASS="$PROV_PASS" WINPE_DRIVER_DIR="$WINPE_DRIVER_DIR" \
    DISK_CONFIG="$DISK_CONFIG" OS_PARTITION_ID="$OS_PARTITION_ID" \
        envsubst '${LOCALE} ${PRODUCT_KEY} ${COMPUTER_NAME} ${PROV_USER} ${PROV_PASS} ${WINPE_DRIVER_DIR} ${DISK_CONFIG} ${OS_PARTITION_ID}' \
        <"$UNATTEND_TEMPLATE" >"$stage/autounattend.xml"

    cp "$REPO_DIR/windows/Setup-Guest.ps1" "$REPO_DIR/windows/Start-Updater.ps1" "$stage/"

    CONFIG_ISO="$DATA_HOME/du-unattend.iso"
    info "Building unattended config ISO -> $CONFIG_ISO"
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -as mkisofs -J -R -V DUCFG -o "$CONFIG_ISO" "$stage" >/dev/null 2>&1
    elif command -v genisoimage >/dev/null 2>&1; then
        genisoimage -J -r -V DUCFG -o "$CONFIG_ISO" "$stage" >/dev/null 2>&1
    else
        mkisofs -J -r -V DUCFG -o "$CONFIG_ISO" "$stage" >/dev/null 2>&1
    fi
}

attach_install_media_and_start() {
    info "Attaching install media (Windows + VirtIO-win) as boot CD-ROMs"
    # Windows ISO first, VirtIO ISO second; the OS disk (boot order 3) comes last.
    virt-xml --connect "$LIBVIRT_URI" "$VM_NAME" --add-device \
        --disk "path=$WIN_ISO,device=cdrom,target.bus=sata,readonly=on,boot.order=1" >/dev/null
    virt-xml --connect "$LIBVIRT_URI" "$VM_NAME" --add-device \
        --disk "path=$VIRTIO_ISO,device=cdrom,target.bus=sata,readonly=on,boot.order=2" >/dev/null
    if [ -n "$CONFIG_ISO" ]; then
        info "Attaching unattended config CD"
        virt-xml --connect "$LIBVIRT_URI" "$VM_NAME" --add-device \
            --disk "path=$CONFIG_ISO,device=cdrom,target.bus=sata,readonly=on" >/dev/null
    fi

    info "Starting VM"
    virsh_ start "$VM_NAME" >/dev/null

    local finalize_note
    if [ "$AUTO_FINALIZE" -eq 1 ]; then
        finalize_note="--auto-finalize is on: this command will wait for the VM to
power off and finalize it automatically."
    else
        finalize_note="Once the VM is shut off, finalize it:

    scripts/create-vm.sh --finalize --vm \"$VM_NAME\""
    fi

    if [ -n "$CONFIG_ISO" ]; then
        cat <<EOF

Unattended install started. Watch it (optional) with:

    virt-viewer --connect $LIBVIRT_URI --attach "$VM_NAME"

Windows installs and provisions itself, then powers off on its own.
$finalize_note
EOF
    else
        cat <<EOF

Windows installer is booting. Open the console with:

    virt-viewer --connect $LIBVIRT_URI --attach "$VM_NAME"

During setup, when asked where to install Windows, choose "Load driver" and
pick the viostor driver for Windows ($WINPE_DRIVER_DIR/amd64) from the VirtIO-win CD.

When Windows is installed, run the Windows setup scripts (windows/Setup-Guest.ps1).
$finalize_note
EOF
    fi
}

# Wait for a *stable* power-off — the final shutdown, not a Windows Setup reboot
# (reboots keep the domain running via on_reboot=restart; a real poweroff goes to
# "shut off" and stays there).
wait_for_final_shutdown() {
    info "Waiting for the VM to finish and power off (this can take a while)..."
    local state stable=0
    while :; do
        state="$(virsh_ domstate "$VM_NAME" 2>/dev/null || echo unknown)"
        if [ "$state" = "shut off" ]; then
            stable=$((stable + 1))
            [ "$stable" -ge 4 ] && break   # ~20s continuously off
        else
            stable=0
        fi
        sleep 5
    done
    info "VM powered off."
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
    [ "$WIN11" -eq 1 ] && WINPE_DRIVER_DIR="w11"   # for the manual-path driver hint

    if virsh_ dominfo "$VM_NAME" >/dev/null 2>&1 && [ "$RECREATE" -eq 0 ]; then
        die "domain '$VM_NAME' already exists. Use --recreate to redefine it, or --finalize."
    fi
    if [ "$RECREATE" -eq 1 ] && virsh_ dominfo "$VM_NAME" >/dev/null 2>&1; then
        info "Removing existing domain '$VM_NAME' (--recreate)"
        virsh_ destroy "$VM_NAME" >/dev/null 2>&1 || true   # stop if running
        # Undefine so `virsh define` doesn't collide on the old UUID. Extra flags
        # clear nvram/snapshots/saved state; fall back if a flag isn't supported.
        virsh_ undefine "$VM_NAME" --nvram --snapshots-metadata --managed-save >/dev/null 2>&1 \
            || virsh_ undefine "$VM_NAME" --nvram >/dev/null 2>&1 \
            || virsh_ undefine "$VM_NAME" >/dev/null 2>&1 || true
    fi

    create_disk
    fetch_virtio_iso
    render_and_define >/dev/null
    [ "$UNATTENDED" -eq 1 ] && build_config_iso
    attach_install_media_and_start

    if [ "$AUTO_FINALIZE" -eq 1 ]; then
        wait_for_final_shutdown
        finalize
    fi
}

main "$@"
