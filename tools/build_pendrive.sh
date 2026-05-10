#!/usr/bin/env bash
# AmiCachy — Build a flashable pendrive image.
#
# Takes a previously built AmiCachy ISO and packages it together with a
# preformatted ext4 partition (label AMICACHY_DATA) into a single .img
# the recipient can flash with a one-liner:
#
#     sudo dd if=amicachy-pendrive-YYYY.MM.DD.img of=/dev/sdX bs=4M status=progress oflag=sync
#
# After flashing, the pendrive boots straight into AmiCachy with the
# user state (configs, ROMs, hardfiles, .uae) you bundled, all on a
# writable filesystem. No post-flash partitioning needed.
#
# Usage:
#   sudo ./tools/build_pendrive.sh \
#       --iso  out/amicachy-aros-YYYY.MM.DD-x86_64.iso \
#       [--output out/amicachy-pendrive-YYYY.MM.DD.img] \
#       [--persist-size 32G] \
#       [--persist-fs ntfs|exfat|ext4]   # default ntfs (Windows-friendly)
#       [--conf-dir DIR]                 # whole Amiberry/conf tree
#       [--roms-dir DIR]                 # whole Amiberry/roms tree
#       [--hardfiles-dir DIR]            # whole Amiberry/harddrives tree
#       [--rom FILE ...]                 # individual ROM(s)
#       [--hardfile FILE ...]            # individual hardfile(s)
#       [--uae FILE ...]                 # individual .uae profile(s)
#       [--boot-config NAME]             # filename inside conf/ to set as default
#       [--owner UID:GID]                # ownership inside the partition (default 1000:1000)
#
# Anything not passed is simply not pre-installed; the partition still
# exists with the right layout, ready for the user to drop files in.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${PROJECT_DIR}/out"

ISO=""
OUTPUT=""
PERSIST_SIZE="32G"
PERSIST_FS="ntfs"   # ntfs | exfat | ext4 — ntfs default so Windows mounts it natively
CONF_DIR=""
ROMS_DIR=""
HARDFILES_DIR=""
ROM_FILES=()
HARDFILE_FILES=()
UAE_FILES=()
BOOT_CONFIG_NAME=""
OWNER="1000:1000"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
    sed -n '4,30p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)            ISO="$2"; shift 2 ;;
        --output)         OUTPUT="$2"; shift 2 ;;
        --persist-size)   PERSIST_SIZE="$2"; shift 2 ;;
        --persist-fs)     PERSIST_FS="$2"; shift 2 ;;
        --conf-dir)       CONF_DIR="$2"; shift 2 ;;
        --roms-dir)       ROMS_DIR="$2"; shift 2 ;;
        --hardfiles-dir)  HARDFILES_DIR="$2"; shift 2 ;;
        --rom)            ROM_FILES+=("$2"); shift 2 ;;
        --hardfile)       HARDFILE_FILES+=("$2"); shift 2 ;;
        --uae)            UAE_FILES+=("$2"); shift 2 ;;
        --boot-config)    BOOT_CONFIG_NAME="$2"; shift 2 ;;
        --owner)          OWNER="$2"; shift 2 ;;
        -h|--help)        usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

case "$PERSIST_FS" in
    ntfs|exfat|ext4) ;;
    *) die "--persist-fs must be one of: ntfs, exfat, ext4 (got: $PERSIST_FS)" ;;
esac

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Must be run as root (loopback + mkfs + mount)."
[[ -n "$ISO" ]] || die "--iso is required. See $0 --help"
[[ -f "$ISO" ]] || die "ISO not found: $ISO"
ISO="$(realpath "$ISO")"

REQUIRED=(qemu-img sgdisk losetup mount umount blkid)
case "$PERSIST_FS" in
    ext4)  REQUIRED+=(mkfs.ext4) ;;
    ntfs)  REQUIRED+=(mkfs.ntfs) ;;
    exfat) REQUIRED+=(mkfs.exfat) ;;
esac
for cmd in "${REQUIRED[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd (install ntfs-3g for ntfs, exfatprogs for exfat)"
done

