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

# CPU arch detection — auto-selects DOCKER_IMAGE and CPU_ARCH_LEVEL
# shellcheck source=lib/cpu_arch.sh
source "${SCRIPT_DIR}/lib/cpu_arch.sh"

# Configurable via environment
DISK_SIZE="${DISK_SIZE:-40G}"
RAM="${RAM:-4096}"
CPUS="${CPUS:-2}"

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
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/edk2/x64/OVMF_CODE.fd; do
        [[ -f "$f" ]] && echo "$f" && return 0
    done
    die "OVMF firmware not found. Install the 'ovmf' or 'edk2-ovmf' package."
}

find_ovmf_vars() {
    for f in \
        /usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2/ovmf/OVMF_VARS.fd \
        /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
        /usr/share/edk2/x64/OVMF_VARS.4m.fd \
        /usr/share/edk2/x64/OVMF_VARS.fd; do
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
    #    Add serial console for dev logging (tty0 first to keep Plymouth on screen)
    echo ":: Syncing boot entries..."
    sudo mkdir -p "$MNT/boot/loader/entries"
    for entry in "$PROJECT_DIR"/archiso/efiboot/loader/entries/0{1,2,3,4}-*.conf; do
        if [[ -f "$entry" ]]; then
            local dest="$MNT/boot/loader/entries/$(basename "$entry")"
            sudo cp "$entry" "$dest"
            # Always inject VM-specific kernel params from the clean repo copy.
            # The cp above gives us the original options line; append VM extras.
            # NOTE: we do NOT add console=ttyS0 because Plymouth detects serial
            # consoles and forces text-only "details" mode instead of the
            # graphical theme.  QEMU still captures serial via -serial file:
            # but without a kernel console= directive the log will be empty.
            sudo sed -i '/^options / {
                s/ console=tty[0-9S,]*//g
                s/ plymouth\.[a-z-]*//g
            }' "$dest"
        fi
    done

    # 3. Installer tools (bundled at build time, not in airootfs repo tree)
    echo ":: Syncing installer tools..."
    sudo mkdir -p "$MNT/usr/share/amicachy/tools/installer"
    sudo rsync -a "$PROJECT_DIR/tools/installer/" \
        "$MNT/usr/share/amicachy/tools/installer/"
    sudo cp "$PROJECT_DIR/tools/hardware_audit.py" \
        "$MNT/usr/share/amicachy/tools/"

    # 3b. Early Startup Control tools
    echo ":: Syncing earlystartup tools..."
    sudo mkdir -p "$MNT/usr/share/amicachy/tools/earlystartup"
    sudo rsync -a "$PROJECT_DIR/tools/earlystartup/" \
        "$MNT/usr/share/amicachy/tools/earlystartup/"

    # 3c. Asset Library tools (fetch_asset)
    echo ":: Syncing fetch_asset tools..."
    sudo mkdir -p "$MNT/usr/share/amicachy/tools/fetch_asset"
    sudo rsync -a "$PROJECT_DIR/tools/fetch_asset/" \
        "$MNT/usr/share/amicachy/tools/fetch_asset/"

    # 4. Fix permissions for executable scripts
    sudo chmod 755 "$MNT/usr/bin/amilaunch.sh" \
                    "$MNT/usr/bin/amicachy-installer" \
                    "$MNT/usr/bin/amicachy-earlystartup" \
                    "$MNT/usr/bin/amicachy-fetch-asset" \
                    "$MNT/usr/bin/amicachy-link-host-assets" \
                    "$MNT/usr/bin/amicachy-seed-assets" \
                    "$MNT/usr/bin/start_dev_env.sh" 2>/dev/null || true

    # 5. Fix ownership: rsync -a preserves host uid which maps to amiga (1000)
    #    inside the VM. System dirs must be root-owned.
    sudo chown -R root:root "$MNT/etc/sudoers.d" 2>/dev/null || true
    sudo chmod 750 "$MNT/etc/sudoers.d" 2>/dev/null || true
    sudo chmod 440 "$MNT/etc/sudoers.d/"* 2>/dev/null || true
    sudo chown -R root:root "$MNT/etc/systemd" 2>/dev/null || true
    sudo chown -R root:root "$MNT/etc/sysusers.d" 2>/dev/null || true
    sudo chown root:root "$MNT/etc/vconsole.conf" "$MNT/etc/hostname" \
                          "$MNT/etc/locale.conf" "$MNT/etc/locale.gen" 2>/dev/null || true
    # Amiberry data dir must be writable by amiga (creates configs at runtime)
    sudo chown -R 1000:1000 "$MNT/usr/share/amiberry" 2>/dev/null || true

    # 6. Install real SDL2 library if built (bypasses sdl2-compat SIGSEGV)
    local sdl2_real="$PROJECT_DIR/out/libSDL2-real"
    if [[ -f "$sdl2_real/libSDL2-2.0.so.0" ]]; then
        echo ":: Installing real SDL2 library (bypasses sdl2-compat)..."
        sudo mkdir -p "$MNT/usr/local/lib"
        sudo cp -a "$sdl2_real"/libSDL2* "$MNT/usr/local/lib/"
    fi

    # 7. Ensure VM's /etc/pacman.conf matches CPU arch level
    #    On generic CPUs, remove [cachyos-v3] repo to prevent SIGILL
    if [[ "$CPU_ARCH_LEVEL" == "x86-64" ]]; then
        if sudo grep -q '\[cachyos-v3\]' "$MNT/etc/pacman.conf" 2>/dev/null; then
            echo ":: Removing [cachyos-v3] repo from VM (CPU lacks AVX2)..."
            sudo sed -i '/^\[cachyos-v3\]/,/^$/d' "$MNT/etc/pacman.conf"
        fi
    fi

    # 8. Regenerate locale if locale-archive is missing or stale
    if [[ ! -f "$MNT/usr/lib/locale/locale-archive" ]]; then
        echo ":: Generating locale..."
        sudo chroot "$MNT" locale-gen
    fi

    # 9. Register Plymouth theme (creates default.plymouth symlink)
    #    plymouth-set-default-theme needs /proc etc. inside the chroot and may
    #    silently succeed without creating the symlink.  Just create it directly.
    echo ":: Registering Plymouth theme 'amicachy'..."
    sudo ln -sfn amicachy/amicachy.plymouth "$MNT/usr/share/plymouth/themes/default.plymouth"

    # 9b. Dev-VM-only journald drop-in: mirror the journal to ttyS1 so QEMU
    #     can capture it via -serial file:. Plymouth stays on ttyS0 untouched
    #     (no kernel console= directive there, so its detection logic is happy).
    #     This file lives only on the dev disk; the ISO is never modified.
    echo ":: Installing dev-VM journald drop-in (forward to ttyS1)..."
    sudo mkdir -p "$MNT/etc/systemd/journald.conf.d"
    sudo tee "$MNT/etc/systemd/journald.conf.d/99-amicachy-dev-serial.conf" >/dev/null << 'EOF'
