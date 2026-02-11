#!/usr/bin/env bash
# AmiCachy — Development VM manager
# Manages a qcow2 virtual disk for rapid edit-test cycles without
# rebuilding the ISO every time.
#
# Commands:
#   create    One-time setup: partition, pacstrap (via Docker), configure
#   sync      Sync airootfs + boot entries to the disk (seconds)
#   boot      Launch the VM with QEMU/KVM + UEFI
#   shell     Mount the disk for manual inspection (subshell)
#   destroy   Remove the dev VM disk and all artifacts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DEV_DIR="${PROJECT_DIR}/dev"
DISK="${DEV_DIR}/amicachy-dev.qcow2"
OVMF_VARS="${DEV_DIR}/OVMF_VARS.fd"
MNT="/tmp/amicachy-dev-mnt"

# Configurable via environment
DISK_SIZE="${DISK_SIZE:-40G}"
RAM="${RAM:-4096}"
CPUS="${CPUS:-2}"
DOCKER_IMAGE="${DOCKER_IMAGE:-cachyos/cachyos-v3:latest}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "'$cmd' not found. Install it first."
    done
}

find_ovmf_code() {
    for f in \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
        [[ -f "$f" ]] && echo "$f" && return 0
    done
    die "OVMF firmware not found. Install the 'ovmf' or 'edk2-ovmf' package."
}

find_ovmf_vars() {
    for f in \
        /usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2/ovmf/OVMF_VARS.fd \
        /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do
        [[ -f "$f" ]] && echo "$f" && return 0
    done
    die "OVMF_VARS not found. Install the 'ovmf' or 'edk2-ovmf' package."
}

find_free_nbd() {
    for i in $(seq 0 15); do
        if [[ ! -e "/sys/block/nbd${i}/pid" ]]; then
            echo "/dev/nbd${i}"
            return 0
        fi
    done
    die "No free /dev/nbd* device found. Disconnect one first."
}

nbd_connect() {
    sudo modprobe nbd max_part=16 2>/dev/null || true
    NBD=$(find_free_nbd)
    echo ":: Connecting $DISK -> $NBD"
    sudo qemu-nbd --connect="$NBD" "$DISK"
    sleep 1
    sudo partprobe "$NBD" 2>/dev/null || true
    sleep 0.5
}

nbd_disconnect() {
    if [[ -n "${NBD:-}" ]]; then
        echo ":: Disconnecting $NBD"
        sudo qemu-nbd --disconnect "$NBD" 2>/dev/null || true
        NBD=""
    fi
}

mount_disk() {
    sudo mkdir -p "$MNT"
    echo ":: Mounting ${NBD}p2 -> $MNT"
    sudo mount "${NBD}p2" "$MNT"
    sudo mkdir -p "$MNT/boot"
    echo ":: Mounting ${NBD}p1 -> $MNT/boot"
    sudo mount "${NBD}p1" "$MNT/boot"
}

umount_disk() {
    echo ":: Unmounting $MNT"
    sudo umount "$MNT/boot" 2>/dev/null || true
    sudo umount "$MNT" 2>/dev/null || true
}

cleanup() {
    umount_disk
    nbd_disconnect
}

