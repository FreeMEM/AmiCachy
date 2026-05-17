#!/usr/bin/env bash
# AmiCachy — ISO build wrapper
# Imports CachyOS GPG keys, prepares directories, and runs mkarchiso.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROFILE_DIR="${PROJECT_DIR}/archiso"
WORK_DIR="${PROJECT_DIR}/work"
OUT_DIR="${PROJECT_DIR}/out"

# CachyOS package signing key
CACHYOS_KEY="882DCFE48E2051D48E2562ABF3B607488DB35A47"

usage() {
    echo "Usage: $(basename "$0") [--reuse-work] [--cpu-arch generic|v3|v4] [--seed-assets DIR] [--squashfs-comp xz|zstd]"
    echo ""
    echo "Options:"
    echo "  --reuse-work         Keep the work/ directory between builds (faster"
    echo "                       iteration when only the airootfs changed). Default"
    echo "                       is to wipe work/ so mkarchiso re-runs every stage —"
    echo "                       otherwise its stamp files cause packages.x86_64 and"
    echo "                       airootfs/ changes to be silently skipped."
    echo "  --clean              Deprecated: now the default. Accepted for backwards"
    echo "                       compatibility, no-op."
    echo "  --no-auto-amiberry   Skip auto-building amiberry when no .pkg matching"
    echo "                       --cpu-arch is found in out/. Default is to invoke"
    echo "                       ./tools/build_amiberry.sh --cpu-arch <arch> on the fly"
    echo "                       so a fresh checkout produces a complete ISO with"
    echo "                       one command."
    echo "  --cpu-arch ARCH      Target CPU baseline (default: v3):"
    echo "                         generic — any x86-64 CPU since 2003 (no AVX/AVX2)"
    echo "                         v3      — Haswell+/Excavator+ (AVX2)"
    echo "                         v4      — Rocket Lake+/Zen 4+ (AVX-512)"
    echo "                       Output ISO is named amicachy-<ARCH>-DATE-x86_64.iso so"
    echo "                       you can build all three side-by-side."
    echo "  --seed-assets DIR    Pre-load Amiga ROMs/HDFs from DIR into the ISO."
    echo "                       DIR must contain kickstarts/ and/or harddrives/"
    echo "                       subdirs. The contents become available to Amiberry"
    echo "                       on first boot via /usr/share/amiberry/{roms,harddrives}/."
    echo "                       Omit this flag to build a clean public ISO with no"
    echo "                       proprietary assets."
    echo "  --squashfs-comp C    Squashfs compression: 'xz' (default, smallest, slow)"
    echo "                       or 'zstd' (recommended for --seed-assets ISOs:"
    echo "                       ~5x faster, ISO 5-10% larger)."
    echo ""
    echo "Bundles installer data (tools/installer/, hardware_audit.py,"
    echo "packages.x86_64, pacman.conf) into airootfs before calling mkarchiso,"
    echo "and cleans up bundled files afterwards."
    echo ""
    echo "Requires: archiso package installed, root privileges."
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root (or via sudo)." >&2
        exit 1
    fi
}

import_cachyos_keys() {
    echo ":: Importing CachyOS signing key..."
    if ! pacman-key --list-keys "$CACHYOS_KEY" &>/dev/null; then
        pacman-key --recv-keys "$CACHYOS_KEY"
        pacman-key --lsign-key "$CACHYOS_KEY"
        echo "   Key imported and locally signed."
    else
        echo "   Key already present."
    fi
}

prepare_dirs() {
    mkdir -p "$WORK_DIR" "$OUT_DIR"
}

clean_work() {
    echo ":: Cleaning work directory..."
    rm -rf "$WORK_DIR"
}