# AmiCachy dev VM — generated by tools/dev_vm.sh
[Journal]
ForwardToConsole=yes
TTYPath=/dev/ttyS1
MaxLevelConsole=debug
EOF

    # 10. Ensure Plymouth is in the initramfs (boot splash)
    #     The ISO's mkinitcpio.conf has archiso-specific hooks; don't use it.
    #     The VM needs virtio_gpu in MODULES for early DRM (Plymouth rendering).
    local need_mkinitcpio=false

    # Write the correct config if needed (check content matches expected)
    # Plymouth MUST come before kms (or kms omitted entirely).
    # Reason: simpledrm (built-in) creates card0 from the UEFI framebuffer,
    # which is what QEMU actually displays. Plymouth renders on it. If kms
    # loads virtio_gpu first, it unbinds simpledrm via aperture cleanup and
    # Plymouth renders on virtio_gpu which doesn't support dumb-buffer mmap
    # properly (virgl mode, -host_visible). Without kms in the initramfs,
    # virtio_gpu loads later from the real root — after Plymouth has finished.
    local expected_hooks='HOOKS=(base udev autodetect modconf plymouth block filesystems keyboard fsck)'
    if ! sudo grep -qF "$expected_hooks" "$MNT/etc/mkinitcpio.conf" 2>/dev/null \
       || ! sudo grep -q 'libpng' "$MNT/etc/mkinitcpio.conf" 2>/dev/null; then
        echo ":: Configuring mkinitcpio for VM (plymouth on simpledrm, no kms)..."
        # FILES: force-include libpng — Plymouth's script.so needs it for
        # Image() but the mkinitcpio hook doesn't trace the dlopen dependency.
        printf '%s\n' \
            '# AmiCachy dev VM — generated by dev_vm.sh sync' \
            'MODULES=()' \
            'BINARIES=()' \
            'FILES=(/usr/lib/libpng16.so.16)' \
            'HOOKS=(base udev autodetect modconf plymouth block filesystems keyboard fsck)' \
            | sudo tee "$MNT/etc/mkinitcpio.conf" >/dev/null
        need_mkinitcpio=true
    fi

    # Always rebuild the initramfs — theme files, hooks, and config are all
    # baked in, and detecting every possible change reliably is fragile.
    # mkinitcpio -P takes ~10s which is acceptable for a dev workflow.
    need_mkinitcpio=true

    if $need_mkinitcpio; then
        sudo mount --bind /proc "$MNT/proc"
        sudo mount --bind /sys  "$MNT/sys"
        sudo mount --bind /dev  "$MNT/dev"
        # Neutralize host locale (e.g. es_ES.UTF-8) — the chroot has not
        # generated it yet, so every subprocess would emit setlocale warnings.
        sudo chroot "$MNT" env LC_ALL=C LANG=C mkinitcpio -P
        sudo umount "$MNT/proc" "$MNT/sys" "$MNT/dev"
    fi
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

    # Generate appropriate pacman.conf for this CPU's arch level
    local PACMAN_CONF
    PACMAN_CONF=$(get_pacman_conf "$PROJECT_DIR/archiso/pacman.conf")

    # Wire up the local repo for amiberry (and any other in-tree packages),
    # mirroring what build_iso.sh does so dev_vm and the shipped ISO install
    # the same way. Skipped if no .pkg.tar.zst is present in out/ — in that
    # case the user can still install amiberry post-create with `dev_vm.sh
    # install out/amiberry-*.pkg.tar.zst`.
    local LOCAL_REPO="${DEV_DIR}/local-repo"
    rm -rf "$LOCAL_REPO"
    local local_pkgs=()
    for f in "${PROJECT_DIR}/out/"amiberry-*.pkg.tar.zst; do
        [[ -f "$f" ]] && local_pkgs+=("$f")
    done
    if [[ ${#local_pkgs[@]} -gt 0 ]]; then
        require_cmd repo-add
        mkdir -p "$LOCAL_REPO"
        # Latest by name (amiberry-7.1.1-2 sorts after -1)
        cp "${local_pkgs[-1]}" "$LOCAL_REPO/"
        echo ":: Local repo: $(basename "${local_pkgs[-1]}")"
        repo-add "${LOCAL_REPO}/amicachy-local.db.tar.gz" "${LOCAL_REPO}"/*.pkg.tar.zst >/dev/null

        local PACMAN_DEV_CONF="${DEV_DIR}/pacman-dev.conf"
        cp "$PACMAN_CONF" "$PACMAN_DEV_CONF"
        cat >> "$PACMAN_DEV_CONF" <<EOF

[amicachy-local]
SigLevel = Never
Server = file:///work/dev/local-repo
EOF
        PACMAN_CONF="$PACMAN_DEV_CONF"
        PACKAGES="$PACKAGES amiberry"
    else
        echo ":: WARNING: no amiberry-*.pkg.tar.zst in out/ — VM won't have amiberry"
        echo "   Build it first: ./tools/build_amiberry.sh"
    fi

    echo ":: Running pacstrap inside Docker (${DOCKER_IMAGE})..."
    echo "   CPU arch level: ${CPU_ARCH_LEVEL}"
    echo "   This will take several minutes on first run."
    echo ""

    # If we built a custom pacman.conf (generic CPU or local repo), mount
    # it into the container as /work/archiso/pacman-build.conf so the
    # bash-c block below picks it up via the existing override mechanism.
    local EXTRA_DOCKER_ARGS=()
    if [[ "$PACMAN_CONF" != "$PROJECT_DIR/archiso/pacman.conf" ]]; then
        EXTRA_DOCKER_ARGS=(-v "${PACMAN_CONF}:/work/archiso/pacman-build.conf:ro")
    fi

    docker run --rm --privileged \
        -v "$MNT":"$MNT" \
        -v "$PROJECT_DIR:/work" \
        "${EXTRA_DOCKER_ARGS[@]}" \
        -e "CPU_ARCH_LEVEL=$CPU_ARCH_LEVEL" \
        "$DOCKER_IMAGE" \
        bash -c "
            set -euo pipefail

            # Select the right pacman.conf inside the container
            if [[ -f /work/archiso/pacman-build.conf ]]; then
                PACMAN_CONF=/work/archiso/pacman-build.conf
                echo ':: Using generic pacman.conf (CPU lacks AVX2)'
            else
                PACMAN_CONF=/work/archiso/pacman.conf
            fi

            # The CachyOS Docker image doesn't include pacstrap/arch-chroot
            echo ':: Installing arch-install-scripts inside container...'
            pacman -Sy --noconfirm arch-install-scripts

            echo ':: Initializing pacman keyring...'
            pacman-key --init
            pacman-key --populate cachyos archlinux

            # Ensure CachyOS mirrorlists are available for pacstrap
            cp /work/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist    /etc/pacman.d/
            if [[ -f /work/archiso/airootfs/etc/pacman.d/cachyos-v3-mirrorlist ]]; then
                cp /work/archiso/airootfs/etc/pacman.d/cachyos-v3-mirrorlist /etc/pacman.d/
            fi

            echo ':: Running pacstrap (this takes a while)...'
            pacstrap -C \"\$PACMAN_CONF\" \"$MNT\" $PACKAGES

            # Copy locale config before generating (overlay comes later)
            cp /work/archiso/airootfs/etc/locale.gen  \"$MNT/etc/locale.gen\"
            cp /work/archiso/airootfs/etc/locale.conf \"$MNT/etc/locale.conf\"

            echo ':: Configuring system...'
            arch-chroot \"$MNT\" bash -c '
                # Generate locale (locale.gen already in place)
                locale-gen

                # Install systemd-boot
                bootctl install

                # Enable essential services
                systemctl enable NetworkManager || true

                # Create user amiga (may already exist from sysusers)
                if ! id amiga &>/dev/null; then
                    useradd -m -u 1000 -G wheel,audio,video,input -s /bin/bash amiga
                fi
                echo \"amiga:amiga\" | chpasswd
            '
        "

    # --- 7. Overlay airootfs ---
    echo ":: Applying airootfs overlay..."
    sync_files

    # --- 8. fstab (static for dev VM) ---
    sudo tee "$MNT/etc/fstab" > /dev/null << 'EOF'
# AmiCachy dev VM
LABEL=AMICACHY  /      ext4  defaults  0 1
LABEL=EFI       /boot  vfat  defaults  0 2
EOF

    # --- 9. Boot loader config (dev defaults) ---
    sudo tee "$MNT/boot/loader/loader.conf" > /dev/null << 'EOF'
default 01-classic-68k.conf
timeout 5
editor  yes
console-mode max
EOF

    # --- 10. Cleanup ---
    umount_disk
    nbd_disconnect
    trap - EXIT

    # --- 11. Prepare OVMF vars ---
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

    # virtiofs share for host-side ROMs/HDFs (read-only by default).
    # Mirrors the guest's /run/host-amiga to ASSET_DIR on the host.
    # Only enabled when both ASSET_DIR and a virtiofsd binary are present;
    # otherwise the VM boots normally with no shared assets.
    local ASSET_DIR="${ASSET_DIR:-$HOME/Amiberry}"
    local VIRTIOFSD_BIN=""
    local VIRTIOFS_SOCK="${DEV_DIR}/virtiofs-assets.sock"
    local VIRTIOFS_PID=""
    local VIRTIOFS_QEMU_ARGS=()
    local MEM_BACKEND_ARGS=()
    local RW_LABEL="rw"
    for cand in /usr/lib/virtiofsd /usr/libexec/virtiofsd /usr/lib/qemu/virtiofsd "$(command -v virtiofsd 2>/dev/null)"; do
        [[ -n "$cand" && -x "$cand" ]] && { VIRTIOFSD_BIN="$cand"; break; }
    done
    if [[ -d "$ASSET_DIR" && -n "$VIRTIOFSD_BIN" ]]; then
        # RW by default (opt-in to read-only via ASSET_RO=1).
        local RW_FLAG=""
        if [[ "${ASSET_RO:-0}" == "1" ]]; then
            RW_FLAG="--readonly"
            RW_LABEL="ro"
        fi
        # Reap any orphan virtiofsd that might still hold the pidfile lock
        # (e.g. a prior boot whose QEMU crashed before our trap fired).
        if [[ -f "${VIRTIOFS_SOCK}.pid" ]]; then
            local _stale_pid
            _stale_pid="$(cat "${VIRTIOFS_SOCK}.pid" 2>/dev/null || true)"
            [[ -n "$_stale_pid" ]] && kill "$_stale_pid" 2>/dev/null || true
        fi
        pkill -f "virtiofsd .* --socket-path=${VIRTIOFS_SOCK}" 2>/dev/null || true
        rm -f "$VIRTIOFS_SOCK" "${VIRTIOFS_SOCK}.pid"
        echo ":: Starting virtiofsd ($RW_LABEL): $ASSET_DIR -> guest tag 'amicachy-assets'"
        "$VIRTIOFSD_BIN" \
            --socket-path="$VIRTIOFS_SOCK" \
            --shared-dir="$ASSET_DIR" \
            --sandbox=none \
            $RW_FLAG \
            >"${DEV_DIR}/virtiofsd.log" 2>&1 &
        VIRTIOFS_PID=$!
        # Wait for socket. Use pre-increment so the arithmetic command never
        # returns a non-zero status (post-increment from 0 would trip set -e).
        local _vtries=0
        while [[ ! -S "$VIRTIOFS_SOCK" && $_vtries -lt 40 ]]; do
            sleep 0.1
            ((++_vtries))
        done
        if [[ -S "$VIRTIOFS_SOCK" ]]; then
            MEM_BACKEND_ARGS=(
                -object "memory-backend-memfd,id=mem,size=${RAM}M,share=on"
                -numa "node,memdev=mem"
            )
            VIRTIOFS_QEMU_ARGS=(
                -chardev "socket,id=char-assets,path=${VIRTIOFS_SOCK}"
                -device "vhost-user-fs-pci,queue-size=1024,chardev=char-assets,tag=amicachy-assets"
            )
        else
            echo "   WARN: virtiofsd socket did not appear; booting WITHOUT host share."
            echo "   See ${DEV_DIR}/virtiofsd.log for details."
            kill "$VIRTIOFS_PID" 2>/dev/null || true
            VIRTIOFS_PID=""
        fi
    elif [[ ! -d "$ASSET_DIR" ]]; then
        echo ":: ASSET_DIR='$ASSET_DIR' not found — booting WITHOUT host share."
    elif [[ -z "$VIRTIOFSD_BIN" ]]; then
        echo ":: virtiofsd not installed — booting WITHOUT host share. (pacman -S virtiofsd)"
    fi

    # Serial logs:
    #   ttyS0 -> boot.log:    firmware / early-boot output. Mostly empty
    #                         because we do NOT pass console=ttyS0 (Plymouth
    #                         would drop out of graphical mode if we did).
    #   ttyS1 -> journal.log: full systemd journal, mirrored here by the
    #                         dev-VM journald drop-in (see sync_files step 9b).
    local BOOT_LOG="${DEV_DIR}/boot.log"
    local JOURNAL_LOG="${DEV_DIR}/journal.log"
    : > "$BOOT_LOG"
    : > "$JOURNAL_LOG"

    echo ":: Booting AmiCachy dev VM"
    echo "   RAM: ${RAM}M | CPUs: ${CPUS} | Audio: ${AUDIO_ARGS[1]%%,*}"
    echo "   Disk:    $DISK"
    echo "   Journal: $JOURNAL_LOG  (ttyS1 — systemd journal)"
    echo "   Serial:  $BOOT_LOG     (ttyS0 — firmware/early boot)"
    echo "   SSH:     ssh -p 2222 amiga@localhost (password: amiga)"
    [[ -n "$VIRTIOFS_PID" ]] && echo "   Assets:  $ASSET_DIR ($RW_LABEL via virtiofs, mounted as /run/host-amiga)"
    echo ""
    echo "   Tip: In another terminal, run: $0 log              # journal"
    echo "        $0 log --serial    # raw ttyS0"
    echo "   Ctrl+C sends ACPI shutdown (clean). Close window also works."
    echo ""

    # QMP socket for sending ACPI shutdown on Ctrl+C instead of killing QEMU
    local QMP_SOCK="${DEV_DIR}/qmp.sock"
    rm -f "$QMP_SOCK"

    # Helper: send QMP command via Python (no socat dependency)
    _qmp_send() {
        python3 -c "
import socket, json, sys
s = socket.socket(socket.AF_UNIX)
try:
    s.settimeout(3)
    s.connect('$QMP_SOCK')
    s.recv(4096)  # greeting
    s.send(b'{\"execute\": \"qmp_capabilities\"}\n')
    s.recv(4096)  # response
    for cmd in sys.argv[1:]:
        s.send(('{\"execute\": \"' + cmd + '\"}\n').encode())
        s.recv(4096)
    s.close()
except Exception as e:
    print(f'QMP: {e}', file=sys.stderr)
    sys.exit(1)
" "$@"
    }

    # Run QEMU in its own session (setsid) so Ctrl+C does NOT reach it.
    # Our trap handler sends ACPI shutdown via QMP instead.
    # -w: wait for child even if setsid forks (PG leader case).
    setsid -w qemu-system-x86_64 \
        -enable-kvm \
        -machine q35 \
        -cpu host \
        -m "$RAM" \
        -smp "$CPUS" \
        "${MEM_BACKEND_ARGS[@]}" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS" \
        -drive file="$DISK",format=qcow2,if=none,id=hd0,cache=writethrough \
        -device virtio-blk-pci,drive=hd0,bootindex=1 \
        -device "$VGA_DEVICE" \
        $DISPLAY_ARGS \
        -device virtio-net-pci,netdev=net0,bootindex=99 \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        "${AUDIO_ARGS[@]}" \
        -device ich9-intel-hda \
        -device hda-duplex,audiodev=snd0 \
        -serial file:"$BOOT_LOG" \
        -serial file:"$JOURNAL_LOG" \
        -usb \
        -device usb-tablet \
        "${VIRTIOFS_QEMU_ARGS[@]}" \
        -qmp unix:"$QMP_SOCK",server,nowait &

    local QEMU_PID=$!

    # Wait for QMP socket and negotiate capabilities
    local _tries=0
    while [[ ! -S "$QMP_SOCK" && $_tries -lt 20 ]]; do
        sleep 0.25
        ((_tries++))
    done
    _qmp_send >/dev/null 2>&1  # capabilities handshake (no extra command)

    # Trap Ctrl+C: send ACPI powerdown instead of killing QEMU instantly.
    # QEMU is in its own session (setsid) so it does NOT receive the SIGINT.
    # Second Ctrl+C force-kills QEMU.
    trap '
        echo ""
        echo ":: Sending ACPI shutdown to guest (clean powerdown)..."
        if _qmp_send system_powerdown 2>/dev/null; then
            echo "   Waiting for VM to power off... (Ctrl+C again to force kill)"
            trap "echo \"   Force killing QEMU.\"; kill '"$QEMU_PID"' 2>/dev/null" INT
        else
            echo "   QMP failed — killing QEMU directly."
            kill '"$QEMU_PID"' 2>/dev/null
        fi
    ' INT TERM

    # Wait in a loop: trap interrupts wait, but we re-wait until QEMU exits.
    while kill -0 "$QEMU_PID" 2>/dev/null; do
        wait "$QEMU_PID" 2>/dev/null
    done
    rm -f "$QMP_SOCK"

    # Tear down virtiofsd if we started it.
    if [[ -n "$VIRTIOFS_PID" ]]; then
        kill "$VIRTIOFS_PID" 2>/dev/null || true
        wait "$VIRTIOFS_PID" 2>/dev/null || true
        rm -f "$VIRTIOFS_SOCK" "${VIRTIOFS_SOCK}.pid"
    fi
    trap - INT TERM
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
# install — Install packages into the VM via Docker (local .pkg.tar.zst or repo names)
# ---------------------------------------------------------------------------

cmd_install() {
    local args=("$@")

    [[ ${#args[@]} -eq 0 ]] && die "Usage: $0 install <package.pkg.tar.zst|package-name> ..."
    [[ -f "$DISK" ]] || die "No dev disk found. Run '$0 create' first."

    require_cmd qemu-nbd docker

    # Separate local files from repo package names
    local abs_pkgs=() repo_pkgs=()
    for arg in "${args[@]}"; do
        if [[ -f "$arg" ]]; then
            abs_pkgs+=("$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")")
        else
            repo_pkgs+=("$arg")
        fi
    done

    nbd_connect
    trap cleanup EXIT
    mount_disk

    # --- Install local .pkg.tar.zst files ---
    if [[ ${#abs_pkgs[@]} -gt 0 ]]; then
        local staging="${DEV_DIR}/.install-staging"
        rm -rf "$staging"
        mkdir -p "$staging"
        local chroot_pkgs=()
        for pkg in "${abs_pkgs[@]}"; do
            local base
            base=$(basename "$pkg")
            cp "$pkg" "$staging/"
            chroot_pkgs+=("/var/cache/pacman/pkg/$base")
            echo ":: Local package: $base"
        done

        echo ":: Installing local packages via Docker + arch-chroot..."
        docker run --rm --privileged \
            -v "$MNT":"$MNT" \
            -v "$PROJECT_DIR:/work" \
            "$DOCKER_IMAGE" \
            bash -c "
                set -euo pipefail
                pacman -Sy --noconfirm arch-install-scripts &>/dev/null

                echo ':: Copying packages into VM disk...'
                cp -v /work/dev/.install-staging/*.pkg.tar.zst \"$MNT/var/cache/pacman/pkg/\"

                # Refresh the chroot's pacman DB so new deps introduced by
                # the local package can be resolved against current mirrors
                # (the disk's DB is frozen at create-time and may point at
                # versions the mirrors no longer carry).
                echo ':: Refreshing chroot pacman DB...'
                arch-chroot \"$MNT\" pacman -Sy --noconfirm

                echo ':: Running arch-chroot pacman -U...'
                arch-chroot \"$MNT\" pacman -U ${chroot_pkgs[*]} --noconfirm
            "
        rm -rf "$staging"
    fi

    # --- Install repo packages ---
    if [[ ${#repo_pkgs[@]} -gt 0 ]]; then
        echo ":: Installing repo packages: ${repo_pkgs[*]}"
        docker run --rm --privileged \
            -v "$MNT":"$MNT" \
            "$DOCKER_IMAGE" \
            bash -c "
                set -euo pipefail
                pacman -Sy --noconfirm arch-install-scripts &>/dev/null
                arch-chroot \"$MNT\" pacman -Sy --noconfirm ${repo_pkgs[*]}
            "
    fi

    umount_disk
    nbd_disconnect
    trap - EXIT

    echo ""
    echo ":: Packages installed successfully."
    echo "   Run '$0 boot' to test."
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
    # Default: systemd journal mirrored on ttyS1 (the useful one).
    # --serial: raw ttyS0 (firmware / early boot, usually mostly empty).
    # --full:   cat the whole file instead of tail -f.
    local target="journal"
    local mode="follow"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --serial)  target="serial" ;;
            --journal) target="journal" ;;
            --full)    mode="full" ;;
            *) die "Unknown log flag: $1 (use --serial / --journal / --full)" ;;
        esac
        shift
    done

    local LOG_FILE
    case "$target" in
        journal) LOG_FILE="${DEV_DIR}/journal.log" ;;
        serial)  LOG_FILE="${DEV_DIR}/boot.log" ;;
    esac

    if [[ ! -f "$LOG_FILE" ]]; then
        die "No $target log found at $LOG_FILE. Boot the VM first with '$0 boot'."
    fi

    if [[ "$mode" == "full" ]]; then
        cat "$LOG_FILE"
    else
        echo ":: Tailing $LOG_FILE (Ctrl+C to stop)"
        echo "   Flags: --serial (ttyS0)  --journal (default, ttyS1)  --full (cat)"
        echo ""
        tail -f "$LOG_FILE"
    fi
}

# ---------------------------------------------------------------------------
# boot-iso — Boot a built ISO under plain QEMU (same hardware setup as
#            'boot'), so we get virtio-vga-gl, host CPU and direct keyboard
#            instead of the libvirt+spice path that ate F5 keypresses.
# ---------------------------------------------------------------------------

cmd_boot_iso() {
    local iso_path="${1:-}"
    [[ -n "$iso_path" ]] || die "Usage: $0 boot-iso <ISO_PATH> [--scratch PATH] [--reset-scratch] [--persist [PATH]] [--persist-size SIZE] [--reset-persist]"
    [[ -f "$iso_path" ]] || die "ISO not found: $iso_path"
    iso_path="$(realpath "$iso_path")"

    local SCRATCH="${DEV_DIR}/test-iso-scratch.qcow2"
    local OVMF_VARS_TI="${DEV_DIR}/OVMF_VARS-test-iso.fd"
    local SCRATCH_SIZE="${SCRATCH_SIZE:-64G}"
    local RESET_SCRATCH=0
    # Persistent data partition (label AMICACHY_DATA) attached as a second
    # USB stick. Lets the live ISO behave like a real pendrive with a
    # second writable partition.
    local PERSIST=""           # path to .img file; empty = disabled
    local PERSIST_SIZE="${PERSIST_SIZE:-32G}"
    local PERSIST_FS="${PERSIST_FS:-ntfs}"   # ntfs | exfat | ext4
    local RESET_PERSIST=0
    local PERSIST_DEFAULT="${DEV_DIR}/test-iso-persist.img"

    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scratch)       SCRATCH="$2"; shift 2 ;;
            --reset-scratch) RESET_SCRATCH=1; shift ;;
            --persist)
                # Optional argument: if next arg looks like a flag or is missing,
                # use the default path.
                if [[ $# -ge 2 && "$2" != --* ]]; then
                    PERSIST="$2"; shift 2
                else
                    PERSIST="$PERSIST_DEFAULT"; shift
                fi
                ;;
            --persist-size)  PERSIST_SIZE="$2"; shift 2 ;;
            --persist-fs)    PERSIST_FS="$2"; shift 2 ;;
            --reset-persist) RESET_PERSIST=1; shift ;;
            *) die "Unknown boot-iso option: $1" ;;
        esac
    done

    require_cmd qemu-system-x86_64 qemu-img

    if [[ $RESET_SCRATCH -eq 1 ]]; then
        rm -f "$SCRATCH" "$OVMF_VARS_TI"
    fi
    mkdir -p "$DEV_DIR"
    if [[ ! -f "$SCRATCH" ]]; then
        echo ":: Creating scratch qcow2 ($SCRATCH_SIZE) at $SCRATCH"
        qemu-img create -f qcow2 "$SCRATCH" "$SCRATCH_SIZE" >/dev/null
    fi

    # Build the persistent data image on demand: a raw file with the
    # AMICACHY_DATA label, exactly the layout amicachy-persistent-data
    # expects on a real pendrive's second partition. Filesystem is
    # selectable via --persist-fs (default ntfs to match the pendrive
    # builder, so testing matches what users will see).
    local PERSIST_QEMU_ARGS=()
    if [[ -n "$PERSIST" ]]; then
        case "$PERSIST_FS" in
            ext4)  require_cmd mkfs.ext4 ;;
            ntfs)  require_cmd mkfs.ntfs ;;
            exfat) require_cmd mkfs.exfat ;;
            *) die "--persist-fs must be ntfs|exfat|ext4 (got: $PERSIST_FS)" ;;
        esac
        if [[ $RESET_PERSIST -eq 1 ]]; then
            rm -f "$PERSIST"
        fi
        if [[ ! -f "$PERSIST" ]]; then
            echo ":: Creating persistent data image ($PERSIST_SIZE, $PERSIST_FS) at $PERSIST"
            qemu-img create -f raw "$PERSIST" "$PERSIST_SIZE" >/dev/null
            case "$PERSIST_FS" in
                ext4)  mkfs.ext4 -q -L AMICACHY_DATA -E root_owner=1000:1000 "$PERSIST" ;;
                ntfs)  mkfs.ntfs -Q -L AMICACHY_DATA -F "$PERSIST" >/dev/null ;;
                exfat) mkfs.exfat -L AMICACHY_DATA "$PERSIST" >/dev/null ;;
            esac
        fi
        PERSIST_QEMU_ARGS=(
            -drive "file=${PERSIST},format=raw,if=none,id=persist0"
            -device "usb-storage,bus=xhci.0,drive=persist0,removable=on"
        )
    fi

    local OVMF_CODE
    OVMF_CODE="$(find_ovmf_code)"
    if [[ ! -f "$OVMF_VARS_TI" ]]; then
        cp "$(find_ovmf_vars)" "$OVMF_VARS_TI"
    fi

    local AUDIO_ARGS=()
    if pgrep -x pipewire &>/dev/null; then
        AUDIO_ARGS=(-audiodev pipewire,id=snd0)
    elif pgrep -x pulseaudio &>/dev/null; then
        AUDIO_ARGS=(-audiodev pa,id=snd0)
    else
        AUDIO_ARGS=(-audiodev sdl,id=snd0)
    fi

    local VGA_DEVICE DISPLAY_ARGS
    # grab-on-hover keeps the host WM from stealing keys (F5, function keys,
    # super, etc.) when the QEMU window has the pointer over it.
    if [[ "${DISPLAY_MODE:-auto}" == "safe" ]]; then
        VGA_DEVICE="virtio-vga"
        DISPLAY_ARGS="-display gtk,grab-on-hover=on"
    else
        VGA_DEVICE="virtio-vga-gl"
        DISPLAY_ARGS="-display gtk,gl=on,grab-on-hover=on"
    fi

    # Capture both serial ports to files so we can inspect kernel output and
    # any journal that the live ISO writes to ttyS0/ttyS1 post-mortem.
    local SERIAL_LOG="${DEV_DIR}/iso-serial.log"
    local JOURNAL_LOG="${DEV_DIR}/iso-journal.log"
    : > "$SERIAL_LOG"
    : > "$JOURNAL_LOG"

    echo ":: Booting ISO under QEMU/KVM (no libvirt, no spice)"
    echo "   ISO:     $iso_path"
    echo "   Scratch: $SCRATCH ($SCRATCH_SIZE virtual)"
    [[ -n "$PERSIST" ]] && echo "   Persist: $PERSIST ($PERSIST_SIZE, ext4 LABEL=AMICACHY_DATA)"
    echo "   RAM: ${RAM}M | CPUs: ${CPUS} | Audio: ${AUDIO_ARGS[1]%%,*}"
    echo "   Serial:  $SERIAL_LOG    (ttyS0 — kernel/firmware)"
    echo "   Journal: $JOURNAL_LOG   (ttyS1 — systemd journal if forwarded)"
    echo "   SSH:     ssh -p 2223 amiga@localhost (live, password 'amiga')"
    echo "   Tip: F5 (Early Startup) goes straight to the guest now."
    echo "        --reset-scratch / --reset-persist wipe the corresponding image."
    echo ""

    exec qemu-system-x86_64 \
        -enable-kvm \
        -machine q35 \
        -cpu host \
        -m "$RAM" \
        -smp "$CPUS" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS_TI" \
        -drive file="$iso_path",format=raw,if=none,id=usb0,readonly=on \
        -device qemu-xhci,id=xhci \
        -device usb-storage,bus=xhci.0,drive=usb0,bootindex=1,removable=on \
        "${PERSIST_QEMU_ARGS[@]}" \
        -drive file="$SCRATCH",format=qcow2,if=none,id=hd0,cache=writethrough \
        -device virtio-blk-pci,drive=hd0,bootindex=2 \
        -device "$VGA_DEVICE" \
        $DISPLAY_ARGS \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::2223-:22 \
        "${AUDIO_ARGS[@]}" \
        -device ich9-intel-hda \
        -device hda-duplex,audiodev=snd0 \
        -serial file:"$SERIAL_LOG" \
        -serial file:"$JOURNAL_LOG" \
        -usb \
        -device usb-tablet
}

# ---------------------------------------------------------------------------
# boot-img — Boot a pendrive .img (output of build_pendrive.sh) under QEMU
#            as if it were the real USB stick. Copies the .img to a
#            scratch location so the original stays pristine, optionally
#            grows the copy to simulate a larger physical pendrive (so
#            amicachy-grow-data.service has free space to expand into).
# ---------------------------------------------------------------------------

cmd_boot_img() {
    local img_path="${1:-}"
    [[ -n "$img_path" ]] || die "Usage: $0 boot-img <PENDRIVE_IMG> [--disk-size SIZE] [--reset]"
    [[ -f "$img_path" ]] || die "Pendrive image not found: $img_path"
    img_path="$(realpath "$img_path")"

    local SIM_SIZE="8G"
    local RESET_IMG=0
    local DEBUG=0

    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --disk-size) SIM_SIZE="$2"; shift 2 ;;
            --reset)     RESET_IMG=1; shift ;;
            --debug)     DEBUG=1; shift ;;
            *) die "Unknown boot-img option: $1" ;;
        esac
    done

    require_cmd qemu-system-x86_64 qemu-img numfmt

    mkdir -p "$DEV_DIR"
    local TEST_IMG="${DEV_DIR}/$(basename "${img_path%.img}")-test.img"
    local OVMF_VARS_BI="${DEV_DIR}/OVMF_VARS-boot-img.fd"

    if [[ $RESET_IMG -eq 1 ]]; then
        rm -f "$TEST_IMG" "$OVMF_VARS_BI"
    fi

    # Refresh the test image if the source .img is newer, otherwise reuse
    # so the autogrow result and any user state persist across boots.
    if [[ ! -f "$TEST_IMG" || "$img_path" -nt "$TEST_IMG" ]]; then
        echo ":: Copying $img_path -> $TEST_IMG"
        cp --reflink=auto "$img_path" "$TEST_IMG"
    else
        echo ":: Reusing existing $TEST_IMG (pass --reset to start over)"
    fi

    # Grow the copy to SIM_SIZE so amicachy-grow-data has room to expand
    # into. Refuse to shrink — that would lop off the seed partition.
    local IMG_BYTES SIM_BYTES
    IMG_BYTES="$(stat -c %s "$TEST_IMG")"
    SIM_BYTES="$(numfmt --from=iec "$SIM_SIZE" 2>/dev/null || echo 0)"
    if (( SIM_BYTES == 0 )); then
        die "--disk-size '$SIM_SIZE' is not a valid size (e.g. 8G, 512M)"
    fi
    if (( SIM_BYTES < IMG_BYTES )); then
        die "--disk-size $SIM_SIZE is smaller than the source .img ($(numfmt --to=iec --suffix=B "$IMG_BYTES")); use a larger value"
    fi
    if (( SIM_BYTES > IMG_BYTES )); then
        echo ":: Resizing $TEST_IMG to $SIM_SIZE (simulated pendrive size)"
        qemu-img resize -f raw "$TEST_IMG" "$SIM_BYTES" >/dev/null
    fi

    # --debug: rewrite the systemd-boot loader entries inside the ESP to
    # drop "quiet splash loglevel=0" and add console=ttyS0+console=tty1
    # so every kernel/userspace message is captured in img-serial.log
    # (and visible on screen) without us having to mash 'e' at the menu.
    if [[ $DEBUG -eq 1 ]]; then
        require_cmd losetup mount umount sed sudo
        echo ":: --debug enabled, patching systemd-boot entries for verbose console"
        local DBG_LOOP DBG_MNT DBG_ESP
        DBG_LOOP="$(sudo losetup --find --show -P "$TEST_IMG")"
        # ESP is the FAT32 partition; pick whichever loop partition contains loader/
        DBG_MNT="$(mktemp -d /tmp/amicachy-boot-img-esp.XXXXXX)"
        DBG_ESP=""
        for p in "${DBG_LOOP}"p*; do
            [[ -b "$p" ]] || continue
            if sudo mount -o ro "$p" "$DBG_MNT" 2>/dev/null; then
                if [[ -d "$DBG_MNT/loader/entries" ]]; then
                    sudo umount "$DBG_MNT"
                    DBG_ESP="$p"
                    break
                fi
                sudo umount "$DBG_MNT"
            fi
        done
        if [[ -z "$DBG_ESP" ]]; then
            sudo losetup -d "$DBG_LOOP"
            rmdir "$DBG_MNT"
            die "--debug: could not find loader/entries on any partition of $TEST_IMG"
        fi
        sudo mount "$DBG_ESP" "$DBG_MNT"
        # Replace silencing flags with verbose console. Idempotent: if we
        # already patched, the sed is a no-op.
        sudo sed -i -E '
            s/\bquiet\b//g;
            s/\bsplash\b//g;
            s/\bloglevel=0\b//g;
            s/\brd\.systemd\.show_status=false\b/rd.systemd.show_status=true/g;
            s/\brd\.udev\.log_priority=3\b/rd.udev.log_priority=info/g;
            s/\budev\.log_priority=3\b/udev.log_priority=info/g;
            s/\bsystemd\.show_status=false\b/systemd.show_status=true/g;
            s/\bvt\.global_cursor_default=0\b//g;
            s/\blogo\.nologo\b//g;
            /^options /{ /console=ttyS0/!s/$/ console=ttyS0,115200n8 console=tty1/ }
        ' "$DBG_MNT"/loader/entries/*.conf
        echo "   Patched entries:"
        sudo grep -H "^options " "$DBG_MNT"/loader/entries/*.conf | sed 's|^|     |'
        sync
        sudo umount "$DBG_MNT" && rmdir "$DBG_MNT"
        sudo losetup -d "$DBG_LOOP"
    fi

    local OVMF_CODE
    OVMF_CODE="$(find_ovmf_code)"
    if [[ ! -f "$OVMF_VARS_BI" ]]; then
        cp "$(find_ovmf_vars)" "$OVMF_VARS_BI"
    fi

    local AUDIO_ARGS=()
    if pgrep -x pipewire &>/dev/null; then
        AUDIO_ARGS=(-audiodev pipewire,id=snd0)
    elif pgrep -x pulseaudio &>/dev/null; then
        AUDIO_ARGS=(-audiodev pa,id=snd0)
    else
        AUDIO_ARGS=(-audiodev sdl,id=snd0)
    fi

    local VGA_DEVICE DISPLAY_ARGS
    if [[ "${DISPLAY_MODE:-auto}" == "safe" ]]; then
        VGA_DEVICE="virtio-vga"
        DISPLAY_ARGS="-display gtk,grab-on-hover=on"
    else
        VGA_DEVICE="virtio-vga-gl"
        DISPLAY_ARGS="-display gtk,gl=on,grab-on-hover=on"
    fi

    local SERIAL_LOG="${DEV_DIR}/img-serial.log"
    local JOURNAL_LOG="${DEV_DIR}/img-journal.log"
    : > "$SERIAL_LOG"
    : > "$JOURNAL_LOG"

    echo ":: Booting pendrive image under QEMU/KVM as USB stick"
    echo "   Source:    $img_path ($(numfmt --to=iec --suffix=B "$IMG_BYTES"))"
    echo "   Test img:  $TEST_IMG ($SIM_SIZE simulated)"
    echo "   RAM: ${RAM}M | CPUs: ${CPUS} | Audio: ${AUDIO_ARGS[1]%%,*}"
    echo "   Serial:    $SERIAL_LOG    (ttyS0 — kernel)"
    echo "   Journal:   $JOURNAL_LOG   (ttyS1 — systemd journal)"
    echo "   SSH:       ssh -p 2223 amiga@localhost (live, password 'amiga')"
    echo "   Tip:       inside the live, 'journalctl -u amicachy-grow-data --no-pager'"
    echo "              shows whether autogrow ran and what it did."
    echo ""

    exec qemu-system-x86_64 \
        -enable-kvm \
        -machine q35 \
        -cpu host \
        -m "$RAM" \
        -smp "$CPUS" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS_BI" \
        -drive file="$TEST_IMG",format=raw,if=none,id=usb0 \
        -device qemu-xhci,id=xhci \
        -device usb-storage,bus=xhci.0,drive=usb0,bootindex=1,removable=on \
        -device "$VGA_DEVICE" \
        $DISPLAY_ARGS \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::2223-:22 \
        "${AUDIO_ARGS[@]}" \
        -device ich9-intel-hda \
        -device hda-duplex,audiodev=snd0 \
        -serial file:"$SERIAL_LOG" \
        -serial file:"$JOURNAL_LOG" \
        -usb \
        -device usb-tablet
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
  boot-iso  Boot a built ISO under the same QEMU/KVM setup as 'boot', with
            a separate scratch qcow2 as install target. Same hardware
            (virtio-vga-gl, host CPU, direct keyboard) so F5 etc. work.
            Usage:    $0 boot-iso <ISO_PATH> [--scratch PATH] [--reset-scratch]
                          [--persist [PATH]] [--persist-size SIZE] [--reset-persist]
            Env vars: SCRATCH_SIZE (default 64G), PERSIST_SIZE (default 32G)
            --persist attaches a second 'USB stick' formatted ext4 with
            label AMICACHY_DATA, so the live ISO behaves like a real
            pendrive with a persistent data partition.
  boot-img  Boot a pendrive .img (output of build_pendrive.sh) as a USB
            stick. Copies the .img to dev/ so the original stays pristine,
            optionally grows the copy to simulate a larger physical
            pendrive so amicachy-grow-data.service has room to expand.
            Usage:    $0 boot-img <PENDRIVE_IMG> [--disk-size SIZE] [--reset] [--debug]
            Defaults: --disk-size 8G   (must be >= source .img size)
            --reset wipes the cached copy and starts over from the source.
            --debug  patches the systemd-boot entries in the test image to
                     drop "quiet splash" + add console=ttyS0,115200n8 so
                     every kernel/journal message is captured in
                     dev/img-serial.log (needs sudo to loop-mount the ESP).
  install   Install packages into the VM: local .pkg.tar.zst or repo names (uses Docker)
  log       Tail VM logs. Default: systemd journal (ttyS1).
            Flags: --serial (ttyS0)  --journal (default)  --full (cat)
  shell     Mount the disk for manual inspection (interactive subshell)
  destroy   Remove the dev VM disk and all artifacts

Environment variables:
  DISK_SIZE       Disk image size          (default: 40G)
  RAM             VM memory in MB          (default: 4096)
  CPUS            Number of vCPUs          (default: 2)
  DOCKER_IMAGE    Docker image for pacstrap (auto-detected from CPU)
  DISPLAY_MODE    "auto" (GL) or "safe"    (default: auto)

CPU detection:
  The script auto-detects your CPU's architecture level (x86-64-v3/AVX2
  or generic x86-64) and selects the appropriate CachyOS Docker image
  and package repositories. On CPUs without AVX2, generic packages are
  used automatically (~10-20% slower emulation, but fully functional).

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
    boot-iso) shift; cmd_boot_iso "$@" ;;
    boot-img) shift; cmd_boot_img "$@" ;;
    install) shift; cmd_install "$@" ;;
    log)     shift; cmd_log "$@" ;;
    shell)   cmd_shell   ;;
    destroy) cmd_destroy ;;
    -h|--help|"") usage  ;;
    *) die "Unknown command: $1. Run '$0 --help'." ;;
esac