# Sync the project's overlay files and tools into the mounted VM root.
sync_files() {
    # 1. airootfs overlay (skip files that are live-ISO-specific)
    echo ":: Syncing airootfs overlay..."
    sudo rsync -a \
        --exclude='etc/mkinitcpio.conf' \
        --exclude='etc/fstab' \
        "$PROJECT_DIR/archiso/airootfs/" "$MNT/"

    # 2. Boot entries (only installed-system entries, not live/archiso ones)
    #    Add serial console for logging: console=ttyS0,115200
    echo ":: Syncing boot entries..."
    sudo mkdir -p "$MNT/boot/loader/entries"
    for entry in "$PROJECT_DIR"/archiso/efiboot/loader/entries/0{1,2,3}-*.conf; do
        if [[ -f "$entry" ]]; then
            local dest="$MNT/boot/loader/entries/$(basename "$entry")"
            sudo cp "$entry" "$dest"
            # Inject serial console if not already present
            if ! sudo grep -q 'console=ttyS0' "$dest" 2>/dev/null; then
                sudo sed -i 's/^options /options console=ttyS0,115200 /' "$dest"
            fi
        fi
    done

    # 3. Installer tools (bundled at build time, not in airootfs repo tree)
    echo ":: Syncing installer tools..."
    sudo mkdir -p "$MNT/usr/share/amicachy/tools/installer"
    sudo rsync -a "$PROJECT_DIR/tools/installer/" \
        "$MNT/usr/share/amicachy/tools/installer/"
    sudo cp "$PROJECT_DIR/tools/hardware_audit.py" \
        "$MNT/usr/share/amicachy/tools/"

    # 4. Fix permissions for executable scripts
    sudo chmod 755 "$MNT/usr/bin/amilaunch.sh" \
                    "$MNT/usr/bin/amicachy-installer" \
                    "$MNT/usr/bin/start_dev_env.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# create — One-time setup
# ---------------------------------------------------------------------------

cmd_create() {
    require_cmd qemu-img qemu-nbd sgdisk mkfs.fat mkfs.ext4 docker

    [[ -f "$DISK" ]] && die "Disk already exists: $DISK\nUse '$0 destroy' first."

    mkdir -p "$DEV_DIR"

    echo "========================================"
    echo "  AmiCachy — Creating development VM"
    echo "  Disk: ${DISK_SIZE}, RAM: ${RAM}M, CPUs: ${CPUS}"
    echo "========================================"
    echo ""

    # --- 1. Create qcow2 disk ---
    echo ":: Creating ${DISK_SIZE} qcow2 disk..."
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"

    # --- 2. Connect NBD ---
    nbd_connect
    trap cleanup EXIT

    # --- 3. Partition: EFI (512M) + Root (rest) ---
    echo ":: Partitioning $NBD..."
    sudo sgdisk -Z "$NBD"
    sudo sgdisk \
        -n 1:0:+512M -t 1:ef00 -c 1:EFI \
        -n 2:0:0     -t 2:8300 -c 2:AMICACHY \
        "$NBD"
    sudo partprobe "$NBD"
    sleep 1

    # --- 4. Format ---
    echo ":: Formatting partitions..."
    sudo mkfs.fat -F32 -n EFI "${NBD}p1"
    sudo mkfs.ext4 -L AMICACHY "${NBD}p2"

    # --- 5. Mount ---
    mount_disk

    # --- 6. Pacstrap via Docker ---
    # Read packages, filtering out live-ISO-only packages
    local PACKAGES
    PACKAGES=$(grep -v '^#' "$PROJECT_DIR/archiso/packages.x86_64" \
        | grep -v '^$' \
        | grep -v 'mkinitcpio-archiso' \
        | grep -v 'syslinux' \
        | tr '\n' ' ')

    echo ":: Running pacstrap inside Docker (${DOCKER_IMAGE})..."
    echo "   This will take several minutes on first run."
    echo ""

    docker run --rm --privileged \
        -v "$MNT":"$MNT" \
        -v "$PROJECT_DIR:/work" \
        "$DOCKER_IMAGE" \
        bash -c "
            set -euo pipefail

            # The CachyOS Docker image doesn't include pacstrap/arch-chroot
            echo ':: Installing arch-install-scripts inside container...'
            pacman -Sy --noconfirm arch-install-scripts

            echo ':: Initializing pacman keyring...'
            pacman-key --init
            pacman-key --populate cachyos archlinux

            # Ensure CachyOS mirrorlists are available for pacstrap
            cp /work/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist    /etc/pacman.d/
            cp /work/archiso/airootfs/etc/pacman.d/cachyos-v3-mirrorlist /etc/pacman.d/

            echo ':: Running pacstrap (this takes a while)...'
            pacstrap -C /work/archiso/pacman.conf \"$MNT\" $PACKAGES

            echo ':: Configuring system...'
            arch-chroot \"$MNT\" bash -c '
                # Generate locale
                locale-gen

                # Install systemd-boot
                bootctl install

                # Enable essential services
                systemctl enable NetworkManager || true

                # Create user amiga (may already exist from sysusers)
                if ! id amiga &>/dev/null; then
                    useradd -m -u 1000 -G wheel,audio,video -s /bin/bash amiga
                fi
                echo \"amiga:amiga\" | chpasswd
            '
        "

    # --- 7. Overlay airootfs ---
    echo ":: Applying airootfs overlay..."
    sync_files

    # --- 8. Dev-specific mkinitcpio.conf (no archiso hooks) ---
    sudo tee "$MNT/etc/mkinitcpio.conf" > /dev/null << 'EOF'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base udev plymouth autodetect modconf kms block filesystems keyboard fsck)
EOF

    # --- 9. fstab ---
    sudo tee "$MNT/etc/fstab" > /dev/null << 'EOF'
# AmiCachy dev VM
LABEL=AMICACHY  /      ext4  defaults  0 1
LABEL=EFI       /boot  vfat  defaults  0 2
EOF

    # --- 10. Boot loader config (dev defaults) ---
    sudo tee "$MNT/boot/loader/loader.conf" > /dev/null << 'EOF'
default 01-classic-68k.conf
timeout 5
editor  yes
console-mode max
EOF

    # --- 11. Rebuild initramfs with dev hooks ---
    echo ":: Rebuilding initramfs..."
    docker run --rm --privileged \
        -v "$MNT":"$MNT" \
        "$DOCKER_IMAGE" \
        bash -c "pacman -Sy --noconfirm arch-install-scripts && arch-chroot \"$MNT\" mkinitcpio -P"

    # --- 12. Cleanup ---
    umount_disk
    nbd_disconnect
    trap - EXIT

    # --- 13. Prepare OVMF vars ---
    if [[ ! -f "$OVMF_VARS" ]]; then
        cp "$(find_ovmf_vars)" "$OVMF_VARS"
    fi

    echo ""
    echo "========================================"
    echo "  Dev VM created successfully!"
    echo ""
    echo "  Disk:  $DISK"
    echo "  OVMF:  $OVMF_VARS"
    echo ""
    echo "  Next steps:"
    echo "    $0 boot            # launch the VM"
    echo "    $0 sync && $0 boot # after editing files"
    echo "========================================"
}

