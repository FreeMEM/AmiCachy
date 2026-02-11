#!/usr/bin/env bash
# AmiCachy — Build ISO inside an Arch Linux Docker container.
# Use this on non-Arch hosts (Ubuntu, Fedora, etc.) where mkarchiso
# is not available natively.
#
# Options:
#   --generic    Force generic x86-64 packages (ISO boots on any 64-bit CPU)
#                Without this flag, the CPU is auto-detected and v3 packages
#                are used if the host supports AVX2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Parse --generic flag before CPU detection
FORCE_GENERIC=0
for arg in "$@"; do
    case "$arg" in
        --generic) FORCE_GENERIC=1 ;;
    esac
done

# CPU arch detection — auto-selects DOCKER_IMAGE and CPU_ARCH_LEVEL
# shellcheck source=lib/cpu_arch.sh
source "${SCRIPT_DIR}/lib/cpu_arch.sh"

# If --generic requested, override to use generic image and repos
if [[ $FORCE_GENERIC -eq 1 && "$CPU_ARCH_LEVEL" != "x86-64" ]]; then
    echo ":: --generic flag: forcing generic x86-64 packages"
    # Keep the Docker image matching the host CPU (for build tool compatibility)
    # but use generic repos for the ISO packages
    CPU_ARCH_LEVEL="x86-64"
    echo ""
fi

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is not installed." >&2
    exit 1
fi

# Generate filtered pacman.conf if needed (generic CPU or --generic flag)
PACMAN_CONF=$(get_pacman_conf "$PROJECT_DIR/archiso/pacman.conf")
EXTRA_DOCKER_ARGS=()
if [[ "$PACMAN_CONF" != "$PROJECT_DIR/archiso/pacman.conf" ]]; then
    # Mount filtered pacman.conf into the container
    EXTRA_DOCKER_ARGS=(-v "${PACMAN_CONF}:/work/archiso/pacman.conf:ro")
fi

echo ":: Building AmiCachy ISO in Docker container..."
echo "   Project dir: ${PROJECT_DIR}"
echo "   Docker image: ${DOCKER_IMAGE}"
echo "   CPU arch level: ${CPU_ARCH_LEVEL}"
echo "   Packages: $(if [[ "$CPU_ARCH_LEVEL" == "x86-64" ]]; then echo "generic x86-64"; else echo "x86-64-v3 (AVX2)"; fi)"
echo ""

docker run --rm --privileged \
    -v "${PROJECT_DIR}:/work" \
    "${EXTRA_DOCKER_ARGS[@]}" \
    -w /work \
    "$DOCKER_IMAGE" \
    bash -c '
        set -euo pipefail

        echo ":: Installing archiso inside container..."
        pacman -Sy --noconfirm archiso

        echo ":: Initializing pacman keyring..."
        pacman-key --init
        pacman-key --populate cachyos archlinux

        echo ":: Setting up CachyOS mirrorlists..."
        cp /work/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist    /etc/pacman.d/
        if [[ -f /work/archiso/airootfs/etc/pacman.d/cachyos-v3-mirrorlist ]]; then
            cp /work/archiso/airootfs/etc/pacman.d/cachyos-v3-mirrorlist /etc/pacman.d/
        fi

        echo ""
        bash /work/tools/build_iso.sh --clean
    '

echo ""
echo ":: Container finished. Checking output..."
ls -lh "${PROJECT_DIR}/out/"*.iso 2>/dev/null || echo "   (no .iso found — check for errors above)"
