#!/usr/bin/env bash
# AmiCachy — Build the calamares-config-amicachy package.
#
# Produces out/calamares-config-amicachy-<VER>-<REL>-any.pkg.tar.zst: the
# Calamares branding + module configuration + custom amicachy-postinstall
# Python job that drive the AmiCachy installer (F3). See the PKGBUILD for
# what it ships.
#
# arch=any, compiles nothing (package() is a plain cp -a of files/), so no
# Docker needed — but it must run from a checkout (the PKGBUILD reads files/
# next to it). depends=cachyos-calamares is asserted at install time, not here.
#
# Usage:  ./tools/build_calamares_config.sh
# Output: out/calamares-config-amicachy-<VER>-<REL>-any.pkg.tar.zst

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PKG_DIR="${PROJECT_DIR}/pkg/calamares-config-amicachy"
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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ":: Building calamares-config-amicachy..."
cd "$PKG_DIR"
BUILDDIR="$WORK" PKGDEST="$OUT_DIR" makepkg -f --noconfirm --nodeps

echo ""
echo ":: Done. Package(s):"
ls -1 "${OUT_DIR}"/calamares-config-amicachy-*.pkg.tar.zst 2>/dev/null || {
    echo "ERROR: no calamares-config-amicachy package produced." >&2
    exit 1
}
