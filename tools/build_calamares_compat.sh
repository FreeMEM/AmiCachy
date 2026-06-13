#!/usr/bin/env bash
# AmiCachy — Build the calamares-compat-libs package.
#
# Produces out/calamares-compat-libs-<VER>-<REL>-x86_64.pkg.tar.zst: a
# TEMPORARY compatibility shim that ships the old soname'd shared libraries
# (yaml-cpp 0.8 + the boost 1.89 suite) the stale cachyos-calamares binary
# needs at startup. See pkg/calamares-compat-libs/PKGBUILD for the full why.
#
# The PKGBUILD downloads the two source packages from the Arch Linux Archive
# (verified by sha256) and extracts just the needed .so — nothing is vendored
# in git. Needs network at build time (like build_amiberry.sh).
#
# Usage:  ./tools/build_calamares_compat.sh
# Output: out/calamares-compat-libs-<VER>-<REL>-x86_64.pkg.tar.zst

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PKG_DIR="${PROJECT_DIR}/pkg/calamares-compat-libs"
OUT_DIR="${PROJECT_DIR}/out"

if [[ "$(id -u)" -eq 0 ]]; then
    echo "ERROR: makepkg must not run as root. Run as your normal user." >&2
    exit 1
fi
command -v makepkg >/dev/null || { echo "ERROR: makepkg not found." >&2; exit 1; }

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ":: Building calamares-compat-libs (downloads yaml-cpp 0.8 + boost 1.89 from the Arch Archive)..."
cd "$PKG_DIR"
BUILDDIR="$WORK" SRCDEST="$WORK" PKGDEST="$OUT_DIR" makepkg -f --noconfirm

echo ""
echo ":: Done. Package(s):"
ls -1 "${OUT_DIR}"/calamares-compat-libs-*.pkg.tar.zst 2>/dev/null || {
    echo "ERROR: no calamares-compat-libs package produced." >&2
    exit 1
}