# Validate sources up front, before we touch a 30 GB image.
for d in "$CONF_DIR" "$ROMS_DIR" "$HARDFILES_DIR"; do
    [[ -z "$d" || -d "$d" ]] || die "Source directory not found: $d"
done
for f in "${ROM_FILES[@]}" "${HARDFILE_FILES[@]}" "${UAE_FILES[@]}"; do
    [[ -f "$f" ]] || die "Source file not found: $f"
done

# Size math
to_bytes() {
    # accepts 32G / 512M / 8K / plain bytes
    local s="$1"
    case "${s: -1}" in
        G|g) echo $(( ${s%[Gg]} * 1024 * 1024 * 1024 )) ;;
        M|m) echo $(( ${s%[Mm]} * 1024 * 1024 )) ;;
        K|k) echo $(( ${s%[Kk]} * 1024 )) ;;
        *)   echo "$s" ;;
    esac
}
ISO_BYTES="$(stat -c %s "$ISO")"
PERSIST_BYTES="$(to_bytes "$PERSIST_SIZE")"
HEADROOM=$(( 32 * 1024 * 1024 ))                # 32 MB for GPT backup + alignment
TOTAL_BYTES=$(( ISO_BYTES + PERSIST_BYTES + HEADROOM ))

if [[ -z "$OUTPUT" ]]; then
    mkdir -p "$OUT_DIR"
    OUTPUT="${OUT_DIR}/amicachy-pendrive-$(date +%Y.%m.%d).img"
fi
OUTPUT="$(realpath -m "$OUTPUT")"

