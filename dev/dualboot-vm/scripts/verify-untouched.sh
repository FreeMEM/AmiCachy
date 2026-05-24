#!/usr/bin/env bash
# Compare partition contents between a baseline and a post-install overlay,
# to prove the AmiCachy installer didn't touch the pre-existing OS partitions
# during a dual-boot install.
#
# Strategy: mount both qcow2 via qemu-nbd (read-only), parse partition table,
# hash each partition's raw contents (sha256), print a comparison table
# highlighting which partitions changed.
#
# Requires sudo (qemu-nbd needs to load the nbd kernel module and create
# /dev/nbdN devices, which root-owns by default).
#
# Usage:
#   sudo ./verify-untouched.sh --baseline debian12-ext4 --overlay overlays/...qcow2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUALBOOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINES_DIR="$DUALBOOT_DIR/baselines"

BASELINE=""
OVERLAY=""

usage() {
    cat <<EOF
Usage: sudo $0 --baseline NAME --overlay PATH

Compares partition-level sha256 between a baseline qcow2 and an overlay
produced by a test install. Partitions whose hash differs are flagged.

Required:
  --baseline NAME       Name (without .qcow2) of a baseline in baselines/
  --overlay PATH        Path to the overlay qcow2 (typically overlays/...qcow2)

Output: comparison table. A "CHANGED" row on a pre-existing OS partition
means the installer modified it — that's the bug we are guarding against.

Requires: sudo, qemu-utils (qemu-nbd), parted, coreutils (sha256sum).
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline)  BASELINE="$2"; shift 2 ;;
        --overlay)   OVERLAY="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *)           echo "Unknown option: $1" >&2; usage ;;
    esac
done

[[ -z "$BASELINE" || -z "$OVERLAY" ]] && usage
[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root (qemu-nbd needs it)" >&2; exit 1; }

BASELINE_PATH="$BASELINES_DIR/${BASELINE}.qcow2"
[[ -f "$BASELINE_PATH" ]] || { echo "ERROR: baseline not found: $BASELINE_PATH" >&2; exit 2; }
[[ -f "$OVERLAY" ]] || { echo "ERROR: overlay not found: $OVERLAY" >&2; exit 2; }

# Load nbd module if not present
modprobe nbd max_part=16 2>/dev/null || true

# Pick two free /dev/nbdN devices
pick_free_nbd() {
    for n in $(seq 0 15); do
        local dev="/dev/nbd${n}"
        [[ -e "$dev" ]] || continue
        # nbd device is free if size is 0
        if [[ "$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)" == "0" ]]; then
            echo "$dev"
            return 0
        fi
    done
    return 1
}

NBD_BASE="$(pick_free_nbd)" || { echo "ERROR: no free /dev/nbdN device" >&2; exit 3; }
NBD_OVER="$(pick_free_nbd)" || { echo "ERROR: no second free /dev/nbdN device" >&2; exit 3; }
# Second pick may have returned the same — qemu-nbd will error if so. Bail explicitly.
[[ "$NBD_BASE" != "$NBD_OVER" ]] || {
    # Walk forward one slot
    for n in $(seq 1 15); do
        candidate="/dev/nbd${n}"
        [[ "$candidate" != "$NBD_BASE" && "$(blockdev --getsize64 "$candidate" 2>/dev/null || echo 0)" == "0" ]] && {
            NBD_OVER="$candidate"; break
        }
    done
}

cleanup() {
    qemu-nbd --disconnect "$NBD_BASE" >/dev/null 2>&1 || true
    qemu-nbd --disconnect "$NBD_OVER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo ">>> Connecting baseline: $BASELINE_PATH → $NBD_BASE"
qemu-nbd --read-only --connect="$NBD_BASE" "$BASELINE_PATH"
echo ">>> Connecting overlay:  $OVERLAY → $NBD_OVER"
qemu-nbd --read-only --connect="$NBD_OVER" "$OVERLAY"

# Wait for partition scan
partprobe "$NBD_BASE" 2>/dev/null || true
partprobe "$NBD_OVER" 2>/dev/null || true
udevadm settle

list_partitions() {
    local dev="$1"
    parted -ms "$dev" unit s print 2>/dev/null | tail -n +3 | awk -F: '{print $1, $2, $3}'
}

hash_partition() {
    local dev="$1"
    sha256sum "$dev" 2>/dev/null | awk '{print $1}'
}

declare -A BASE_HASH
declare -A BASE_SIZE
echo ""
echo ">>> Hashing baseline partitions..."
while read -r idx start end; do
    [[ -z "$idx" ]] && continue
    part="${NBD_BASE}p${idx}"
    [[ -e "$part" ]] || continue
    BASE_HASH["$idx"]="$(hash_partition "$part")"
    BASE_SIZE["$idx"]="$(blockdev --getsize64 "$part")"
    printf "    p%s  size=%s  sha256=%s\n" "$idx" "${BASE_SIZE[$idx]}" "${BASE_HASH[$idx]:0:16}…"
done < <(list_partitions "$NBD_BASE")

declare -A OVER_HASH
declare -A OVER_SIZE
echo ""
echo ">>> Hashing overlay partitions..."
while read -r idx start end; do
    [[ -z "$idx" ]] && continue
    part="${NBD_OVER}p${idx}"
    [[ -e "$part" ]] || continue
    OVER_HASH["$idx"]="$(hash_partition "$part")"
    OVER_SIZE["$idx"]="$(blockdev --getsize64 "$part")"
    printf "    p%s  size=%s  sha256=%s\n" "$idx" "${OVER_SIZE[$idx]}" "${OVER_HASH[$idx]:0:16}…"
done < <(list_partitions "$NBD_OVER")

# Comparison table
echo ""
echo ">>> Comparison:"
printf "    %-4s  %-12s  %-12s  %s\n" "Part" "Status" "Size base→ovr" "Hash"
printf "    %s\n" "----------------------------------------------------------------"

ALL_IDX=$(echo "${!BASE_HASH[@]} ${!OVER_HASH[@]}" | tr ' ' '\n' | sort -u)
DIRTY_COUNT=0
for idx in $ALL_IDX; do
    bh="${BASE_HASH[$idx]:-MISSING}"
    oh="${OVER_HASH[$idx]:-MISSING}"
    bs="${BASE_SIZE[$idx]:-0}"
    os="${OVER_SIZE[$idx]:-0}"

    if [[ "$bh" == "MISSING" && "$oh" != "MISSING" ]]; then
        status="NEW"
        DIRTY_COUNT=$((DIRTY_COUNT + 1))
    elif [[ "$oh" == "MISSING" && "$bh" != "MISSING" ]]; then
        status="DELETED"
        DIRTY_COUNT=$((DIRTY_COUNT + 1))
    elif [[ "$bh" == "$oh" ]]; then
        status="UNCHANGED"
    else
        status="CHANGED"
        DIRTY_COUNT=$((DIRTY_COUNT + 1))
    fi

    printf "    p%-3s  %-12s  %d→%d  %s\n" "$idx" "$status" "$bs" "$os" "${oh:0:16}…"
done

echo ""
if [[ $DIRTY_COUNT -eq 0 ]]; then
    echo ">>> All partitions UNCHANGED. Baseline is intact."
else
    echo ">>> $DIRTY_COUNT partition(s) changed — review whether this was expected."
    echo "    (NEW partitions are normal for AmiCachy install in free space."
    echo "     CHANGED partitions on the pre-existing OS are a BUG.)"
fi
