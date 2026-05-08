#!/usr/bin/env bash
# Inject one or more pacman packages into an extracted Archiso USB tree.
#
# Usage:
#   inject_airoot_package.sh USB_ROOT_DIR package [package...]

set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") USB_ROOT_DIR package [package...]" >&2
    exit 1
}

[[ $# -ge 2 ]] || usage

USB_ROOT="$(realpath "$1")"
shift
PACKAGES=("$@")

SFS_PATH="${USB_ROOT}/arch/x86_64/airootfs.sfs"
WORK_DIR="/tmp/amicachy-airoot-package-$$"

if [[ ! -f "$SFS_PATH" ]]; then
    echo "ERROR: airootfs.sfs not found: $SFS_PATH" >&2
    exit 1
fi

for cmd in pacman unsquashfs mksquashfs; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: '$cmd' is required." >&2
        exit 1
    fi
done

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR/root"

echo ":: Extracting airootfs.sfs..."
unsquashfs -d "$WORK_DIR/root" "$SFS_PATH" >/dev/null
ROOT="$WORK_DIR/root"

PATCH_CONF="${WORK_DIR}/pacman-airoot.conf"
cp "${ROOT}/etc/pacman.conf" "$PATCH_CONF"

mkdir -p "${ROOT}/etc/pacman.d"
for mirrorlist in mirrorlist cachyos-mirrorlist cachyos-v3-mirrorlist; do
    if [[ -s "/etc/pacman.d/${mirrorlist}" ]] && grep -q '^Server' "/etc/pacman.d/${mirrorlist}"; then
        cp "/etc/pacman.d/${mirrorlist}" "${ROOT}/etc/pacman.d/${mirrorlist}"
    fi
done

sed -i "s|Include = /etc/pacman.d/|Include = ${ROOT}/etc/pacman.d/|g" "$PATCH_CONF"
sed -i 's/^SigLevel[[:space:]]*=.*/SigLevel = Never/' "$PATCH_CONF"

echo ":: Installing into airootfs: ${PACKAGES[*]}"
pacman -r "$ROOT" --config "$PATCH_CONF" -Sy --noconfirm --needed "${PACKAGES[@]}"

echo ":: Rebuilding airootfs.sfs..."
rm -f "${SFS_PATH}" "${SFS_PATH}.sha512"
mksquashfs "$ROOT" "$SFS_PATH" -comp zstd -Xcompression-level 3 -noappend >/dev/null
sha512sum "$SFS_PATH" | awk '{ print $1 }' > "${SFS_PATH}.sha512"

echo ":: Injected packages: ${PACKAGES[*]}"
