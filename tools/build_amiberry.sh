#!/usr/bin/env bash
# AmiCachy — Build amiberry package inside Docker.
# Produces a .pkg.tar.zst in out/ that can be installed via pacman -U.
#
# The PKGBUILD compiles amiberry with:
#   - Explicit -march=x86-64-vN (NOT -march=native), so the binary is
#     portable to every CPU at that x86-64 level.
#   - Link-Time Optimization (WITH_LTO=ON via cmake)
#   - DBUS control support
#   - IPC socket for debug bridge
#   - Zstandard for CHD compressed disk images
#
# Usage:
#   ./tools/build_amiberry.sh [--cpu-arch generic|v3|v4|all]
#
# --cpu-arch defaults to v3 — same baseline as ./tools/build_iso.sh, so
# the package and ISO that consume it are compatible by default. Pick
# generic for max portability (any x86-64 CPU since 2003), v4 only on
# CPUs with AVX-512.
#
# --cpu-arch all builds all three variants inside the same container so
# the (slow) pacman -Syu / base-devel install is amortised across them.
#
# Output: out/amiberry-<VER>-<REL>-<arch>-x86_64.pkg.tar.zst
# The arch suffix lets build_iso.sh pick the package that matches its
# own --cpu-arch without ambiguity.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PKG_DIR="${PROJECT_DIR}/pkg/amiberry"
OUT_DIR="${PROJECT_DIR}/out"

# Use cpu_arch.sh only as a fallback for DOCKER_IMAGE; the target arch
# comes from --cpu-arch, NOT from the host CPU.
# shellcheck source=lib/cpu_arch.sh
source "${SCRIPT_DIR}/lib/cpu_arch.sh"

usage() {
    echo "Usage: $(basename "$0") [--cpu-arch generic|v3|v4|all]"
    echo ""
    echo "  --cpu-arch ARCH      Target CPU baseline (default: v3):"
    echo "                         generic — any x86-64 CPU since 2003 (no AVX/AVX2)"
    echo "                         v3      — Haswell+/Excavator+ (AVX2)"
    echo "                         v4      — Rocket Lake+/Zen 4+ (AVX-512)"
    echo "                         all     — build all three variants in one container run"
    echo ""
    echo "Output: out/amiberry-<VER>-<REL>-<arch>-x86_64.pkg.tar.zst"
    exit 1
}

CPU_ARCH="v3"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cpu-arch)
            [[ $# -ge 2 ]] || { echo "ERROR: --cpu-arch requires generic|v3|v4|all"; usage; }
            CPU_ARCH="$2"; shift 2 ;;
        --cpu-arch=*)
            CPU_ARCH="${1#*=}"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Resolve target list and the matching x86-64-vN flag for each.
declare -a TARGETS=()
case "$CPU_ARCH" in
    generic) TARGETS=("generic:x86-64") ;;
    v3)      TARGETS=("v3:x86-64-v3")   ;;
    v4)      TARGETS=("v4:x86-64-v4")   ;;
    all)     TARGETS=("generic:x86-64" "v3:x86-64-v3" "v4:x86-64-v4") ;;
    *) echo "ERROR: --cpu-arch must be generic|v3|v4|all (got: $CPU_ARCH)"; exit 1 ;;
esac

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is not installed." >&2
    exit 1
fi
[[ -f "$PKG_DIR/PKGBUILD" ]] || { echo "ERROR: PKGBUILD not found at $PKG_DIR/PKGBUILD" >&2; exit 1; }

mkdir -p "$OUT_DIR"

echo ":: Building amiberry package in Docker"
echo "   Docker image:  $DOCKER_IMAGE"
echo "   Targets:       ${TARGETS[*]}"
echo "   PKGBUILD:      $PKG_DIR/PKGBUILD"
echo ""

# Build a space-separated "arch:level arch:level …" string the bash
# inside the container can split. Each entry: <suffix>:<march level>.
TARGETS_STR="${TARGETS[*]}"

docker run --rm \
    -v "$PROJECT_DIR:/work" \
    -e "AMICACHY_TARGETS=$TARGETS_STR" \
    "$DOCKER_IMAGE" \
    bash -c '
        set -euo pipefail

        echo ":: Updating system and installing build tools..."
        pacman -Syu --noconfirm
        pacman -S --noconfirm --needed base-devel git cmake ninja

        # Create non-root builder (makepkg refuses to run as root)
        useradd -m builder
        echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

        cp -r /work/pkg/amiberry /home/builder/amiberry-build
        chown -R builder:builder /home/builder/amiberry-build
        cd /home/builder/amiberry-build

        # Iterate every requested (suffix:level) pair. --cleanbuild on
        # each iteration so they do not contaminate each other; the
        # downloaded source tarball / git checkout is kept by makepkg
        # in srcdest, so it is not redownloaded between arches.
        for target in $AMICACHY_TARGETS; do
            suffix="${target%%:*}"
            level="${target##*:}"
            echo ""
            echo "===> Building amiberry (target=$suffix, march=$level)"

            su builder -c "AMICACHY_CPU_ARCH_LEVEL=$level makepkg -s --noconfirm --cleanbuild"

            # Rename and copy to /work/out with the arch suffix.
            for pkg in /home/builder/amiberry-build/amiberry-*-x86_64.pkg.tar.zst; do
                [[ -f "$pkg" ]] || continue
                base=$(basename "$pkg")
                stem="${base%-x86_64.pkg.tar.zst}"
                # Skip files that already carry a suffix from a previous loop
                case "$stem" in
                    *-generic|*-v3|*-v4) continue ;;
                esac
                tagged="${stem}-${suffix}-x86_64.pkg.tar.zst"
                cp "$pkg" "/work/out/${tagged}"
                rm -f "$pkg"   # so the next iteration glob is clean
                echo ":: Tagged output: out/${tagged}"
            done
        done

        echo ""
        echo ":: All requested amiberry variants built. Latest in out/:"
        ls -lh /work/out/amiberry-*.pkg.tar.zst 2>/dev/null | tail -10
    '

echo ""
case "$CPU_ARCH" in
    all)
        echo ":: Done. Now you can build the ISO for any arch:"
        echo "   sudo ./tools/build_iso.sh --cpu-arch generic"
        echo "   sudo ./tools/build_iso.sh --cpu-arch v3"
        echo "   sudo ./tools/build_iso.sh --cpu-arch v4"
        ;;
    *)
        echo ":: Done. To consume this package in the ISO:"
        echo "   sudo ./tools/build_iso.sh --cpu-arch $CPU_ARCH"
        ;;
esac
