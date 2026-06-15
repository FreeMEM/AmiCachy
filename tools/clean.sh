#!/usr/bin/env bash
# tools/clean.sh — reclaim disk in out/ and dev/ from regenerable build/test
# artifacts. The ISO/pendrive build flow drops a fresh dated artifact every run,
# so these dirs balloon; this prunes the stale ones.
#
# SAFE BY DEFAULT. Runs as a dry-run unless you pass --yes, and NEVER touches:
#   - dev/dualboot-vm/baselines/   (Debian/Win11 baselines — expensive, semi-manual)
#   - out/amicachy-target.sfs      (current target rootfs, needed to build ISOs)
#   - the NEWEST amicachy-v3/v4 ISO + any *-latest.iso symlink
#   - dev/dualboot-vm/ovmf/OVMF_VARS-template* and overlays' backing files
#
# Default (safe) sweep removes:
#   - old dated ISOs in out/ (all but the newest v3 + newest v4 + latest symlinks;
#     *pendrive*/*loaded* are spared unless --releases)
#   - dev/dualboot-vm/ overlays + per-run OVMF VARS + logs (disposable test runs)
#   - small dev/ scratch: test-iso-scratch.qcow2, *-test.img, *.log, *.sock*
#
# Opt-in extra reclaim (each is regenerable via the build_*.sh scripts):
#   --pendrives  also delete out/*pendrive*.img  (release pendrive images — big)
#   --loaded     also delete out/*loaded*.iso + out/*.7z.* (asset-loaded ISO + archives)
#   --releases   shorthand for --pendrives --loaded
#   --dev-vms    also delete dev/amicachy-dev.qcow2 and dev/test-iso-persist.img
#                (big dev/test VM scratch disks — may hold state you set up)
#
# Usage:
#   ./tools/clean.sh                 # dry-run, safe sweep (shows what it would free)
#   ./tools/clean.sh --yes           # do the safe sweep
#   ./tools/clean.sh --pendrives --yes            # safe sweep + drop pendrive images
#   ./tools/clean.sh --releases --dev-vms --yes   # full reclaim

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/out"
DEV="$REPO/dev"
DB="$DEV/dualboot-vm"

DRY=1
PENDRIVES=0
LOADED=0
DEV_VMS=0
for a in "$@"; do
    case "$a" in
        --yes)       DRY=0 ;;
        --pendrives) PENDRIVES=1 ;;
        --loaded)    LOADED=1 ;;
        --releases)  PENDRIVES=1; LOADED=1 ;;   # convenience: both of the above
        --dev-vms)   DEV_VMS=1 ;;
        -h|--help)   sed -n '2,33p' "$0"; exit 0 ;;
        *) echo "Unknown option: $a" >&2; exit 1 ;;
    esac
done

FREED=0
del() {
    # del <path>...  — delete (or, in dry-run, report) each existing path.
    local f sz bytes
    for f in "$@"; do
        [[ -e "$f" || -L "$f" ]] || continue
        bytes=$(du -s --block-size=1 "$f" 2>/dev/null | cut -f1 || echo 0)  # actual blocks, not apparent (sparse-safe)
        sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
        FREED=$((FREED + bytes))
        if [[ $DRY -eq 1 ]]; then
            printf '    [dry-run] %6s  %s\n' "$sz" "${f#$REPO/}"
        else
            printf '    rm        %6s  %s\n' "$sz" "${f#$REPO/}"
            rm -rf "$f"
        fi
    done
}

# Resolve which ISOs to KEEP: newest v3, newest v4, and any *-latest.iso symlink.
keep_iso=" "
for pat in "amicachy-v3-"*"-x86_64.iso" "amicachy-v4-"*"-x86_64.iso"; do
    newest=$(ls -t "$OUT/"$pat 2>/dev/null | head -1 || true)
    [[ -n "${newest:-}" ]] && keep_iso+="$(basename "$newest") "
done

echo ">>> Mode: $([[ $DRY -eq 1 ]] && echo 'DRY-RUN (pass --yes to delete)' || echo 'DELETING')"
echo ">>> Keeping newest ISOs:${keep_iso}+ *-latest.iso symlinks"
echo ""

echo ">>> out/: stale ISOs"
shopt -s nullglob
for iso in "$OUT/"*.iso; do
    [[ -L "$iso" ]] && continue                                  # keep symlinks
    base="$(basename "$iso")"
    [[ "$keep_iso" == *" $base "* ]] && continue                 # keep newest v3/v4
    if [[ "$base" == *loaded* ]]; then
        [[ $LOADED -eq 1 ]] && del "$iso"                        # loaded ISO: only with --loaded
        continue
    fi
    del "$iso"
done

echo ">>> dev/dualboot-vm/: test overlays, per-run VARS, logs"
del "$DB"/overlays/*.qcow2
del "$DB"/ovmf/OVMF_VARS-run-*.fd
del "$DB"/logs/*.serial.log "$DB"/logs/*.monitor.sock

echo ">>> dev/: scratch disks and logs"
del "$DEV"/test-iso-scratch.qcow2
del "$DEV"/*-test.img
del "$DEV"/*.log "$DEV"/*.sock.pid "$DEV"/*.sock

if [[ $PENDRIVES -eq 1 ]]; then
    echo ">>> out/: pendrive release images (--pendrives)"
    del "$OUT"/*pendrive*.img
fi

if [[ $LOADED -eq 1 ]]; then
    echo ">>> out/: loaded-ISO split archives (--loaded; the .iso itself is pruned above)"
    del "$OUT"/*.7z.*
fi

if [[ $DEV_VMS -eq 1 ]]; then
    echo ">>> dev/: big VM scratch disks (--dev-vms)"
    del "$DEV"/amicachy-dev.qcow2
    del "$DEV"/test-iso-persist.img
fi

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1} bytes"; }
echo ""
if [[ $DRY -eq 1 ]]; then
    echo ">>> DRY-RUN: would free ~$(human "$FREED"). Re-run with --yes to delete."
    [[ $PENDRIVES -eq 0 ]] && echo "    (add --pendrives to also prune out/*pendrive*.img)"
    [[ $LOADED -eq 0 ]]    && echo "    (add --loaded to also prune the loaded ISO + .7z archives)"
    [[ $DEV_VMS -eq 0 ]]   && echo "    (add --dev-vms to also prune dev/amicachy-dev.qcow2 + test-iso-persist.img)"
else
    echo ">>> Freed ~$(human "$FREED")."
fi
