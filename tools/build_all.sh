#!/usr/bin/env bash
# AmiCachy — release-grade matrix build.
#
# Produces every shippable artifact for the three x86-64 CPU baselines
# in one go:
#
#   amiberry .pkg.tar.zst  × {generic, v3, v4}   (built inside Docker)
#   amicachy ISO            × {generic, v3, v4}   (mkarchiso, needs root)
#   amicachy pendrive .img  × {generic, v3, v4}   (build_pendrive.sh,
#                                                  needs root)
#
# Each step is idempotent: artifacts already in out/ matching the
# expected names are reused unless --force is passed (which deletes the
# matching outputs first).
#
# Usage:
#   ./tools/build_all.sh [--arch generic,v3,v4]
#                        [--skip-amiberry]
#                        [--skip-iso]
#                        [--skip-pendrive]
#                        [--force]
#
# Defaults:
#   --arch              all three (generic,v3,v4)
#   no skips, no force
#
# Requires sudo (the ISO and pendrive steps run as root). Cache your
# credentials first with `sudo -v` so the matrix does not stall halfway
# asking for a password.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${PROJECT_DIR}/out"

ARCHS="generic,v3,v4"
SKIP_AMIBERRY=0
SKIP_ISO=0
SKIP_PENDRIVE=0
FORCE=0

usage() {
    sed -n '4,28p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)            ARCHS="$2"; shift 2 ;;
        --arch=*)          ARCHS="${1#*=}"; shift ;;
        --skip-amiberry)   SKIP_AMIBERRY=1; shift ;;
        --skip-iso)        SKIP_ISO=1; shift ;;
        --skip-pendrive)   SKIP_PENDRIVE=1; shift ;;
        --force)           FORCE=1; shift ;;
        -h|--help)         usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Validate the arch list up front so a typo doesn't surface only after
# an hour of building.
IFS=',' read -ra ARCH_ARRAY <<< "$ARCHS"
for a in "${ARCH_ARRAY[@]}"; do
    case "$a" in
        generic|v3|v4) ;;
        *) echo "ERROR: --arch entries must be generic|v3|v4 (got: $a)"; exit 1 ;;
    esac
done

if [[ $SKIP_ISO -eq 0 || $SKIP_PENDRIVE -eq 0 ]]; then
    if ! sudo -n true 2>/dev/null; then
        echo ":: This script needs sudo for the ISO and pendrive steps."
        echo "   Run 'sudo -v' first to cache credentials, then re-run."
        exit 1
    fi
fi

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# 1. amiberry — build all requested arches in one container run
# ---------------------------------------------------------------------------
if [[ $SKIP_AMIBERRY -eq 0 ]]; then
    if [[ $FORCE -eq 1 ]]; then
        for a in "${ARCH_ARRAY[@]}"; do
            rm -f "${OUT_DIR}"/amiberry-*-"${a}"-x86_64.pkg.tar.zst
        done
    fi

    # Skip the (slow) docker run if every requested arch already has a
    # tagged .pkg in out/.
    needed=()
    for a in "${ARCH_ARRAY[@]}"; do
        if ! ls "${OUT_DIR}"/amiberry-*-"${a}"-x86_64.pkg.tar.zst >/dev/null 2>&1; then
            needed+=("$a")
        fi
    done
    if [[ ${#needed[@]} -eq 0 ]]; then
        echo "===> [1/3] amiberry: all requested arches already in out/, skipping."
    else
        # Single docker run for everything we need; build_amiberry.sh
        # accepts 'all' or one specific arch.
        case "${#needed[@]}" in
            3) target="all" ;;
            1) target="${needed[0]}" ;;
            *) target="all" ;;   # 2 arches: just build all, cheaper than two runs
        esac
        echo "===> [1/3] amiberry: building target='$target' (missing: ${needed[*]})"
        "${SCRIPT_DIR}/build_amiberry.sh" --cpu-arch "$target"
    fi
else
    echo "===> [1/3] amiberry: SKIPPED (--skip-amiberry)"
fi

# ---------------------------------------------------------------------------
# 2. ISOs — one per arch (each is a clean mkarchiso build by default)
# ---------------------------------------------------------------------------
if [[ $SKIP_ISO -eq 0 ]]; then
    for a in "${ARCH_ARRAY[@]}"; do
        if [[ $FORCE -eq 1 ]]; then
            rm -f "${OUT_DIR}"/amicachy-"${a}"-*-x86_64.iso
        fi
        if ls "${OUT_DIR}"/amicachy-"${a}"-*-x86_64.iso >/dev/null 2>&1; then
            echo "===> [2/3] ISO ($a): already in out/, skipping. Pass --force to rebuild."
            continue
        fi
        echo "===> [2/3] ISO ($a): building"
        sudo "${SCRIPT_DIR}/build_iso.sh" --cpu-arch "$a"
    done
else
    echo "===> [2/3] ISOs: SKIPPED (--skip-iso)"
fi

# ---------------------------------------------------------------------------
# 3. Pendrive .img — one per ISO
# ---------------------------------------------------------------------------
if [[ $SKIP_PENDRIVE -eq 0 ]]; then
    for a in "${ARCH_ARRAY[@]}"; do
        iso=$(ls -t "${OUT_DIR}"/amicachy-"${a}"-*-x86_64.iso 2>/dev/null | head -1)
        if [[ -z "$iso" ]]; then
            echo "===> [3/3] pendrive ($a): no matching ISO, skipping"
            continue
        fi
        # Pendrive .img name carries today's date, so versioning matches
        # whatever ISO we just produced. Force unless already present.
        img_glob="${OUT_DIR}/amicachy-pendrive-${a}-*.img"
        if [[ $FORCE -eq 1 ]]; then
            rm -f $img_glob
        fi
        if ls $img_glob >/dev/null 2>&1; then
            echo "===> [3/3] pendrive ($a): already in out/, skipping. Pass --force to rebuild."
            continue
        fi
        out_img="${OUT_DIR}/amicachy-pendrive-${a}-$(date +%Y.%m.%d).img"
        echo "===> [3/3] pendrive ($a): building from $(basename "$iso")"
        sudo "${SCRIPT_DIR}/build_pendrive.sh" --iso "$iso" --output "$out_img"
    done
else
    echo "===> [3/3] pendrives: SKIPPED (--skip-pendrive)"
fi

echo ""
echo "===> Matrix build complete. Artifacts in $OUT_DIR/:"
ls -1 "${OUT_DIR}"/amiberry-*.pkg.tar.zst "${OUT_DIR}"/amicachy-*.iso "${OUT_DIR}"/amicachy-pendrive-*.img 2>/dev/null \
    | sort
