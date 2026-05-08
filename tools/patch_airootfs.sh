#!/usr/bin/env bash
# Patch an extracted Archiso USB tree in-place.
#
# Expected tree:
#   <usb-root>/arch/x86_64/airootfs.sfs
#
# This updates the live root with the current AmiCachy launcher and offline
# installer without rebuilding the full ISO.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Usage: $(basename "$0") USB_ROOT_DIR" >&2
    exit 1
}

[[ $# -eq 1 ]] || usage

USB_ROOT="$(realpath "$1")"
SFS_PATH="${USB_ROOT}/arch/x86_64/airootfs.sfs"
WORK_DIR="/tmp/amicachy-airootfs-patch-$$"

if [[ ! -f "$SFS_PATH" ]]; then
    echo "ERROR: airootfs.sfs not found: $SFS_PATH" >&2
    exit 1
fi

for cmd in unsquashfs mksquashfs; do
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

echo ":: Applying AmiCachy offline-installer patches..."

install_file() {
    local src="$1"
    local dest="$2"
    local mode="${3:-}"
    if [[ -f "$src" ]]; then
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        if [[ -n "$mode" ]]; then
            chmod "$mode" "$dest"
        fi
    fi
}

install_dir() {
    local src="$1"
    local dest="$2"
    if [[ -d "$src" ]]; then
        mkdir -p "$(dirname "$dest")"
        rm -rf "$dest"
        cp -a "$src" "$dest"
    fi
}

normalize_lf() {
    local path="$1"
    if [[ -f "$path" ]]; then
        sed -i 's/\r$//' "$path"
    elif [[ -d "$path" ]]; then
        find "$path" -type f \( -name '*.conf' -o -name '*.sh' -o -name '*.script' -o -name '*.plymouth' \) \
            -exec sed -i 's/\r$//' {} +
    fi
}

install_file "${PROJECT_DIR}/archiso/airootfs/usr/bin/amicachy-installer" \
    "${ROOT}/usr/bin/amicachy-installer" 755
install_file "${PROJECT_DIR}/archiso/airootfs/usr/bin/amilaunch.sh" \
    "${ROOT}/usr/bin/amilaunch.sh" 755
install_file "${PROJECT_DIR}/archiso/airootfs/usr/bin/amicachy-amiberry-session" \
    "${ROOT}/usr/bin/amicachy-amiberry-session" 755
install_file "${PROJECT_DIR}/archiso/airootfs/usr/bin/start_dev_env.sh" \
    "${ROOT}/usr/bin/start_dev_env.sh" 755
install_file "${PROJECT_DIR}/archiso/airootfs/usr/bin/amicachy-fix-mac-boot" \
    "${ROOT}/usr/bin/amicachy-fix-mac-boot" 755
install_file "${PROJECT_DIR}/archiso/airootfs/usr/bin/amicachy-copy-roms" \
    "${ROOT}/usr/bin/amicachy-copy-roms" 755
install_file "${PROJECT_DIR}/archiso/airootfs/usr/bin/amicachy-wifi-debug" \
    "${ROOT}/usr/bin/amicachy-wifi-debug" 755
install_file "${PROJECT_DIR}/archiso/airootfs/usr/share/applications/amicachy-copy-roms.desktop" \
    "${ROOT}/usr/share/applications/amicachy-copy-roms.desktop" 644
install_file "${PROJECT_DIR}/archiso/airootfs/usr/share/applications/amicachy-wifi-debug.desktop" \
    "${ROOT}/usr/share/applications/amicachy-wifi-debug.desktop" 644

mkdir -p "${ROOT}/usr/share/amicachy/tools"
rm -rf "${ROOT}/usr/share/amicachy/tools/installer"
cp -a "${PROJECT_DIR}/tools/installer" "${ROOT}/usr/share/amicachy/tools/installer"
rm -rf "${ROOT}/usr/share/amicachy/tools/earlystartup"
cp -a "${PROJECT_DIR}/tools/earlystartup" "${ROOT}/usr/share/amicachy/tools/earlystartup"
install_file "${PROJECT_DIR}/tools/hardware_audit.py" \
    "${ROOT}/usr/share/amicachy/tools/hardware_audit.py"

mkdir -p "${ROOT}/usr/share/amicachy/installer"
install_file "${PROJECT_DIR}/archiso/packages.x86_64" \
    "${ROOT}/usr/share/amicachy/installer/packages.x86_64"
install_file "${PROJECT_DIR}/archiso/pacman.conf" \
    "${ROOT}/usr/share/amicachy/installer/pacman.conf"

install_dir "${PROJECT_DIR}/archiso/airootfs/usr/share/amicachy/uae" \
    "${ROOT}/usr/share/amicachy/uae"
mkdir -p "${ROOT}/usr/share/amicachy/installer/uae"
if [[ -d "${PROJECT_DIR}/archiso/airootfs/usr/share/amicachy/uae" ]]; then
    cp "${PROJECT_DIR}/archiso/airootfs/usr/share/amicachy/uae/"*.uae \
        "${ROOT}/usr/share/amicachy/installer/uae/" 2>/dev/null || true
fi

install_dir "${PROJECT_DIR}/archiso/airootfs/etc/amicachy/labwc-emulator" \
    "${ROOT}/etc/amicachy/labwc-emulator"
install_dir "${PROJECT_DIR}/archiso/airootfs/etc/amicachy/labwc-emulator" \
    "${ROOT}/usr/share/amicachy/installer/labwc-emulator"

install_file "${PROJECT_DIR}/archiso/airootfs/etc/polkit-1/rules.d/10-udisks2.rules" \
    "${ROOT}/etc/polkit-1/rules.d/10-udisks2.rules"
install_file "${PROJECT_DIR}/archiso/airootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf" \
    "${ROOT}/etc/systemd/system/getty@tty1.service.d/autologin.conf"
install_file "${PROJECT_DIR}/archiso/airootfs/etc/mkinitcpio.conf" \
    "${ROOT}/etc/mkinitcpio.conf"
install_file "${PROJECT_DIR}/archiso/airootfs/usr/lib/initcpio/install/remove-simpledrm" \
    "${ROOT}/usr/lib/initcpio/install/remove-simpledrm" 755
install_file "${PROJECT_DIR}/archiso/airootfs/usr/lib/initcpio/hooks/remove-simpledrm" \
    "${ROOT}/usr/lib/initcpio/hooks/remove-simpledrm" 755
install_dir "${PROJECT_DIR}/archiso/airootfs/usr/share/plymouth/themes/amicachy" \
    "${ROOT}/usr/share/plymouth/themes/amicachy"
install_file "${PROJECT_DIR}/archiso/airootfs/etc/plymouth/plymouthd.conf" \
    "${ROOT}/etc/plymouth/plymouthd.conf"
install_file "${PROJECT_DIR}/archiso/airootfs/etc/systemd/system/plymouth-quit.service.d/retain-splash.conf" \
    "${ROOT}/etc/systemd/system/plymouth-quit.service.d/retain-splash.conf"
rm -f "${ROOT}/etc/systemd/system/sysinit.target.wants/plymouth-start.service"
rm -f "${ROOT}/etc/systemd/system/multi-user.target.wants/plymouth-quit.service"
rm -f "${ROOT}/etc/systemd/system/multi-user.target.wants/plymouth-quit-wait.service"
install_file "${PROJECT_DIR}/archiso/airootfs/etc/systemd/system/load-virtio-gpu.service" \
    "${ROOT}/etc/systemd/system/load-virtio-gpu.service"
install_file "${PROJECT_DIR}/archiso/airootfs/home/amiga/.config/labwc/rc.xml" \
    "${ROOT}/home/amiga/.config/labwc/rc.xml" 644
install_file "${PROJECT_DIR}/archiso/airootfs/etc/skel/.config/labwc/rc.xml" \
    "${ROOT}/etc/skel/.config/labwc/rc.xml" 644
mkdir -p "${ROOT}/usr/share/amicachy/installer/labwc"
install_file "${PROJECT_DIR}/archiso/airootfs/etc/skel/.config/labwc/rc.xml" \
    "${ROOT}/usr/share/amicachy/installer/labwc/rc.xml" 644
install_file "${PROJECT_DIR}/archiso/airootfs/home/amiga/.bash_profile" \
    "${ROOT}/home/amiga/.bash_profile"
: > "${ROOT}/home/amiga/.hushlogin"
chown -R 1000:1000 "${ROOT}/home/amiga" 2>/dev/null || true

normalize_lf "${ROOT}/usr/bin/amicachy-installer"
normalize_lf "${ROOT}/usr/bin/amilaunch.sh"
normalize_lf "${ROOT}/usr/bin/amicachy-amiberry-session"
normalize_lf "${ROOT}/usr/bin/start_dev_env.sh"
normalize_lf "${ROOT}/usr/bin/amicachy-fix-mac-boot"
normalize_lf "${ROOT}/usr/bin/amicachy-copy-roms"
normalize_lf "${ROOT}/usr/bin/amicachy-wifi-debug"
normalize_lf "${ROOT}/usr/share/applications/amicachy-copy-roms.desktop"
normalize_lf "${ROOT}/usr/share/applications/amicachy-wifi-debug.desktop"
normalize_lf "${ROOT}/etc/mkinitcpio.conf"
normalize_lf "${ROOT}/etc/plymouth/plymouthd.conf"
normalize_lf "${ROOT}/etc/systemd/system/plymouth-quit.service.d/retain-splash.conf"
normalize_lf "${ROOT}/etc/systemd/system/load-virtio-gpu.service"
normalize_lf "${ROOT}/home/amiga/.config/labwc/rc.xml"
normalize_lf "${ROOT}/etc/skel/.config/labwc/rc.xml"
normalize_lf "${ROOT}/usr/share/amicachy/installer/labwc/rc.xml"
normalize_lf "${ROOT}/usr/lib/initcpio/install/remove-simpledrm"
normalize_lf "${ROOT}/usr/lib/initcpio/hooks/remove-simpledrm"
normalize_lf "${ROOT}/usr/share/plymouth/themes/amicachy"

echo ":: Rebuilding airootfs.sfs..."
rm -f "${SFS_PATH}" "${SFS_PATH}.sha512"
mksquashfs "$ROOT" "$SFS_PATH" -comp zstd -Xcompression-level 3 -noappend >/dev/null
sha512sum "$SFS_PATH" | awk '{ print $1 }' > "${SFS_PATH}.sha512"

echo ":: Patched: $SFS_PATH"
