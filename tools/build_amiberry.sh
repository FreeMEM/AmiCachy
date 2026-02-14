#!/usr/bin/env bash
# AmiCachy — Build amiberry package inside Docker.
# Produces a .pkg.tar.zst in out/ that can be installed via pacman -U.
#
# The PKGBUILD compiles amiberry with:
#   - CachyOS x86-64-v3 CFLAGS (from makepkg.conf)
#   - Link-Time Optimization (WITH_LTO=ON)
#   - DBUS control support
#   - IPC socket for debug bridge
#   - Zstandard for CHD compressed disk images

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PKG_DIR="${PROJECT_DIR}/pkg/amiberry"
OUT_DIR="${PROJECT_DIR}/out"

# CPU arch detection — auto-selects DOCKER_IMAGE and CPU_ARCH_LEVEL
# shellcheck source=lib/cpu_arch.sh
source "${SCRIPT_DIR}/lib/cpu_arch.sh"

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is not installed." >&2
    exit 1
fi

if [[ ! -f "$PKG_DIR/PKGBUILD" ]]; then
    echo "ERROR: PKGBUILD not found at $PKG_DIR/PKGBUILD" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

echo ":: Building amiberry package in Docker ($DOCKER_IMAGE)..."
echo "   PKGBUILD: $PKG_DIR/PKGBUILD"
echo ""

docker run --rm \
    -v "$PROJECT_DIR:/work" \
    "$DOCKER_IMAGE" \
    bash -c '
        set -euo pipefail

        echo ":: Updating system and installing build tools..."
        pacman -Syu --noconfirm
        pacman -S --noconfirm --needed base-devel git cmake ninja

        # Create non-root builder (makepkg refuses to run as root)
        useradd -m builder
        echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

        # Copy PKGBUILD to builder home
        cp -r /work/pkg/amiberry /home/builder/amiberry-build
        chown -R builder:builder /home/builder/amiberry-build

        echo ":: Running makepkg..."
        cd /home/builder/amiberry-build
        su builder -c "makepkg -s --noconfirm --cleanbuild"

        # Copy result to output
        cp /home/builder/amiberry-build/*.pkg.tar.zst /work/out/
        echo ""
        echo ":: Package built successfully:"
        ls -lh /work/out/amiberry-*.pkg.tar.zst
    '

echo ""
echo ":: Done! Install in the dev VM with:"
echo "   ./tools/dev_vm.sh shell"
echo "   sudo pacman -U /path/to/amiberry-*.pkg.tar.zst"
