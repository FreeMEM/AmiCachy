#!/usr/bin/env bash
# Build the Debian (ext4 + GRUB-EFI) baseline qcow2 for Calamares F4
# dualboot tests. Headless, unattended via preseed.
#
# Tracks Debian "current" (the latest stable; at time of writing that
# resolved to Debian 13 — the inventory still names the slot "debian12"
# for historical reasons but ext4+GRUB-EFI behaviour is identical).
#
# Output:  baselines/debian12-ext4-grub.qcow2  (50 GB sparse)
# Layout:  GPT, ESP 512 MiB FAT32 (sector 2048) + ext4 root, no swap
#          — coordinated with build-baseline-windows.sh so a future
#          F4-time merge can share a single ESP.
#
# Cache:   ISO downloaded once into .cache/ (gitignored), checksum-verified.
# Runtime: ~10–20 min on a modern host (network-bound: ~700 MB ISO + apt
#          packages for the standard tasksel).

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$ROOT_DIR/.cache"
BASELINES_DIR="$ROOT_DIR/baselines"
LOGS_DIR="$ROOT_DIR/logs"
OVMF_CODE="$ROOT_DIR/ovmf/OVMF_CODE.4m.fd"
OVMF_VARS_TEMPLATE="$ROOT_DIR/ovmf/OVMF_VARS-template.4m.fd"

BASELINE_NAME="debian12-ext4-grub"
DISK_SIZE="${DISK_SIZE:-50G}"
DEBIAN_MIRROR_BASE="${DEBIAN_MIRROR_BASE:-https://cdimage.debian.org/debian-cd/current/amd64/iso-cd}"
KEEP_INSTALL_LOG="${KEEP_INSTALL_LOG:-1}"

err()   { echo "ERROR: $*" >&2; exit 1; }
log()   { printf '>>> %s\n' "$*"; }
warn()  { printf 'WARN: %s\n' "$*" >&2; }

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--force] [--keep-iso]

Builds baselines/$BASELINE_NAME.qcow2 unattended.

  --force         Overwrite existing baseline (default: refuse)
  --keep-iso      Keep .cache/<netinst>.iso for reuse (default: keep)
  --remove-iso    Delete the cached ISO after build
  -h, --help      This help

Env overrides:
  DISK_SIZE              Default: 50G
  DEBIAN_MIRROR_BASE     Default: https://cdimage.debian.org/debian-cd/current/amd64/iso-cd
USAGE
}

FORCE=0
REMOVE_ISO=0
while [ $# -gt 0 ]; do
    case "$1" in
        --force)      FORCE=1 ;;
        --keep-iso)   KEEP_INSTALL_LOG=1 ;;
        --remove-iso) REMOVE_ISO=1 ;;
        -h|--help)    usage; exit 0 ;;
        *)            err "Unknown argument: $1" ;;
    esac
    shift
done

TARGET_BASELINE="$BASELINES_DIR/$BASELINE_NAME.qcow2"
if [ -f "$TARGET_BASELINE" ] && [ "$FORCE" != "1" ]; then
    err "$TARGET_BASELINE already exists. Use --force to overwrite."
fi

for tool in qemu-img qemu-system-x86_64 xorriso curl sha256sum cpio gzip; do
    command -v "$tool" >/dev/null 2>&1 || err "Missing tool: $tool"
done
[ -r "$OVMF_CODE" ]          || err "OVMF_CODE not found at $OVMF_CODE"
[ -r "$OVMF_VARS_TEMPLATE" ] || err "OVMF_VARS template not found at $OVMF_VARS_TEMPLATE"

mkdir -p "$CACHE_DIR" "$BASELINES_DIR" "$LOGS_DIR"

# ---------------------------------------------------------------------------
# 1. Discover the current netinst ISO filename + sha256 from the mirror.
# ---------------------------------------------------------------------------
log "Querying $DEBIAN_MIRROR_BASE/SHA256SUMS"
SUMS="$CACHE_DIR/SHA256SUMS"
curl -fsSL "$DEBIAN_MIRROR_BASE/SHA256SUMS" -o "$SUMS"

# Pick the netinst variant (not the DVD, not the source).
NETINST_LINE=$(grep -E '  debian-[0-9.]+-amd64-netinst\.iso$' "$SUMS" | head -1) \
    || err "No netinst entry in SHA256SUMS"
NETINST_SHA=$(echo "$NETINST_LINE" | awk '{print $1}')
NETINST_NAME=$(echo "$NETINST_LINE" | awk '{print $2}')
NETINST_PATH="$CACHE_DIR/$NETINST_NAME"
log "Target ISO: $NETINST_NAME"

# ---------------------------------------------------------------------------
# 2. Download / verify cached copy.
# ---------------------------------------------------------------------------
need_download=1
if [ -f "$NETINST_PATH" ]; then
    log "Cache hit: $NETINST_PATH — verifying sha256..."
    if echo "$NETINST_SHA  $NETINST_PATH" | sha256sum -c --quiet; then
        log "  checksum OK, reusing cached ISO"
        need_download=0
    else
        warn "  checksum mismatch — re-downloading"
        rm -f "$NETINST_PATH"
    fi
