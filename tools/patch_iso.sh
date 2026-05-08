#!/usr/bin/env bash
# AmiCachy — Patch an existing ISO without full rebuild.
#
# This script extracts the squashfs from an existing ISO, applies
# file-level patches (scripts, configs), and rebuilds the ISO.
# Much faster than a full rebuild since no packages are downloaded.
#
# Usage:  sudo bash tools/patch_iso.sh [--input ISO_PATH] [--output ISO_PATH]
#         Default input:  latest ISO in out/
#         Default output: out/amicachy-patched-YYYYMMDD-x86_64.iso

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${PROJECT_DIR}/out"
PATCH_WORK="/tmp/amicachy-patch-$$"

# --- Parse arguments ---
INPUT_ISO=""
OUTPUT_ISO=""
for arg in "$@"; do
    case "$arg" in
        --input=*)  INPUT_ISO="${arg#--input=}" ;;
        --output=*) OUTPUT_ISO="${arg#--output=}" ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--input=ISO_PATH] [--output=ISO_PATH]"
            exit 0
            ;;
    esac
done

# Auto-detect latest ISO
if [[ -z "$INPUT_ISO" ]]; then
    INPUT_ISO=$(ls -t "${OUT_DIR}"/amicachy-*.iso 2>/dev/null | head -1)
    if [[ -z "$INPUT_ISO" ]]; then
        echo "ERROR: No ISO found in ${OUT_DIR}/" >&2
        exit 1
    fi
fi

if [[ -z "$OUTPUT_ISO" ]]; then
    OUTPUT_ISO="${OUT_DIR}/amicachy-patched-$(date +%Y%m%d)-x86_64.iso"
fi

echo ":: AmiCachy ISO Patcher"
echo "   Input:  ${INPUT_ISO}"
echo "   Output: ${OUTPUT_ISO}"
echo ""

# --- Check dependencies ---
for cmd in xorriso unsquashfs mksquashfs; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is not installed." >&2
        echo "Install: pacman -S xorriso squashfs-tools" >&2
        exit 1
    fi
done

PACMAN_AVAILABLE=0
if command -v pacman &>/dev/null; then
    PACMAN_AVAILABLE=1
fi

# --- Setup work directory ---
cleanup() {
    echo ":: Cleaning up..."
    umount "${PATCH_WORK}/iso_mount" 2>/dev/null || true
    rm -rf "$PATCH_WORK"
}
trap cleanup EXIT

mkdir -p "${PATCH_WORK}/iso_mount" "${PATCH_WORK}/iso_extract" "${PATCH_WORK}/squashfs_root"

# --- Step 1: Extract ISO contents ---
echo ":: Step 1/5: Extracting ISO..."
xorriso -osirrox on -indev "$INPUT_ISO" -extract / "${PATCH_WORK}/iso_extract"
chmod -R u+w "${PATCH_WORK}/iso_extract"

# --- Step 2: Find and extract squashfs ---
echo ":: Step 2/5: Extracting squashfs filesystem..."
SQUASHFS_PATH="${PATCH_WORK}/iso_extract/arch/x86_64/airootfs.sfs"
if [[ ! -f "$SQUASHFS_PATH" ]]; then
    echo "ERROR: airootfs.sfs not found at expected path." >&2
    echo "Searching..." >&2
    find "${PATCH_WORK}/iso_extract" -name "airootfs.sfs" -o -name "*.sfs" 2>/dev/null
    exit 1
fi

unsquashfs -d "${PATCH_WORK}/squashfs_root" "$SQUASHFS_PATH"
echo "   Squashfs extracted."

# --- Step 3: Apply patches ---
echo ":: Step 3/5: Applying patches..."
ROOT="${PATCH_WORK}/squashfs_root"

# 3a. amilaunch.sh
if [[ -f "${PROJECT_DIR}/archiso/airootfs/usr/bin/amilaunch.sh" ]]; then
    cp "${PROJECT_DIR}/archiso/airootfs/usr/bin/amilaunch.sh" \
       "${ROOT}/usr/bin/amilaunch.sh"
    chmod 755 "${ROOT}/usr/bin/amilaunch.sh"
    echo "   ✓ amilaunch.sh"
fi
if [[ -f "${PROJECT_DIR}/archiso/airootfs/usr/bin/amicachy-installer" ]]; then
    cp "${PROJECT_DIR}/archiso/airootfs/usr/bin/amicachy-installer" \
       "${ROOT}/usr/bin/amicachy-installer"
    chmod 755 "${ROOT}/usr/bin/amicachy-installer"
    echo "   ✓ amicachy-installer"
