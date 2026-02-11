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
build_iso