# ---------------------------------------------------------------------------
# sync — Fast iteration (seconds)
# ---------------------------------------------------------------------------

cmd_sync() {
    require_cmd qemu-nbd rsync

    [[ -f "$DISK" ]] || die "No dev disk found. Run '$0 create' first."

    echo ":: Syncing changes to dev VM..."
    nbd_connect
    trap cleanup EXIT

    mount_disk
    sync_files
    umount_disk
    nbd_disconnect
    trap - EXIT

    echo ""
    echo ":: Sync complete. Run '$0 boot' to test."
}

# ---------------------------------------------------------------------------
# boot — Launch QEMU/KVM
# ---------------------------------------------------------------------------

cmd_boot() {
    require_cmd qemu-system-x86_64

    [[ -f "$DISK" ]] || die "No dev disk found. Run '$0 create' first."

    local OVMF_CODE
    OVMF_CODE="$(find_ovmf_code)"

    if [[ ! -f "$OVMF_VARS" ]]; then
        cp "$(find_ovmf_vars)" "$OVMF_VARS"
    fi

    # Detect audio backend
    local AUDIO_ARGS=()
    if pgrep -x pipewire &>/dev/null; then
        AUDIO_ARGS=(-audiodev pipewire,id=snd0)
    elif pgrep -x pulseaudio &>/dev/null; then
        AUDIO_ARGS=(-audiodev pa,id=snd0)
    else
        AUDIO_ARGS=(-audiodev sdl,id=snd0)
    fi

    # Detect display backend — prefer GL for Wayland compositors in the guest
    local DISPLAY_ARGS
    local VGA_DEVICE
    if [[ "${DISPLAY_MODE:-auto}" == "safe" ]]; then
        VGA_DEVICE="virtio-vga"
        DISPLAY_ARGS="-display gtk"
    else
        VGA_DEVICE="virtio-vga-gl"
        DISPLAY_ARGS="-display gtk,gl=on"
    fi

    # Serial console log — captures all kernel and service output
    local BOOT_LOG="${DEV_DIR}/boot.log"
    : > "$BOOT_LOG"  # truncate previous log

    echo ":: Booting AmiCachy dev VM"
    echo "   RAM: ${RAM}M | CPUs: ${CPUS} | Audio: ${AUDIO_ARGS[1]%%,*}"
    echo "   Disk: $DISK"
    echo "   Log:  $BOOT_LOG"
    echo "   SSH:  ssh -p 2222 amiga@localhost (password: amiga)"
    echo ""
    echo "   Tip: In another terminal, run: $0 log"
    echo ""

    qemu-system-x86_64 \
        -enable-kvm \
        -machine q35 \
        -cpu host \
        -m "$RAM" \
        -smp "$CPUS" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS" \
        -drive file="$DISK",format=qcow2,if=virtio \
        -device "$VGA_DEVICE" \
        $DISPLAY_ARGS \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        "${AUDIO_ARGS[@]}" \
        -device ich9-intel-hda \
        -device hda-duplex,audiodev=snd0 \
        -serial file:"$BOOT_LOG" \
        -usb \
        -device usb-tablet
}