fi
if [[ -f "${PROJECT_DIR}/archiso/airootfs/usr/bin/amicachy-amiberry-session" ]]; then
    cp "${PROJECT_DIR}/archiso/airootfs/usr/bin/amicachy-amiberry-session" \
       "${ROOT}/usr/bin/amicachy-amiberry-session"
    chmod 755 "${ROOT}/usr/bin/amicachy-amiberry-session"
    if [[ -d "${ROOT}/usr/share/amicachy/installer" ]]; then
        cp "${PROJECT_DIR}/archiso/airootfs/usr/bin/amicachy-amiberry-session" \
           "${ROOT}/usr/share/amicachy/installer/amicachy-amiberry-session"
    fi
    echo "   ✓ amicachy-amiberry-session"
fi

# 3a.1. Ensure the automount stack exists in older ISOs.
# This downloads only missing packages into the extracted squashfs; it does not
# rebuild the full archiso package set.
missing_pkgs=()
[[ ! -x "${ROOT}/usr/bin/udiskie" ]] && missing_pkgs+=(udiskie udisks2 polkit)
[[ ! -x "${ROOT}/usr/bin/rsync" ]] && missing_pkgs+=(rsync)
if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    if [[ "$PACMAN_AVAILABLE" == "1" ]]; then
        echo "   Installing missing runtime packages into squashfs: ${missing_pkgs[*]}"
        PACMAN_PATCH_CONF="${PATCH_WORK}/pacman-patch.conf"
        cp "${ROOT}/etc/pacman.conf" "$PACMAN_PATCH_CONF"
        sed -i "s|Include = /etc/pacman.d/|Include = ${ROOT}/etc/pacman.d/|g" "$PACMAN_PATCH_CONF"
        pacman -r "$ROOT" --config "$PACMAN_PATCH_CONF" -Sy --noconfirm --needed "${missing_pkgs[@]}"
        echo "   ✓ missing runtime packages"
    else
        echo "   ⚠ Missing packages (${missing_pkgs[*]}) and pacman is unavailable; package injection skipped"
    fi
fi

# 3b. vconsole.conf
if [[ -f "${PROJECT_DIR}/archiso/airootfs/etc/vconsole.conf" ]]; then
    cp "${PROJECT_DIR}/archiso/airootfs/etc/vconsole.conf" \
       "${ROOT}/etc/vconsole.conf"
    echo "   ✓ vconsole.conf"
fi

# 3b.1. Locale data. Some patched ISOs may have locale.conf/locale.gen but no
# generated locale archive, causing "setlocale: cannot change locale" warnings.
if [[ -x "${ROOT}/usr/bin/locale-gen" ]]; then
    chroot "$ROOT" locale-gen >/dev/null
    echo "   ✓ locale archive"
fi

# 3c. mkinitcpio.conf (for the live ISO, mostly informational)
if [[ -f "${PROJECT_DIR}/archiso/airootfs/etc/mkinitcpio.conf" ]]; then
    cp "${PROJECT_DIR}/archiso/airootfs/etc/mkinitcpio.conf" \
       "${ROOT}/etc/mkinitcpio.conf"
    echo "   ✓ mkinitcpio.conf"
fi

# 3c.1. Polkit rules for passwordless udisks mounts by the live user.
if [[ -f "${PROJECT_DIR}/archiso/airootfs/etc/polkit-1/rules.d/10-udisks2.rules" ]]; then
    mkdir -p "${ROOT}/etc/polkit-1/rules.d"
    cp "${PROJECT_DIR}/archiso/airootfs/etc/polkit-1/rules.d/10-udisks2.rules" \
       "${ROOT}/etc/polkit-1/rules.d/10-udisks2.rules"
    echo "   ✓ udisks2 polkit rule"
fi

# 3c.1b. CachyOS Calamares ships settings under /usr/share/calamares, while
# the launcher expects /etc/calamares/settings.conf.
if [[ -f "${PROJECT_DIR}/archiso/airootfs/etc/calamares/settings.conf" ]]; then
    mkdir -p "${ROOT}/etc/calamares"
    cp "${PROJECT_DIR}/archiso/airootfs/etc/calamares/settings.conf" \
       "${ROOT}/etc/calamares/settings.conf"
    echo "   ✓ calamares settings.conf"
fi

# 3c.2. Keep the proven agetty login path for Cage/logind, but suppress as
# much terminal noise as possible before amilaunch clears TTY1.
rm -f "${ROOT}/etc/systemd/system/amicachy-live.service"
rm -f "${ROOT}/etc/systemd/system/multi-user.target.wants/amicachy-live.service"
mkdir -p "${ROOT}/etc/systemd/system/getty@tty1.service.d"
cp "${PROJECT_DIR}/archiso/airootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf" \
   "${ROOT}/etc/systemd/system/getty@tty1.service.d/autologin.conf"