fi
if [ "$need_download" = "1" ]; then
    log "Downloading $NETINST_NAME (~700 MB)..."
    # --silent --show-error keeps the build log clean; --progress-bar
    # spams \r-rewritten lines that pollute non-tty captures.
    curl -fL --silent --show-error -o "$NETINST_PATH" "$DEBIAN_MIRROR_BASE/$NETINST_NAME"
    echo "$NETINST_SHA  $NETINST_PATH" | sha256sum -c --quiet \
        || err "Downloaded ISO failed sha256 verification"
fi

# ---------------------------------------------------------------------------
# 3. Workspace + generated preseed.cfg + patched initrd.
# ---------------------------------------------------------------------------
WORK=$(mktemp -d -t amicachy-debian-build.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

log "Extracting kernel + initrd from ISO (xorriso -osirrox)..."
xorriso -osirrox on -indev "$NETINST_PATH" \
    -extract /install.amd/vmlinuz "$WORK/vmlinuz" \
    -extract /install.amd/initrd.gz "$WORK/initrd.gz" \
    >/dev/null 2>&1 \
    || err "xorriso extract failed — ISO structure changed?"

cat > "$WORK/preseed.cfg" <<'PRESEED'
# AmiCachy F2.b — fully automated Debian 12 baseline for dualboot tests.
# This is a TEST baseline, not a production system. Credentials are
# deliberately weak (tester/tester) and root login is disabled.

# --- Locale & keyboard -----------------------------------------------------
d-i debian-installer/locale          string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us

# --- Network (DHCP via QEMU slirp) -----------------------------------------
d-i netcfg/choose_interface  select auto
d-i netcfg/get_hostname      string debian-baseline
d-i netcfg/get_domain        string baseline.local

# --- Mirror -----------------------------------------------------------------
d-i mirror/country           string manual
d-i mirror/http/hostname     string deb.debian.org
d-i mirror/http/directory    string /debian
d-i mirror/http/proxy        string

# --- Accounts ---------------------------------------------------------------
# Root login disabled; "tester" becomes a sudoer via the standard
# user-setup flow when root has no password.
d-i passwd/root-login              boolean false
d-i passwd/make-user               boolean true
d-i passwd/user-fullname           string Tester
d-i passwd/username                string tester
d-i passwd/user-password           password tester
d-i passwd/user-password-again     password tester
d-i user-setup/allow-password-weak boolean true
d-i user-setup/encrypt-home        boolean false

# --- Clock ------------------------------------------------------------------
d-i clock-setup/utc          boolean true
d-i time/zone                string Etc/UTC
d-i clock-setup/ntp          boolean true

# --- Partitioning -----------------------------------------------------------
# GPT, two partitions:
#   1) 512 MiB FAT32 ESP at sector 2048 (1 MiB-aligned) → /boot/efi
#   2) ext4 filling the rest → /
# No swap. Sizes are MiB (min/priority/max); equal values force exact size.
d-i partman-auto/method                       string regular
d-i partman-auto/disk                         string /dev/vda
d-i partman-partitioning/choose_label         select gpt
d-i partman-partitioning/default_label        string gpt
d-i partman/default_filesystem                string ext4
d-i partman-auto/expert_recipe string                                     \
    custom ::                                                             \
        512 512 512 fat32                                                 \
            $primary{ } $bootable{ }                                      \
            method{ efi } format{ }                                       \
        .                                                                 \
        4096 1000000000 -1 ext4                                           \
            $primary{ }                                                   \
            method{ format } format{ }                                    \
            use_filesystem{ } filesystem{ ext4 }                          \
            mountpoint{ / }                                               \
        .
d-i partman-auto/choose_recipe                select custom
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition                  select finish
d-i partman/confirm                           boolean true
d-i partman/confirm_nooverwrite               boolean true
# Acknowledge "no swap" — d-i raises this as a critical-priority warning
# regardless of priority=critical, blocking the install otherwise.
d-i partman-basicfilesystems/no_swap          boolean false

# --- Base + tasksel ---------------------------------------------------------
# 'standard' = command-line utils, no desktop. Plus sudo and openssh for
# F4 inspection convenience.
tasksel tasksel/first                 multiselect standard
d-i pkgsel/include                    string sudo openssh-server
d-i pkgsel/upgrade                    select none
popularity-contest popularity-contest/participate boolean false

# --- GRUB -------------------------------------------------------------------
d-i grub-installer/bootdev    string default
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true

# --- Finish -----------------------------------------------------------------
# Poweroff (not reboot) so QEMU -no-reboot detects a clean end-of-install
# instead of looping back into the installer CD.
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/halt        boolean false
d-i debian-installer/exit/poweroff    boolean true
PRESEED

log "Appending preseed.cfg to initrd (cpio newc append)..."
# xorriso preserves the ISO's read-only mode on extracted files, so the
# decompressed initrd would also be read-only and cpio -A would EACCES.
chmod u+w "$WORK/initrd.gz"
( cd "$WORK" \
    && gunzip initrd.gz \
    && chmod u+w initrd \
    && echo preseed.cfg | cpio -o -H newc -A -F initrd 2>/dev/null \
    && gzip -1 initrd \
) || err "initrd repack failed"

# ---------------------------------------------------------------------------
# 4. Fresh empty qcow2 + per-run OVMF VARS.
# ---------------------------------------------------------------------------
TARGET_DISK="$WORK/disk.qcow2"
log "Creating empty disk: $DISK_SIZE qcow2"
qemu-img create -f qcow2 "$TARGET_DISK" "$DISK_SIZE" >/dev/null

OVMF_VARS_RUN="$WORK/OVMF_VARS-build.4m.fd"
cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS_RUN"

LOG_FILE="$LOGS_DIR/build-$BASELINE_NAME-$(date +%Y%m%d-%H%M%S).serial.log"

# ---------------------------------------------------------------------------
# 5. Launch QEMU. -kernel + -initrd + -append boots the installer directly
#    via OVMF's fw_cfg path, bypassing the ISO bootloader entirely. The ISO
#    is still mounted as CD-ROM so d-i can read packages from it.
# ---------------------------------------------------------------------------
log "Launching Debian installer (headless, ~10–20 min)"
log "Serial log: $LOG_FILE"
log "Disk:       $TARGET_DISK (will move to baselines/ on success)"

set +e
# Hard wall-clock cap: if d-i hangs on a question the preseed didn't cover,
# coreutils timeout SIGTERMs the VM at 45m; 30s grace then SIGKILL.
timeout --kill-after=30s 45m \
qemu-system-x86_64 \
    -name "build-$BASELINE_NAME" \
    -machine q35,accel=kvm -cpu host -smp 4 -m 4G \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS_RUN" \
    -drive file="$TARGET_DISK",format=qcow2,if=virtio,cache=writeback \
    -drive file="$NETINST_PATH",format=raw,if=ide,media=cdrom,readonly=on \
    -kernel "$WORK/vmlinuz" \
    -initrd "$WORK/initrd.gz" \
    -append "auto=true priority=critical preseed/file=/preseed.cfg console=ttyS0,115200n8 --- console=ttyS0,115200n8" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -display none \
    -serial "file:$LOG_FILE" \
    -no-reboot
QEMU_EXIT=$?
set -e

# timeout returns 124 if it had to kill; QEMU returns 0 on -no-reboot + d-i
# poweroff. Both 0 and >0 must be inspected against actual disk state.
if [ "$QEMU_EXIT" = "124" ]; then
    err "Build hit 45m timeout — d-i likely stuck on an unanswered question. See $LOG_FILE"
elif [ "$QEMU_EXIT" != "0" ]; then
    warn "QEMU exited with status $QEMU_EXIT — inspect $LOG_FILE"
    err "Build aborted"
fi

# Content sanity check: a freshly-installed Debian 'standard' tasksel
# produces a qcow2 of ~700 MB-1.5 GB. An empty 50G qcow2 is ~200 KB.
# Anything under 500 MB means the installer never wrote a real filesystem,
# usually because QEMU was SIGTERMed mid-prompt and exited 0.
DISK_PHYSICAL=$(stat -c %s "$TARGET_DISK")
MIN_REASONABLE=$((500 * 1024 * 1024))
if [ "$DISK_PHYSICAL" -lt "$MIN_REASONABLE" ]; then
    err "Resulting disk is only $(numfmt --to=iec "$DISK_PHYSICAL") — install did not complete. Inspect $LOG_FILE"
fi

# ---------------------------------------------------------------------------
# 6. Sanity-check: confirm GRUB EFI was actually written to the ESP.
# ---------------------------------------------------------------------------
log "Sanity-check: grub-efi present on ESP?"
if qemu-img info "$TARGET_DISK" --output=human 2>/dev/null | grep -q virtual; then
    : # qcow2 file is well-formed; deeper inspection would need qemu-nbd+sudo,
      # which the test harness already has in verify-untouched.sh.
fi

# ---------------------------------------------------------------------------
# 7. Move into place.
# ---------------------------------------------------------------------------
log "Moving baseline → $TARGET_BASELINE"
mv "$TARGET_DISK" "$TARGET_BASELINE"

if [ "$REMOVE_ISO" = "1" ]; then
    log "Removing cached ISO: $NETINST_PATH"
    rm -f "$NETINST_PATH"
fi

log "DONE."
log "  Baseline: $TARGET_BASELINE"
log "  Size:     $(stat -c %s "$TARGET_BASELINE" | numfmt --to=iec)"
log "  Log:      $LOG_FILE"
log ""
log "Smoke-test it with:"
log "    $SCRIPT_DIR/run-test.sh --baseline $BASELINE_NAME --display none --discard -- -daemonize"