# ---------------------------------------------------------------------------
# shell — Interactive mount for manual editing
# ---------------------------------------------------------------------------

cmd_shell() {
    require_cmd qemu-nbd

    [[ -f "$DISK" ]] || die "No dev disk found. Run '$0 create' first."

    nbd_connect
    trap cleanup EXIT
    mount_disk

    echo ""
    echo "========================================"
    echo "  AmiCachy dev VM mounted at: $MNT"
    echo ""
    echo "  Root FS:    $MNT/"
    echo "  EFI/Boot:   $MNT/boot/"
    echo "  Boot entries: $MNT/boot/loader/entries/"
    echo "  Amiga home: $MNT/home/amiga/"
    echo "  UAE configs: $MNT/usr/share/amicachy/uae/"
    echo ""
    echo "  Type 'exit' to unmount and disconnect."
    echo "========================================"
    echo ""

    (cd "$MNT" && exec bash) || true

    umount_disk
    nbd_disconnect
    trap - EXIT
    echo ":: Disk unmounted and disconnected."
}

# ---------------------------------------------------------------------------
# destroy — Remove everything
# ---------------------------------------------------------------------------

cmd_destroy() {
    if [[ ! -d "$DEV_DIR" ]]; then
        echo "Nothing to destroy (no dev/ directory)."
        return
    fi

    echo "Will delete:"
    ls -lh "$DEV_DIR/" 2>/dev/null
    echo ""
    read -rp "Are you sure? [y/N] " answer
    [[ "$answer" =~ ^[yY]$ ]] || { echo "Aborted."; exit 0; }

    rm -rf "$DEV_DIR"
    echo ":: Dev VM destroyed."
}

# ---------------------------------------------------------------------------
# log — Tail the boot log
# ---------------------------------------------------------------------------

cmd_log() {
    local BOOT_LOG="${DEV_DIR}/boot.log"

    if [[ ! -f "$BOOT_LOG" ]]; then
        die "No boot log found. Boot the VM first with '$0 boot'."
    fi

    if [[ "${1:-}" == "--full" ]]; then
        cat "$BOOT_LOG"
    else
        echo ":: Tailing $BOOT_LOG (Ctrl+C to stop)"
        echo "   Use '$0 log --full' to see the complete log"
        echo ""
        tail -f "$BOOT_LOG"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

usage() {
    cat << 'USAGE'
AmiCachy Development VM Manager

Usage: ./tools/dev_vm.sh <command>

Commands:
  create    Create the dev disk and install the system (one-time, uses Docker)
  sync      Sync airootfs + boot entries to the disk (fast, seconds)
  boot      Launch the VM with QEMU/KVM + UEFI
  log       Tail the boot/serial log (--full for complete log)
  shell     Mount the disk for manual inspection (interactive subshell)
  destroy   Remove the dev VM disk and all artifacts

Environment variables:
  DISK_SIZE       Disk image size          (default: 40G)
  RAM             VM memory in MB          (default: 4096)
  CPUS            Number of vCPUs          (default: 2)
  DOCKER_IMAGE    Docker image for pacstrap (default: cachyos/cachyos-v3:latest)
  DISPLAY_MODE    "auto" (GL) or "safe"    (default: auto)

Typical workflow:
  ./tools/dev_vm.sh create               # first time (slow, uses Docker)
  ./tools/dev_vm.sh boot                 # test it
  vim archiso/airootfs/usr/bin/amilaunch.sh   # edit something
  ./tools/dev_vm.sh sync                 # push changes (seconds)
  ./tools/dev_vm.sh boot                 # test again

  RAM=8192 CPUS=4 ./tools/dev_vm.sh boot # more resources
  DISPLAY_MODE=safe ./tools/dev_vm.sh boot  # no GL (fallback)
USAGE
    exit 0
}

NBD=""  # global, set by nbd_connect

case "${1:-}" in
    create)  cmd_create  ;;
    sync)    cmd_sync    ;;
    boot)    cmd_boot    ;;
    log)     shift; cmd_log "$@" ;;
    shell)   cmd_shell   ;;
    destroy) cmd_destroy ;;
    -h|--help|"") usage  ;;
    *) die "Unknown command: $1. Run '$0 --help'." ;;
esac