bundle_installer_data() {
    # Copy project files into the airootfs tree so they end up inside the ISO.
    # This avoids duplicating files in the repo — they live in one canonical
    # location and are bundled only at build time.
    echo ":: Bundling installer data into airootfs..."

    local AIROOTFS="${PROFILE_DIR}/airootfs"
    local DEST_TOOLS="${AIROOTFS}/usr/share/amicachy/tools"
    local DEST_INST="${AIROOTFS}/usr/share/amicachy/installer"

    # installer Python package
    mkdir -p "${DEST_TOOLS}/installer"
    cp -a "${PROJECT_DIR}/tools/installer/"* "${DEST_TOOLS}/installer/"
    echo "   -> tools/installer/ -> airootfs (tools/installer/)"

    # Early Startup Control (Qt menu + check_hotkey.py probe). amilaunch.sh
    # spawns check_hotkey.py during the autologin window; if it isn't here
    # the F5 hotkey silently does nothing.
    mkdir -p "${DEST_TOOLS}/earlystartup"
    cp -a "${PROJECT_DIR}/tools/earlystartup/"* "${DEST_TOOLS}/earlystartup/"
    echo "   -> tools/earlystartup/ -> airootfs (tools/earlystartup/)"

    # Asset Manager (fetch_asset). The /usr/bin/amicachy-fetch-asset
    # launcher in airootfs imports from this path.
    mkdir -p "${DEST_TOOLS}/fetch_asset"
    cp -a "${PROJECT_DIR}/tools/fetch_asset/"* "${DEST_TOOLS}/fetch_asset/"
    echo "   -> tools/fetch_asset/ -> airootfs (tools/fetch_asset/)"

    # hardware_audit bridge
    cp -a "${PROJECT_DIR}/tools/hardware_audit.py" "${DEST_TOOLS}/hardware_audit.py"
    echo "   -> tools/hardware_audit.py -> airootfs (tools/)"

    # packages list and pacman.conf for the installer's install-to-disk step
    mkdir -p "${DEST_INST}"
    cp -a "${PROFILE_DIR}/packages.x86_64" "${DEST_INST}/packages.x86_64"
    cp -a "${PROFILE_DIR}/pacman.conf"     "${DEST_INST}/pacman.conf"
    echo "   -> packages.x86_64, pacman.conf -> airootfs (installer/)"

    echo "   Bundle complete."
}

unbundle_installer_data() {
    # Remove bundled files from the profile tree so they don't linger in the
    # repo working copy after a build.
    echo ":: Cleaning bundled data from profile tree..."

    local AIROOTFS="${PROFILE_DIR}/airootfs"
    rm -rf "${AIROOTFS}/usr/share/amicachy/tools/installer"
    rm -rf "${AIROOTFS}/usr/share/amicachy/tools/earlystartup"
    rm -rf "${AIROOTFS}/usr/share/amicachy/tools/fetch_asset"
    rm -f  "${AIROOTFS}/usr/share/amicachy/tools/hardware_audit.py"
    rm -f  "${AIROOTFS}/usr/share/amicachy/installer/packages.x86_64"
    rm -f  "${AIROOTFS}/usr/share/amicachy/installer/pacman.conf"
}

bundle_seed_assets() {
    # Stage Amiga ROMs and HDFs from a host directory into the airootfs so the
    # built ISO ships with them preloaded. Maps:
    #   $SEED_ASSETS/kickstarts/  ->  /usr/share/amicachy/seed-assets/roms/
    #   $SEED_ASSETS/harddrives/  ->  /usr/share/amicachy/seed-assets/harddrives/
    # On first boot, amicachy-seed-assets.service symlinks these into
    # /usr/share/amiberry/{roms,harddrives}/ so Amiberry sees them.
    [[ -z "${SEED_ASSETS:-}" ]] && return 0

    if [[ ! -d "$SEED_ASSETS" ]]; then
        echo "ERROR: --seed-assets path does not exist: $SEED_ASSETS" >&2
        exit 1
    fi

    echo ":: Bundling seed assets from $SEED_ASSETS..."

    local AIROOTFS="${PROFILE_DIR}/airootfs"
    local SEED_DIR="${AIROOTFS}/usr/share/amicachy/seed-assets"
    local copied=0

    if [[ -d "$SEED_ASSETS/kickstarts" ]]; then
        mkdir -p "${SEED_DIR}/roms"
        cp -aL "$SEED_ASSETS/kickstarts/." "${SEED_DIR}/roms/"
        local n
        n="$(find "$SEED_ASSETS/kickstarts" -maxdepth 1 -type f | wc -l)"
        echo "   -> kickstarts/ ($n file(s)) -> seed-assets/roms/"
        copied=$((copied + n))
    fi

    if [[ -d "$SEED_ASSETS/harddrives" ]]; then
        mkdir -p "${SEED_DIR}/harddrives"
        cp -aL "$SEED_ASSETS/harddrives/." "${SEED_DIR}/harddrives/"
        local n
        n="$(find "$SEED_ASSETS/harddrives" -maxdepth 1 -type f | wc -l)"
        echo "   -> harddrives/ ($n file(s)) -> seed-assets/harddrives/"
        copied=$((copied + n))
    fi

    if [[ $copied -eq 0 ]]; then
        echo "   WARN: $SEED_ASSETS contains neither kickstarts/ nor harddrives/"
    else
        local sz
        sz="$(du -sh "$SEED_DIR" 2>/dev/null | cut -f1)"
        echo "   Total bundled: $sz"
    fi
    HAS_SEED_ASSETS=1
}

unbundle_seed_assets() {
    [[ "${HAS_SEED_ASSETS:-0}" -eq 1 ]] || return 0
    echo ":: Cleaning seed assets from profile tree..."
    rm -rf "${PROFILE_DIR}/airootfs/usr/share/amicachy/seed-assets"
}

