#!/usr/bin/env bash
# Standalone Wi-Fi diagnostics script for AmiCachy.
# Can be run directly from the boot USB without rebuilding/rebooting.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
OUT="${1:-${SCRIPT_DIR}/wifi-debug.txt}"

run_section() {
    local title="$1"
    shift

    {
        echo
        echo "=== ${title} ==="
        "$@"
    } >> "$OUT" 2>&1
}

: > "$OUT"

{
    echo "AmiCachy Wi-Fi Debug"
    echo "Generated: $(date -Is 2>/dev/null || date)"
    echo "Script path: ${BASH_SOURCE[0]}"
    echo
} >> "$OUT"

run_section "kernel" uname -a
run_section "cmdline" cat /proc/cmdline
run_section "all pci devices" bash -lc "lspci -nnk || true"
run_section "network-ish pci devices" bash -lc "lspci -nnk | grep -A8 -Ei 'network|wireless|wifi|broadcom|airport|communication|ethernet' || true"
run_section "usb devices" bash -lc "lsusb 2>/dev/null || true"
run_section "ip link" ip link
run_section "rfkill" bash -lc "rfkill list 2>/dev/null || true"
run_section "nmcli device" bash -lc "nmcli device 2>/dev/null || true"
run_section "nmcli radio" bash -lc "nmcli radio 2>/dev/null || true"
run_section "NetworkManager status" bash -lc "systemctl status NetworkManager --no-pager 2>/dev/null || true"
run_section "iwd status" bash -lc "systemctl status iwd --no-pager 2>/dev/null || true"
run_section "loaded wifi modules" bash -lc "lsmod | grep -Ei 'brcm|b43|bcma|wl|ssb|cfg80211|mac80211|ath|iwl|airport|broadcom' || true"
run_section "firmware packages" bash -lc "pacman -Qs 'broadcom|linux-firmware|networkmanager|iwd|wireless|wpa|pciutils|usbutils' 2>/dev/null || true"
run_section "broadcom firmware files" bash -lc "find /usr/lib/firmware -maxdepth 4 -type f \\( -iname '*brcm*' -o -iname '*b43*' -o -iname '*broadcom*' \\) 2>/dev/null | sort | head -300"
run_section "dmesg wifi/network" bash -lc "dmesg | grep -Ei 'brcm|b43|bcma|wl|ssb|firmware|wifi|wlan|wireless|airport|cfg80211|rfkill|network|broadcom|80211' || true"

chmod 0644 "$OUT" 2>/dev/null || true

echo "Wi-Fi debug written to: $OUT"
echo "Send me that file contents."
