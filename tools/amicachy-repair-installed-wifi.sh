#!/usr/bin/env bash
# Repair Wi-Fi support in an already installed AmiCachy system.
# Run from the live/dev USB.

set -euo pipefail

ROOT_PART="${1:-}"
MOUNTPOINT="/mnt/amicachy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

log() {
    printf ':: %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ "$ROOT_PART" == "--current" || "$ROOT_PART" == "--installed" || "$ROOT_PART" == "/" ]]; then
    MOUNTPOINT="/"
    ROOT_PART="current root"
fi

if [[ "$MOUNTPOINT" != "/" && -z "$ROOT_PART" ]]; then
    ROOT_PART="$(blkid -L AMICACHY 2>/dev/null || true)"
fi

if [[ "$MOUNTPOINT" != "/" ]]; then
    [[ -n "$ROOT_PART" && -b "$ROOT_PART" ]] || die "Root partition not found. Try: sudo bash $0 /dev/sda3"
fi

log "Root partition: $ROOT_PART"

if [[ "$MOUNTPOINT" != "/" ]]; then
    mkdir -p "$MOUNTPOINT"
    umount -R "$MOUNTPOINT" 2>/dev/null || true
    mount "$ROOT_PART" "$MOUNTPOINT"
fi

cleanup() {
    sync
    if [[ "$MOUNTPOINT" != "/" ]]; then
        umount -R "$MOUNTPOINT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

regdb=""
for candidate in \
    "$SCRIPT_DIR/regulatory.db" \
    "$SCRIPT_DIR/wifi-repair/regulatory.db" \
    "/usr/lib/firmware/regulatory.db"; do
    if [[ -f "$candidate" ]]; then
        regdb="$candidate"
        break
    fi
done

[[ -n "$regdb" ]] || die "regulatory.db not found. Put regulatory.db in the same directory as this script."

log "Copying regulatory database from $regdb..."
install -D -m 0644 "$regdb" \
    "$MOUNTPOINT/usr/lib/firmware/regulatory.db"

for sig in \
    "${regdb}.p7s" \
    "$SCRIPT_DIR/regulatory.db.p7s" \
    "$SCRIPT_DIR/wifi-repair/regulatory.db.p7s" \
    "/usr/lib/firmware/regulatory.db.p7s"; do
    if [[ -f "$sig" ]]; then
        log "Copying regulatory signature from $sig..."
        install -D -m 0644 "$sig" \
        "$MOUNTPOINT/usr/lib/firmware/regulatory.db.p7s"
        break
    fi
done

iw_src=""
for candidate in \
    "$SCRIPT_DIR/iw" \
    "$SCRIPT_DIR/wifi-repair/iw" \
    "/usr/bin/iw"; do
    if [[ -f "$candidate" ]]; then
        iw_src="$candidate"
        break
    fi
done

if [[ -n "$iw_src" ]]; then
    log "Copying iw tool from $iw_src..."
    install -D -m 0755 "$iw_src" "$MOUNTPOINT/usr/bin/iw"
fi

log "Ensuring NetworkManager is enabled..."
if [[ "$MOUNTPOINT" == "/" ]]; then
    systemctl enable --now NetworkManager >/dev/null 2>&1 || true
else
    arch-chroot "$MOUNTPOINT" systemctl enable NetworkManager >/dev/null 2>&1 || true
fi

log "Ensuring Broadcom wl helper state..."
mkdir -p "$MOUNTPOINT/etc/modprobe.d"
cat > "$MOUNTPOINT/etc/modprobe.d/amicachy-broadcom-wl.conf" <<'EOF'
# BCM4360 on MacBook Air works with broadcom-wl.
# Keep legacy open drivers from racing wl during boot.
blacklist b43
blacklist b43legacy
blacklist ssb
blacklist brcmsmac
blacklist brcmfmac
EOF

log "Writing repair report..."
REPORT_PATH="$MOUNTPOINT/root/amicachy-wifi-repair.txt"
USB_REPORT_PATH="$SCRIPT_DIR/amicachy-wifi-repair-report.txt"

cat > "$REPORT_PATH" <<EOF
AmiCachy Wi-Fi repair completed.

Root partition: $ROOT_PART
Installed:
- /usr/lib/firmware/regulatory.db
- /usr/lib/firmware/regulatory.db.p7s if available
- /usr/bin/iw if available
- NetworkManager enabled
- Broadcom wl blacklist helper

Reboot into the installed AmiCachy and try:
  nmcli dev wifi rescan
  nmcli dev wifi list
EOF

if [[ -w "$SCRIPT_DIR" ]]; then
    cp "$REPORT_PATH" "$USB_REPORT_PATH" 2>/dev/null || true
    log "USB report: $USB_REPORT_PATH"
fi

log "Done. Reboot into the installed AmiCachy."
