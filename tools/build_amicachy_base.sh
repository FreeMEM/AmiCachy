#!/usr/bin/env bash
# AmiCachy — Build the amicachy-base package.
#
# Produces out/amicachy-base-<VER>-<REL>-any.pkg.tar.zst, the base rootfs
# payload for the *installed* system under the Calamares migration (F3.0).
# See pkg/amicachy-base/PKGBUILD for what it bundles and why.
#
# Unlike build_amiberry.sh this needs no Docker: the package is arch=any and
# compiles nothing — package() just assembles files, collecting the shared
# assets from archiso/airootfs/ at build time. It must therefore run from a
# full AmiCachy checkout (the PKGBUILD reads ../../archiso/airootfs).
#
# Usage: ./tools/build_amicachy_base.sh
# Output: out/amicachy-base-<VER>-<REL>-any.pkg.tar.zst

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PKG_DIR="${PROJECT_DIR}/pkg/amicachy-base"
OUT_DIR="${PROJECT_DIR}/out"

if [[ "$(id -u)" -eq 0 ]]; then
    echo "ERROR: makepkg must not run as root. Run as your normal user." >&2
    exit 1
fi

if ! command -v makepkg >/dev/null 2>&1; then
    echo "ERROR: makepkg not found (install pacman/base-devel)." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

# Keep makepkg's transient src/pkg trees out of the repo, and drop the
# finished package straight into out/.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ":: Building amicachy-base..."
cd "$PKG_DIR"
BUILDDIR="$WORK" PKGDEST="$OUT_DIR" makepkg -f --noconfirm --nodeps

echo ""
echo ":: Done. Package(s):"
ls -1 "${OUT_DIR}"/amicachy-base-*.pkg.tar.zst 2>/dev/null || {
    echo "ERROR: no amicachy-base package produced." >&2
    exit 1
}
