#!/usr/bin/env bash
# AmiCachyEnv — ISO build wrapper
# Imports CachyOS GPG keys, prepares directories, and runs mkarchiso.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROFILE_DIR="${PROJECT_DIR}/archiso"
WORK_DIR="${PROJECT_DIR}/work"
OUT_DIR="${PROJECT_DIR}/out"

# CachyOS package signing key
CACHYOS_KEY="882DCFE48E2051D48E2562ABF3B607488DB35A47"

usage() {
    echo "Usage: $(basename "$0") [--clean]"
    echo ""
    echo "Options:"
    echo "  --clean    Remove work/ directory before building"
    echo ""
    echo "Bundles installer data (tools/installer/, hardware_audit.py,"
    echo "packages.x86_64, pacman.conf) into airootfs before calling mkarchiso,"
    echo "and cleans up bundled files afterwards."
    echo ""
    echo "Requires: archiso package installed, root privileges."
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root (or via sudo)." >&2
        exit 1
    fi
}

import_cachyos_keys() {
    echo ":: Importing CachyOS signing key..."
    if ! pacman-key --list-keys "$CACHYOS_KEY" &>/dev/null; then
        pacman-key --recv-keys "$CACHYOS_KEY"
        pacman-key --lsign-key "$CACHYOS_KEY"
        echo "   Key imported and locally signed."
    else
        echo "   Key already present."
    fi
}

prepare_dirs() {
    mkdir -p "$WORK_DIR" "$OUT_DIR"
}

clean_work() {
    echo ":: Cleaning work directory..."
    rm -rf "$WORK_DIR"
}

bundle_installer_data() {
    # Copy project files into the airootfs tree so they end up inside the ISO.
    # This avoids duplicating files in the repo — they live in one canonical
    # location and are bundled only at build time.
    echo ":: Bundling installer data into airootfs..."

    local AIROOTFS="${PROFILE_DIR}/airootfs"
    local DEST_TOOLS="${AIROOTFS}/usr/share/amicachy/tools"
    local DEST_INST="${AIROOTFS}/usr/share/amicachy/installer"

    # installer Python package
    mkdir -p "${DEST_TOOLS}/installer"
    cp -a "${PROJECT_DIR}/tools/installer/"* "${DEST_TOOLS}/installer/"
    echo "   -> tools/installer/ -> airootfs (tools/installer/)"

    # hardware_audit bridge
    cp -a "${PROJECT_DIR}/tools/hardware_audit.py" "${DEST_TOOLS}/hardware_audit.py"
    echo "   -> tools/hardware_audit.py -> airootfs (tools/)"

    # packages list and pacman.conf for the installer's install-to-disk step
    mkdir -p "${DEST_INST}"
    cp -a "${PROFILE_DIR}/packages.x86_64" "${DEST_INST}/packages.x86_64"
    cp -a "${PROFILE_DIR}/pacman.conf"     "${DEST_INST}/pacman.conf"
    echo "   -> packages.x86_64, pacman.conf -> airootfs (installer/)"

    echo "   Bundle complete."
}

unbundle_installer_data() {
    # Remove bundled files from the profile tree so they don't linger in the
    # repo working copy after a build.
    echo ":: Cleaning bundled data from profile tree..."

    local AIROOTFS="${PROFILE_DIR}/airootfs"
    rm -rf "${AIROOTFS}/usr/share/amicachy/tools/installer"
    rm -f  "${AIROOTFS}/usr/share/amicachy/tools/hardware_audit.py"
    rm -f  "${AIROOTFS}/usr/share/amicachy/installer/packages.x86_64"
    rm -f  "${AIROOTFS}/usr/share/amicachy/installer/pacman.conf"
}

build_iso() {
    echo ":: Building ISO..."
    mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR"
    echo ""
    echo ":: Done! ISO written to: ${OUT_DIR}/"
    ls -lh "${OUT_DIR}"/*.iso 2>/dev/null || echo "   (no .iso found — check for errors above)"
}

# --- Main ---

CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $arg"; usage ;;
    esac
done

check_root
import_cachyos_keys
[[ $CLEAN -eq 1 ]] && clean_work
prepare_dirs
bundle_installer_data
trap unbundle_installer_data EXIT
build_iso
