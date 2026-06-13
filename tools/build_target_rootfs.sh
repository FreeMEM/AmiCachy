#!/usr/bin/env bash
# AmiCachy — Build the installed-system (TARGET) rootfs squashfs.
#
# Produces out/amicachy-target.sfs: the precompiled rootfs that Calamares'
# unpackfs module deploys onto the disk (Calamares migration, F3 — decision
# "separate clean squashfs"). Unlike the live squashfs it contains NO
# installer and NO Calamares: just the CachyOS base + Amiberry + the
# amicachy-base payload that used to be written by configure_system().
#
# Built in Docker like build_amiberry.sh, so the host need not be CachyOS and
# pacstrap runs against the right repos. The package list is DERIVED from
# archiso/packages.x86_64 (single source of truth) by dropping the live-only
# packages and adding the target-only ones — see EXCLUDE/ADD below.
#
# Prerequisites (build these first):
#   ./tools/build_amiberry.sh      --cpu-arch <arch>
#   ./tools/build_amicachy_base.sh
#
# Usage:  ./tools/build_target_rootfs.sh [--cpu-arch generic|v3|v4]
# Output: out/amicachy-target.sfs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${PROJECT_DIR}/out"

# shellcheck source=lib/cpu_arch.sh
source "${SCRIPT_DIR}/lib/cpu_arch.sh"
_detect_cpu_arch

CPU_ARCH="v3"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cpu-arch)      CPU_ARCH="$2"; shift 2 ;;
        --cpu-arch=*)    CPU_ARCH="${1#*=}"; shift ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--cpu-arch generic|v3|v4]"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

case "$CPU_ARCH" in
    generic|v3|v4) ;;
    *) echo "ERROR: --cpu-arch must be generic|v3|v4 (got: $CPU_ARCH)" >&2; exit 1 ;;
esac

# pacman.conf for the chosen arch (same per-arch confs the ISO build uses).
PACMAN_CONF_NAME="pacman-${CPU_ARCH}.conf"
[[ -f "${PROJECT_DIR}/archiso/${PACMAN_CONF_NAME}" ]] || {
    echo "ERROR: archiso/${PACMAN_CONF_NAME} not found." >&2; exit 1; }

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is not installed." >&2; exit 1
fi

# Locate the prerequisite packages in out/.
shopt -s nullglob
AMIBERRY_PKGS=("${OUT_DIR}"/amiberry-*-"${CPU_ARCH}"-x86_64.pkg.tar.zst)
BASE_PKGS=("${OUT_DIR}"/amicachy-base-*-any.pkg.tar.zst)
shopt -u nullglob
if [[ ${#AMIBERRY_PKGS[@]} -eq 0 ]]; then
    echo "ERROR: no amiberry-*-${CPU_ARCH}-x86_64.pkg.tar.zst in out/." >&2
    echo "       Run: ./tools/build_amiberry.sh --cpu-arch ${CPU_ARCH}" >&2
    exit 1
fi
if [[ ${#BASE_PKGS[@]} -eq 0 ]]; then
    echo "ERROR: no amicachy-base-*-any.pkg.tar.zst in out/." >&2
    echo "       Run: ./tools/build_amicachy_base.sh" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

echo ":: Building AmiCachy target rootfs squashfs"
echo "   Docker image: $DOCKER_IMAGE"
echo "   CPU arch:     $CPU_ARCH  (pacman conf: ${PACMAN_CONF_NAME})"
echo ""

docker run --rm \
    -v "$PROJECT_DIR:/work" \
    -e "CPU_ARCH=$CPU_ARCH" \
    -e "PACMAN_CONF_NAME=$PACMAN_CONF_NAME" \
    --privileged \
    "$DOCKER_IMAGE" \
    bash -c '
        set -euo pipefail

        echo ":: Updating container and installing build tools..."
        pacman -Syu --noconfirm --needed arch-install-scripts squashfs-tools

        # --- Local repo with the AmiCachy-built packages ------------------
        REPO=/tmp/amicachy-repo
        mkdir -p "$REPO"
        cp /work/out/amiberry-*-"${CPU_ARCH}"-x86_64.pkg.tar.zst "$REPO"/
        cp /work/out/amicachy-base-*-any.pkg.tar.zst "$REPO"/
        repo-add "$REPO/amicachy-local.db.tar.gz" "$REPO"/*.pkg.tar.zst

        # --- pacman.conf = per-arch profile conf + local repo -------------
        CONF=/tmp/pacman-target.conf
        cp "/work/archiso/${PACMAN_CONF_NAME}" "$CONF"
        cat >> "$CONF" <<EOF

[amicachy-local]
SigLevel = Never
Server = file://$REPO
EOF

        # --- Derive the target package list from packages.x86_64 ----------
        # Single source of truth: archiso/packages.x86_64, minus the
        # live-only packages, plus the target-only ones.
        EXCLUDE="mkinitcpio-archiso syslinux cachyos-calamares calamares-config-amicachy"
        ADD="amicachy-base amiberry linux-cachyos-headers"

        mapfile -t BASE < <(grep -vE "^\s*#|^\s*$" /work/archiso/packages.x86_64)
        TARGET_PKGS=()
        for p in "${BASE[@]}"; do
            skip=0
            for e in $EXCLUDE; do [[ "$p" == "$e" ]] && skip=1; done
            [[ $skip -eq 0 ]] && TARGET_PKGS+=("$p")
        done
        TARGET_PKGS+=($ADD)

        echo ":: pacstrap target (${#TARGET_PKGS[@]} packages)..."
        ROOT=/tmp/target
        mkdir -p "$ROOT"
        pacstrap -K -c -C "$CONF" "$ROOT" "${TARGET_PKGS[@]}"

        # The local repo only exists at build time; do not leave it in the
        # installed pacman.conf. amicachy-base already ships the real
        # pacman.d mirrorlists; the squashfs build inherits the per-arch
        # pacman.conf via the ISO build, not from here.
        rm -rf "$ROOT/etc/pacman.d/gnupg/openpgp-revocs.d" 2>/dev/null || true

        echo ":: mksquashfs -> out/amicachy-target.sfs"
        rm -f /work/out/amicachy-target.sfs
        mksquashfs "$ROOT" /work/out/amicachy-target.sfs \
            -comp zstd -Xcompression-level 19 -noappend -no-progress

        echo ""
        echo ":: Done:"
        ls -lh /work/out/amicachy-target.sfs
    '

echo ""
echo ":: Target rootfs ready at out/amicachy-target.sfs"
echo "   tools/build_iso.sh will embed it for Calamares unpackfs."