cp "${PROJECT_DIR}/archiso/airootfs/home/amiga/.bash_profile" \
   "${ROOT}/home/amiga/.bash_profile"
: > "${ROOT}/home/amiga/.hushlogin"
echo "   ✓ quiet autologin"

# 3d. Installer Python code. Replace the full package so patched ISOs do not
# end up with a mixed old/new installer or missing modules such as app.py.
INST_TOOLS="${ROOT}/usr/share/amicachy/tools/installer"
mkdir -p "$(dirname "$INST_TOOLS")"
rm -rf "$INST_TOOLS"
cp -a "${PROJECT_DIR}/tools/installer" "$INST_TOOLS"
echo "   ✓ installer package"

# 3e. hardware_audit.py
if [[ -d "${ROOT}/usr/share/amicachy/tools" ]]; then
    cp "${PROJECT_DIR}/tools/hardware_audit.py" \
       "${ROOT}/usr/share/amicachy/tools/hardware_audit.py"
    echo "   ✓ hardware_audit.py"
fi

# 3f. Installer data (packages list, pacman.conf for install-to-disk)
INST_DATA="${ROOT}/usr/share/amicachy/installer"
if [[ -d "$INST_DATA" ]]; then
    cp "${PROJECT_DIR}/archiso/packages.x86_64" "$INST_DATA/packages.x86_64"
    cp "${PROJECT_DIR}/archiso/pacman.conf"      "$INST_DATA/pacman.conf"
    echo "   ✓ installer data (packages.x86_64, pacman.conf)"
fi

# 3g. UAE configs for the live profiles and installed system payload.
if [[ -d "${PROJECT_DIR}/archiso/airootfs/usr/share/amicachy/uae" ]]; then
    mkdir -p "${ROOT}/usr/share/amicachy/uae"
    cp "${PROJECT_DIR}/archiso/airootfs/usr/share/amicachy/uae/"*.uae \
       "${ROOT}/usr/share/amicachy/uae/"
    if [[ -d "$INST_DATA" ]]; then
        mkdir -p "$INST_DATA/uae"
        cp "${PROJECT_DIR}/archiso/airootfs/usr/share/amicachy/uae/"*.uae \
           "$INST_DATA/uae/"
    fi
    echo "   ✓ UAE configs"
fi

# 3h. labwc emulator config for touchpad tap/click behaviour.
if [[ -d "${PROJECT_DIR}/archiso/airootfs/etc/amicachy/labwc-emulator" ]]; then
    mkdir -p "${ROOT}/etc/amicachy"
    cp -a "${PROJECT_DIR}/archiso/airootfs/etc/amicachy/labwc-emulator" \
       "${ROOT}/etc/amicachy/"
    if [[ -d "$INST_DATA" ]]; then
        cp -a "${PROJECT_DIR}/archiso/airootfs/etc/amicachy/labwc-emulator" \
           "$INST_DATA/"
    fi
    echo "   ✓ labwc emulator config"
fi

echo "   All patches applied."

# --- Step 4: Rebuild squashfs ---
echo ":: Step 4/5: Rebuilding squashfs (this takes a few minutes)..."
rm "$SQUASHFS_PATH"
mksquashfs "${PATCH_WORK}/squashfs_root" "$SQUASHFS_PATH" \
    -comp xz -Xbcj x86 -b 1M -Xdict-size 1M \
    -noappend
# Update the sha512 checksum
sha512sum "$SQUASHFS_PATH" | cut -d' ' -f1 > "${SQUASHFS_PATH}.sha512"
echo "   Squashfs rebuilt."

# --- Step 5: Rebuild ISO ---
echo ":: Step 5/5: Rebuilding ISO..."
if [[ -e "$OUTPUT_ISO" && "$OUTPUT_ISO" != "$INPUT_ISO" ]]; then
    rm -f "$OUTPUT_ISO"
fi
xorriso \
    -indev "$INPUT_ISO" \
    -outdev "$OUTPUT_ISO" \
    -boot_image any replay \
    -overwrite on \
    -map "$SQUASHFS_PATH" "/arch/x86_64/airootfs.sfs" \
    -map "${SQUASHFS_PATH}.sha512" "/arch/x86_64/airootfs.sfs.sha512" \
    -commit

echo ""
echo ":: Done!"
echo "   Patched ISO: ${OUTPUT_ISO}"
ls -lh "$OUTPUT_ISO"
