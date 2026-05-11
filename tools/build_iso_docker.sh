#!/usr/bin/env bash
# AmiCachy — Build ISO inside a CachyOS Docker container.
# Use this on non-Arch hosts (Ubuntu, Fedora, etc.) where mkarchiso
# is not available natively, or whenever you want a fully isolated
# build that does not pull anything from the host's pacman cache.
#
# Options:
#   --cpu-arch generic|v3|v4
#       Target CPU baseline for the resulting ISO. Default: v3.
#         generic — any x86-64 CPU since 2003 (no AVX/AVX2). Best for
#                   distributing to unknown hardware.
#         v3      — Haswell+/Excavator+ (AVX2). Most modern PCs (2013+).
#         v4      — Rocket Lake+/Zen 4+ (AVX-512).
#       The Docker image used to host the build is picked to match.
#       Output: out/amicachy-<ARCH>-DATE-x86_64.iso
#
#   --generic   Alias for --cpu-arch generic (kept for backwards compat).
#
#   Other flags (--seed-assets, --squashfs-comp, --clean) are forwarded
#   to build_iso.sh inside the container.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

CPU_ARCH="v3"
PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cpu-arch)
            CPU_ARCH="$2"; shift 2 ;;
        --cpu-arch=*)
            CPU_ARCH="${1#*=}"; shift ;;
        --generic)
            CPU_ARCH="generic"; shift ;;
        *)
            PASSTHROUGH+=("$1"); shift ;;
    esac
done

case "$CPU_ARCH" in
    generic|v3|v4) ;;
    *) echo "ERROR: --cpu-arch must be 'generic', 'v3' or 'v4' (got: $CPU_ARCH)" >&2; exit 1 ;;
esac

# Pick the Docker image for the build host. The container only needs to
# RUN the build tools (pacman, mkarchiso); it does not have to be the
# same arch level as the resulting ISO. Match it to the requested arch
# so the build host has access to the same package repos the ISO uses.
case "$CPU_ARCH" in
    generic) DOCKER_IMAGE="${DOCKER_IMAGE:-cachyos/cachyos:latest}" ;;
    v3)      DOCKER_IMAGE="${DOCKER_IMAGE:-cachyos/cachyos-v3:latest}" ;;
    v4)      DOCKER_IMAGE="${DOCKER_IMAGE:-cachyos/cachyos-znver4:latest}" ;;
esac

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is not installed." >&2
    exit 1
fi

echo ":: Building AmiCachy ISO in Docker container"
echo "   Project dir:    ${PROJECT_DIR}"
echo "   Docker image:   ${DOCKER_IMAGE}"
echo "   Target CPU:     ${CPU_ARCH}"
[[ ${#PASSTHROUGH[@]} -gt 0 ]] && echo "   Forwarded args: ${PASSTHROUGH[*]}"
echo ""

docker run --rm --privileged \
    -v "${PROJECT_DIR}:/work" \
    -w /work \
    -e "AMICACHY_CPU_ARCH=${CPU_ARCH}" \
    "$DOCKER_IMAGE" \
    bash -c '
        set -euo pipefail

        echo ":: Installing archiso inside container..."
        pacman -Sy --noconfirm archiso

        echo ":: Initializing pacman keyring..."
        pacman-key --init
        pacman-key --populate cachyos archlinux

        echo ":: Copying CachyOS mirrorlists into the container..."
        cp /work/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist /etc/pacman.d/
        for ml in cachyos-v3-mirrorlist cachyos-v4-mirrorlist; do
            if [[ -f /work/archiso/airootfs/etc/pacman.d/$ml ]]; then
                cp /work/archiso/airootfs/etc/pacman.d/$ml /etc/pacman.d/
            fi
        done

        echo ""
        bash /work/tools/build_iso.sh --clean --cpu-arch "$AMICACHY_CPU_ARCH" '"${PASSTHROUGH[*]}"'
    '

echo ""
echo ":: Container finished. ISO output:"
ls -lh "${PROJECT_DIR}/out/"amicachy-${CPU_ARCH}-*-x86_64.iso 2>/dev/null \
    || echo "   (no matching .iso — check for errors above)"