echo ":: Building pendrive image"
echo "   ISO:          $ISO ($(numfmt --to=iec --suffix=B "$ISO_BYTES"))"
echo "   Output:       $OUTPUT"
echo "   Persist size: $PERSIST_SIZE ($(numfmt --to=iec --suffix=B "$PERSIST_BYTES"))"
echo "   Total image:  $(numfmt --to=iec --suffix=B "$TOTAL_BYTES")"
echo "   Owner:        $OWNER"
[[ -n "$CONF_DIR" ]]      && echo "   Conf dir:     $CONF_DIR"
[[ -n "$ROMS_DIR" ]]      && echo "   Roms dir:     $ROMS_DIR"
[[ -n "$HARDFILES_DIR" ]] && echo "   Hardfiles dir:$HARDFILES_DIR"
[[ ${#ROM_FILES[@]}      -gt 0 ]] && echo "   ROM files:    ${#ROM_FILES[@]}"
[[ ${#HARDFILE_FILES[@]} -gt 0 ]] && echo "   Hardfiles:    ${#HARDFILE_FILES[@]}"
[[ ${#UAE_FILES[@]}      -gt 0 ]] && echo "   UAE configs:  ${#UAE_FILES[@]}"
[[ -n "$BOOT_CONFIG_NAME" ]] && echo "   Boot default: $BOOT_CONFIG_NAME"
echo ""

# ---------------------------------------------------------------------------
# Build the .img
# ---------------------------------------------------------------------------

LOOP=""
MNT=""
cleanup() {
    set +e
    [[ -n "$MNT"  ]] && mountpoint -q "$MNT" && umount "$MNT"
    [[ -n "$MNT"  && -d "$MNT" ]] && rmdir "$MNT"
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
    set -e
}
trap cleanup EXIT

echo ":: Allocating $OUTPUT..."
truncate -s "$TOTAL_BYTES" "$OUTPUT"

echo ":: Copying ISO into the image (offset 0)..."
dd if="$ISO" of="$OUTPUT" bs=4M conv=notrunc status=progress

echo ":: Repairing GPT backup at the new end-of-disk..."
sgdisk --move-second-header "$OUTPUT" >/dev/null

echo ":: Adding AMICACHY_DATA partition at the tail..."
sgdisk --new=0:0:0 \
       --typecode=0:8300 \
       --change-name=0:AMICACHY_DATA \
       "$OUTPUT" >/dev/null

# Partprobe the image via loop, and pick the partition we just created
# (highest partition number).
LOOP="$(losetup --find --show -P "$OUTPUT")"
sleep 1   # let the kernel scan the GPT
PERSIST_PART="$(ls "${LOOP}"p* | sort -V | tail -1)"
[[ -b "$PERSIST_PART" ]] || die "Partition device not found after losetup: $PERSIST_PART"

echo ":: Formatting $PERSIST_PART ($PERSIST_FS, label AMICACHY_DATA)..."
MOUNT_OPTS=()
case "$PERSIST_FS" in
    ext4)
        mkfs.ext4 -q -L AMICACHY_DATA -E "root_owner=${OWNER}" "$PERSIST_PART"
        ;;
    ntfs)
        # mkfs.ntfs interactive prompt suppression: -F to force, -Q quick.
        mkfs.ntfs -Q -L AMICACHY_DATA -F "$PERSIST_PART"
        MOUNT_OPTS=(-t ntfs3 -o "uid=${OWNER%:*},gid=${OWNER#*:},umask=022")
        ;;
    exfat)
        mkfs.exfat -L AMICACHY_DATA "$PERSIST_PART"
        MOUNT_OPTS=(-t exfat -o "uid=${OWNER%:*},gid=${OWNER#*:},umask=022")
        ;;
esac

MNT="$(mktemp -d /tmp/amicachy-pendrive.XXXXXX)"
mount "${MOUNT_OPTS[@]}" "$PERSIST_PART" "$MNT"
mkdir -p "$MNT/Amiberry/conf" "$MNT/Amiberry/roms" "$MNT/Amiberry/harddrives"

# ---------------------------------------------------------------------------
# Populate the persistent partition
# ---------------------------------------------------------------------------

if [[ -n "$CONF_DIR" ]]; then
    echo ":: Copying $CONF_DIR/* -> Amiberry/conf/"
    cp -aL "$CONF_DIR"/. "$MNT/Amiberry/conf/" 2>/dev/null || true
fi
if [[ -n "$ROMS_DIR" ]]; then
    echo ":: Copying $ROMS_DIR/* -> Amiberry/roms/"
    cp -aL "$ROMS_DIR"/. "$MNT/Amiberry/roms/" 2>/dev/null || true
fi
if [[ -n "$HARDFILES_DIR" ]]; then
    echo ":: Copying $HARDFILES_DIR/* -> Amiberry/harddrives/"
    cp -aL "$HARDFILES_DIR"/. "$MNT/Amiberry/harddrives/" 2>/dev/null || true
fi

for f in "${ROM_FILES[@]}"; do
    echo ":: Copying ROM $f"
    cp -aL "$f" "$MNT/Amiberry/roms/"
done
for f in "${HARDFILE_FILES[@]}"; do
    echo ":: Copying hardfile $(basename "$f")  ($(numfmt --to=iec --suffix=B "$(stat -Lc %s "$f")"))"
    cp -aL "$f" "$MNT/Amiberry/harddrives/"
done
for f in "${UAE_FILES[@]}"; do
    echo ":: Copying .uae $(basename "$f")"
    cp -aL "$f" "$MNT/Amiberry/conf/"
done

if [[ -n "$BOOT_CONFIG_NAME" ]]; then
    BOOT_REF="/home/amiga/Amiberry/conf/${BOOT_CONFIG_NAME}"
    echo ":: Setting default boot config -> $BOOT_REF"
    echo "$BOOT_REF" > "$MNT/Amiberry/conf/amicachy-boot-config"
fi

# Make everything owned by amiga(1000) inside the guest. NTFS/exFAT
# already enforce ownership via the mount options above (uid=,gid=),
# but chown is harmless on them and authoritative for ext4.
chown -R "$OWNER" "$MNT/Amiberry" 2>/dev/null || true

sync
umount "$MNT" && rmdir "$MNT" && MNT=""
losetup -d "$LOOP" && LOOP=""

echo ""
echo ":: Done. Pendrive image written to:"
echo "   $OUTPUT  ($(numfmt --to=iec --suffix=B "$(stat -c %s "$OUTPUT")"))"
echo ""
echo "Flash to a pendrive (≥ $(numfmt --to=iec --suffix=B "$TOTAL_BYTES")) with:"
echo ""
echo "    sudo dd if=$OUTPUT of=/dev/sdX bs=4M status=progress oflag=sync"
echo ""
echo "Then boot from it."
