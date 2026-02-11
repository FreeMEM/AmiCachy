#!/usr/bin/env bash
# AmiCachy — ISO build wrapper
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

setup_local_packages() {
    # If amiberry (or other custom packages) have been compiled and are in out/,
    # create a local pacman repo so mkarchiso can install them into the ISO.
    local LOCAL_REPO="${PROFILE_DIR}/local-repo"
    local pkgs=()

    for f in "${OUT_DIR}"/amiberry-*.pkg.tar.zst; do
        [[ -f "$f" ]] && pkgs+=("$f")
    done

    if [[ ${#pkgs[@]} -eq 0 ]]; then
        echo ":: WARNING: No amiberry package found in out/"
        echo "   Build it first: ./tools/build_amiberry.sh"
        echo "   The ISO will be built WITHOUT amiberry."
        echo ""
        HAS_LOCAL_REPO=0
        return
    fi

    echo ":: Setting up local package repository..."
    mkdir -p "$LOCAL_REPO"

    # Copy the latest amiberry package
    local latest_pkg="${pkgs[-1]}"
    cp "$latest_pkg" "$LOCAL_REPO/"
    echo "   -> $(basename "$latest_pkg")"

    # Create repo database
    repo-add "${LOCAL_REPO}/amicachy.db.tar.gz" "${LOCAL_REPO}"/*.pkg.tar.zst

    # Add local repo to pacman.conf
    cat >> "${PROFILE_DIR}/pacman.conf" << EOF

# --- AmiCachy Local Repo (auto-generated, removed after build) ---
[amicachy-local]
SigLevel = Never
Server = file://${LOCAL_REPO}
EOF

    # Add amiberry to the package list
    echo "amiberry" >> "${PROFILE_DIR}/packages.x86_64"

    HAS_LOCAL_REPO=1
    echo "   Local repo ready. amiberry will be included in the ISO."
}

cleanup_local_packages() {
    if [[ "${HAS_LOCAL_REPO:-0}" -eq 1 ]]; then
        echo ":: Cleaning local package repository..."
        rm -rf "${PROFILE_DIR}/local-repo"
        # Remove appended local repo section from pacman.conf
        sed -i '/^# --- AmiCachy Local Repo/,$ d' "${PROFILE_DIR}/pacman.conf"
        # Remove amiberry line from packages.x86_64
        sed -i '/^amiberry$/d' "${PROFILE_DIR}/packages.x86_64"
    fi
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
setup_local_packages
bundle_installer_data
trap 'unbundle_installer_data; cleanup_local_packages' EXIT
build_iso
