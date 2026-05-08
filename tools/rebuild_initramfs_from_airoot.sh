#!/usr/bin/env bash
# Rebuild the live initramfs from an extracted/copy-to-USB Archiso tree.
#
# Usage:
#   bash tools/rebuild_initramfs_from_airoot.sh OUT_USB_TREE
#
# Expected input:
#   OUT_USB_TREE/arch/x86_64/airootfs.sfs
#   OUT_USB_TREE/arch/boot/x86_64/initramfs-linux-cachyos.img

set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") OUT_USB_TREE" >&2
    exit 1
}

[[ $# -eq 1 ]] || usage

USB_ROOT="$(realpath "$1")"
SFS_PATH="${USB_ROOT}/arch/x86_64/airootfs.sfs"
INITRAMFS_PATH="${USB_ROOT}/arch/boot/x86_64/initramfs-linux-cachyos.img"
WORK_DIR="/tmp/amicachy-initramfs-$$"

if [[ ! -f "$SFS_PATH" ]]; then
    echo "ERROR: airootfs.sfs not found: $SFS_PATH" >&2
    exit 1
fi

for cmd in unsquashfs arch-chroot mkinitcpio; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: '$cmd' is required." >&2
        exit 1
    fi
done

cleanup() {
    umount -R "${WORK_DIR}/root/run" 2>/dev/null || true
    umount "${WORK_DIR}/root/out-initramfs" 2>/dev/null || true
    umount -R "${WORK_DIR}/root/dev" 2>/dev/null || true
    umount -R "${WORK_DIR}/root/sys" 2>/dev/null || true
    umount "${WORK_DIR}/root/proc" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR"

echo ":: Extracting live root..."
unsquashfs -d "${WORK_DIR}/root" "$SFS_PATH" >/dev/null

echo ":: Preparing chroot mounts..."
mount -t proc proc "${WORK_DIR}/root/proc"
mount --rbind /sys "${WORK_DIR}/root/sys"
mount --make-rslave "${WORK_DIR}/root/sys"
mount --rbind /dev "${WORK_DIR}/root/dev"
mount --make-rslave "${WORK_DIR}/root/dev"
mount --rbind /run "${WORK_DIR}/root/run"
mount --make-rslave "${WORK_DIR}/root/run"
mkdir -p "${WORK_DIR}/out" "${WORK_DIR}/root/out-initramfs"
mount --bind "${WORK_DIR}/out" "${WORK_DIR}/root/out-initramfs"

echo ":: Rebuilding initramfs..."
kernel_version="$(
    arch-chroot "${WORK_DIR}/root" \
        bash -lc "find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -1"
)"
if [[ -z "$kernel_version" ]]; then
    echo "ERROR: Could not find a kernel module directory in the live root." >&2
    exit 1
fi

arch-chroot "${WORK_DIR}/root" \
    mkinitcpio -k "$kernel_version" \
        -c /etc/mkinitcpio.conf \
        -g /out-initramfs/initramfs-linux-cachyos.img

mkdir -p "$(dirname "$INITRAMFS_PATH")"
generated="${WORK_DIR}/out/initramfs-linux-cachyos.img"
if [[ ! -f "$generated" && -f "${WORK_DIR}/root/out-initramfs/initramfs-linux-cachyos.img" ]]; then
    generated="${WORK_DIR}/root/out-initramfs/initramfs-linux-cachyos.img"
fi
if [[ ! -f "$generated" ]]; then
    generated="$(find "$WORK_DIR" /tmp -maxdepth 5 -type f -name 'initramfs-linux-cachyos.img' 2>/dev/null | head -1)"
fi
if [[ -z "${generated:-}" || ! -f "$generated" ]]; then
    echo "ERROR: mkinitcpio reported success, but no initramfs image was found." >&2
    exit 1
fi

cp "$generated" "$INITRAMFS_PATH"
sha512sum "$INITRAMFS_PATH" | awk '{ print $1 }' > "${INITRAMFS_PATH}.sha512"

echo ":: Rebuilt: $INITRAMFS_PATH"