setup_local_packages() {
    # If amiberry (or other custom packages) have been compiled and are in out/,
    # create a local pacman repo so mkarchiso can install them into the ISO.
    local LOCAL_REPO="${PROFILE_DIR}/local-repo"
    local pkgs=()

    # Prefer packages tagged with the current --cpu-arch, since builds before
    # 2026-05 emitted un-tagged binaries (built with -march=native, host-pinned)
    # that SIGILL on any CPU other than the one that compiled them.
    # Match: amiberry-<ver>-<rel>-<arch>-x86_64.pkg.tar.zst
    _collect_arch_pkgs() {
        pkgs=()
        for f in "${OUT_DIR}"/amiberry-*-"${CPU_ARCH}"-x86_64.pkg.tar.zst; do
            [[ -f "$f" ]] && pkgs+=("$f")
        done
    }
    _collect_arch_pkgs

    # Auto-build if missing and the user has not opted out.
    if [[ ${#pkgs[@]} -eq 0 && "${AUTO_AMIBERRY:-1}" -eq 1 ]]; then
        echo ":: No amiberry-${CPU_ARCH} package found; building it now (--no-auto-amiberry to skip)..."
        if ! "${SCRIPT_DIR}/build_amiberry.sh" --cpu-arch "$CPU_ARCH"; then
            echo ":: ERROR: build_amiberry.sh failed; aborting ISO build."
            echo "   Re-run with --no-auto-amiberry to continue without amiberry."
            exit 1
        fi
        _collect_arch_pkgs
    fi

    if [[ ${#pkgs[@]} -eq 0 ]]; then
        # Fall back to un-tagged packages, but warn loudly — they may have
        # been built with -march=native on a different host CPU.
        local untagged=()
        for f in "${OUT_DIR}"/amiberry-*-x86_64.pkg.tar.zst; do
            [[ -f "$f" ]] || continue
            # Skip already-tagged variants (covered above).
            case "$(basename "$f")" in
                *-generic-x86_64.pkg.tar.zst|*-v3-x86_64.pkg.tar.zst|*-v4-x86_64.pkg.tar.zst) continue ;;
            esac
            untagged+=("$f")
        done
        if [[ ${#untagged[@]} -eq 0 ]]; then
            echo ":: WARNING: No amiberry package for --cpu-arch $CPU_ARCH in out/"
            echo "   Build it first: ./tools/build_amiberry.sh --cpu-arch $CPU_ARCH"
            echo "   The ISO will be built WITHOUT amiberry."
            echo ""
            HAS_LOCAL_REPO=0
            return
        fi
        echo ":: WARNING: no tagged amiberry-*-${CPU_ARCH}-x86_64.pkg.tar.zst; using untagged build"
        echo "   That .pkg was likely built with -march=native (host-pinned) and may"
        echo "   SIGILL on other CPUs. Rebuild with:"
        echo "       ./tools/build_amiberry.sh --cpu-arch $CPU_ARCH"
        pkgs=("${untagged[@]}")
    fi

    echo ":: Setting up local package repository..."
    mkdir -p "$LOCAL_REPO"

    # Most-recently-modified wins within the matching set, so a fresh
    # tagged build supersedes any older one.
    local latest_pkg
    latest_pkg=$(ls -t "${pkgs[@]}" | head -1)
    cp "$latest_pkg" "$LOCAL_REPO/"
    echo "   -> $(basename "$latest_pkg")"

    # Create repo database
    repo-add "${LOCAL_REPO}/amicachy-local.db.tar.gz" "${LOCAL_REPO}"/*.pkg.tar.zst

    # Add local repo to pacman.conf
    cat >> "${PROFILE_DIR}/pacman.conf" << EOF

# --- AmiCachy Local Repo (auto-generated, removed after build) ---
[amicachy-local]
SigLevel = Never
Server = file://${LOCAL_REPO}
EOF

    # Add amiberry to the package list
    echo "amiberry" >> "${PROFILE_DIR}/packages.x86_64"

    HAS_LOCAL_REPO=1
    echo "   Local repo ready. amiberry will be included in the ISO."
}

cleanup_local_packages() {
    if [[ "${HAS_LOCAL_REPO:-0}" -eq 1 ]]; then
        echo ":: Cleaning local package repository..."
        rm -rf "${PROFILE_DIR}/local-repo"
        # Remove appended local repo section from pacman.conf, then trim
        # any trailing blank lines the heredoc had left behind.
        sed -i '/^# --- AmiCachy Local Repo/,$ d' "${PROFILE_DIR}/pacman.conf"
        sed -i -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' "${PROFILE_DIR}/pacman.conf"
        # Remove amiberry line from packages.x86_64
        sed -i '/^amiberry$/d' "${PROFILE_DIR}/packages.x86_64"
    fi
}

select_pacman_conf() {
    # Materialise archiso/pacman.conf from the per-arch template the
    # user requested. mkarchiso reads pacman.conf by name (set in
    # profiledef.sh as pacman_conf="pacman.conf"), so the file has to
    # exist with the exact name during the build. The template is the
    # source of truth and stays in git; pacman.conf itself is gitignored.
    local src="${PROFILE_DIR}/pacman-${CPU_ARCH}.conf"
    [[ -f "$src" ]] || die "Template not found: $src"
    cp "$src" "${PROFILE_DIR}/pacman.conf"
    echo ":: Using ${src##*/} for this build"
}

cleanup_pacman_conf() {
    rm -f "${PROFILE_DIR}/pacman.conf"
}

rename_iso_output() {
    # mkarchiso emits amicachy-DATE-x86_64.iso (iso_name from
    # profiledef.sh). Tag it with the arch so the three variants live
    # side by side without collisions.
    local raw
    raw=$(ls -t "${OUT_DIR}"/amicachy-[0-9]*-x86_64.iso 2>/dev/null | head -1)
    [[ -n "$raw" && -f "$raw" ]] || return 0
    local date_part="${raw##*amicachy-}"
    date_part="${date_part%-x86_64.iso}"
    local renamed="${OUT_DIR}/amicachy-${CPU_ARCH}-${date_part}-x86_64.iso"
    mv -f "$raw" "$renamed"
    echo ":: Renamed -> ${renamed##*/}"
}

die() { echo "ERROR: $*" >&2; exit 1; }

build_iso() {
    echo ":: Building ISO..."
    mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR"
    rename_iso_output
    echo ""
    echo ":: Done! ISO written to: ${OUT_DIR}/"
    ls -lh "${OUT_DIR}"/*.iso 2>/dev/null || echo "   (no .iso found — check for errors above)"
}

# --- Main ---

REUSE_WORK=0
SEED_ASSETS=""
SQUASHFS_COMP="xz"
CPU_ARCH="v3"
AUTO_AMIBERRY=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reuse-work) REUSE_WORK=1; shift ;;
        --no-auto-amiberry) AUTO_AMIBERRY=0; shift ;;
        --clean) shift ;;   # deprecated no-op (clean is now the default)
        --cpu-arch)
            [[ $# -ge 2 ]] || { echo "ERROR: --cpu-arch requires generic|v3|v4"; usage; }
            CPU_ARCH="$2"; shift 2 ;;
        --cpu-arch=*)
            CPU_ARCH="${1#*=}"; shift ;;
        --seed-assets)
            [[ $# -ge 2 ]] || { echo "ERROR: --seed-assets requires a path"; usage; }
            SEED_ASSETS="$2"; shift 2 ;;
        --seed-assets=*)
            SEED_ASSETS="${1#*=}"; shift ;;
        --squashfs-comp)
            [[ $# -ge 2 ]] || { echo "ERROR: --squashfs-comp requires xz|zstd"; usage; }
            SQUASHFS_COMP="$2"; shift 2 ;;
        --squashfs-comp=*)
            SQUASHFS_COMP="${1#*=}"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

case "$SQUASHFS_COMP" in
    xz|zstd) ;;
    *) echo "ERROR: --squashfs-comp must be 'xz' or 'zstd' (got: $SQUASHFS_COMP)"; exit 1 ;;
esac
case "$CPU_ARCH" in
    generic|v3|v4) ;;
    *) echo "ERROR: --cpu-arch must be 'generic', 'v3' or 'v4' (got: $CPU_ARCH)"; exit 1 ;;
esac
export AMICACHY_SQUASHFS_COMP="$SQUASHFS_COMP"

check_root
import_cachyos_keys
# Clean by default. mkarchiso uses stamp files in work/ to skip stages it
# has already done, so reusing work/ across edits silently produces an
# outdated ISO (the most common cause of "my changes didn't take effect").
# Use --reuse-work explicitly when you know your edits only affect things
# downstream of the cached stages.
if [[ $REUSE_WORK -eq 0 ]]; then
    clean_work
else
    echo ":: Reusing work/ (--reuse-work). mkarchiso stamps may skip stages."
fi
prepare_dirs

# mkarchiso pins SOURCE_DATE_EPOCH from $work_dir/build_date when that
# file exists (mkarchiso:1881-1885), which would freeze the build mtime
# to the first run. Remove it on every build so the new SOURCE_DATE_EPOCH
# we set below sticks — under --reuse-work as well, so the .iso mtime
# always reflects this build, not a stale stamp.
rm -f "${WORK_DIR}/build_date"
export SOURCE_DATE_EPOCH="$(date +%s)"
select_pacman_conf
setup_local_packages
bundle_installer_data
bundle_seed_assets
trap 'unbundle_installer_data; cleanup_local_packages; unbundle_seed_assets; cleanup_pacman_conf' EXIT
build_iso
