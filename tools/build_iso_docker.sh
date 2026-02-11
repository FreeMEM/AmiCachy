#!/usr/bin/env bash
# AmiCachy — Build ISO inside an Arch Linux Docker container.
# Use this on non-Arch hosts (Ubuntu, Fedora, etc.) where mkarchiso
# is not available natively.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is not installed." >&2
    exit 1
fi

echo ":: Building AmiCachy ISO in Docker container..."
echo "   Project dir: ${PROJECT_DIR}"
echo ""

docker run --rm --privileged \
    -v "${PROJECT_DIR}:/work" \
    -w /work \
    cachyos/cachyos-v3:latest \
    bash -c '
        set -euo pipefail

        echo ":: Installing archiso inside container..."
        pacman -Sy --noconfirm archiso

        echo ":: Initializing pacman keyring..."
        pacman-key --init
        pacman-key --populate cachyos archlinux

        echo ":: Setting up CachyOS mirrorlists..."
        cp /work/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist    /etc/pacman.d/
        cp /work/archiso/airootfs/etc/pacman.d/cachyos-v3-mirrorlist /etc/pacman.d/

        echo ""
        bash /work/tools/build_iso.sh --clean
    '

echo ""
echo ":: Container finished. Checking output..."
ls -lh "${PROJECT_DIR}/out/"*.iso 2>/dev/null || echo "   (no .iso found — check for errors above)"
