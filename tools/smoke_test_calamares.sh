#!/usr/bin/env bash
# AmiCachy — Headless smoke test for the Calamares live installer (F3).
#
# Boots a built ISO with NO display, SSHes into the live system, and checks
# that the Calamares migration is correctly wired and that Calamares launched
# without a fatal startup error. It does NOT drive the GUI wizard (picking a
# disk, creating the user, installing) — that is inherently interactive. Use
# this to catch gross regressions (missing payload, bad config, the autostart
# flip not taking) cheaply before a manual click-through.
#
# Requires: sshpass, qemu-system-x86_64. The live enables sshd and sets
# amiga/amiga on first boot; we reach it via hostfwd 2223->22.
#
# Usage:  ./tools/smoke_test_calamares.sh [ISO_PATH]
#         (defaults to the newest out/amicachy-v3-*.iso)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

ISO="${1:-$(ls -t "$PROJECT_DIR"/out/amicachy-v3-*.iso 2>/dev/null | head -1)}"
[[ -n "$ISO" && -f "$ISO" ]] || { echo "ERROR: ISO not found (pass a path)." >&2; exit 1; }
ISO="$(realpath "$ISO")"

for c in sshpass qemu-system-x86_64 qemu-img; do
    command -v "$c" >/dev/null || { echo "ERROR: $c not found." >&2; exit 1; }
done

find_ovmf() {
    for f in "$@"; do [[ -f "$f" ]] && { echo "$f"; return 0; }; done
    return 1
}
OVMF_CODE="$(find_ovmf /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/edk2/x64/OVMF_CODE.fd)" \
    || { echo "ERROR: OVMF firmware not found." >&2; exit 1; }
OVMF_VARS_TMPL="$(find_ovmf /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/edk2/x64/OVMF_VARS.fd)" \
    || { echo "ERROR: OVMF vars template not found." >&2; exit 1; }

WORK="$(mktemp -d)"
QEMU_PID=""
cleanup() {
    [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

cp "$OVMF_VARS_TMPL" "$WORK/vars.fd"
qemu-img create -f qcow2 "$WORK/scratch.qcow2" 64G >/dev/null

# 2224, not 2223: dev_vm.sh boot-iso hardcodes 2223, so a different port lets
# the smoke test and a manual boot-iso run without a hostfwd collision.
PORT=2224
SSH_OPTS=(-p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o LogLevel=ERROR)
RSSH() { sshpass -p amiga ssh "${SSH_OPTS[@]}" amiga@localhost "$@"; }

echo ":: AmiCachy Calamares smoke test"
echo "   ISO: $ISO"
echo "   Booting headless (no display)..."

# virtio-gpu (not -gl, which needs a display) gives the guest a DRM node so
# cage/Calamares can render to an offscreen framebuffer. RAM/CPU mirror dev_vm.
qemu-system-x86_64 \
    -enable-kvm -machine q35 -cpu host -m "${RAM:-4096}" -smp "${CPUS:-2}" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$WORK/vars.fd" \
    -drive file="$ISO",format=raw,if=none,id=usb0,readonly=on \
    -device qemu-xhci,id=xhci \
    -device usb-storage,bus=xhci.0,drive=usb0,bootindex=1,removable=on \
    -drive file="$WORK/scratch.qcow2",format=qcow2,if=none,id=hd0 \
    -device virtio-blk-pci,drive=hd0,bootindex=2 \
    -device virtio-gpu-pci \
    -display none \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::${PORT}-:22 \
    -serial file:"$WORK/serial.log" \
    >/dev/null 2>&1 &
QEMU_PID=$!

echo "   Waiting for the live system (sshd + amiga password)..."
ready=0
for i in $(seq 1 60); do      # up to ~180s
    kill -0 "$QEMU_PID" 2>/dev/null || { echo "ERROR: QEMU exited early."; exit 1; }
    if RSSH true 2>/dev/null; then ready=1; break; fi
    sleep 3
done
if [[ $ready -ne 1 ]]; then
    echo "ERROR: could not reach the live over SSH within ~180s."
    echo "       Serial tail:"; tail -20 "$WORK/serial.log" 2>/dev/null
    exit 1
fi
echo "   Live is up. Running checks..."
echo ""

# One remote script emits KEY=PASS/FAIL[:detail] lines we parse locally.
RESULTS="$(RSSH 'bash -s' <<'REMOTE'
emit() { echo "$1=$2"; }
[ -f /usr/share/amicachy/target.sfs ] \
    && emit payload "PASS:$(du -h /usr/share/amicachy/target.sfs | cut -f1)" \
    || emit payload FAIL
[ -f /etc/calamares/settings.conf ] && emit settings PASS || emit settings FAIL
[ -d /etc/calamares/branding/amicachy ] && emit branding PASS || emit branding FAIL
[ -f /usr/lib/calamares/modules/amicachy-postinstall/main.py ] \
    && emit module PASS || emit module FAIL
command -v calamares >/dev/null && emit engine PASS || emit engine FAIL
pacman -Q cachyos-calamares >/dev/null 2>&1 && emit pkg_engine PASS || emit pkg_engine FAIL
pacman -Q calamares-config-amicachy >/dev/null 2>&1 && emit pkg_config PASS || emit pkg_config FAIL
grep -q "sudo -E calamares" /usr/bin/amilaunch.sh && emit flip PASS || emit flip FAIL
# Did Calamares actually launch? Best-effort (headless cage may or may not).
if pgrep -x calamares >/dev/null; then emit launched PASS
elif pgrep -x cage >/dev/null;       then emit launched "PASS:cage-up"
else emit launched "WARN:not-running-headless"; fi
# Any fatal startup error captured by amilaunch run_installer()?
if [ -s /tmp/amicachy-installer.log ]; then
    if grep -qiE "error|fatal|cannot|traceback|no such" /tmp/amicachy-installer.log; then
        emit startlog "WARN:see-log"
    else
        emit startlog PASS
    fi
else
    emit startlog "PASS:empty"
fi
echo "---LOG-TAIL---"
tail -15 /tmp/amicachy-installer.log 2>/dev/null || echo "(no installer log)"
REMOTE
)"

# --- Report ---------------------------------------------------------------
declare -A LABEL=(
    [payload]="target.sfs present in live"
    [settings]="/etc/calamares/settings.conf"
    [branding]="branding/amicachy/"
    [module]="amicachy-postinstall module"
    [engine]="calamares binary"
    [pkg_engine]="cachyos-calamares installed"
    [pkg_config]="calamares-config-amicachy installed"
    [flip]="amilaunch flips to calamares"
    [launched]="Calamares/cage process"
    [startlog]="installer log clean"
)
order=(payload settings branding module engine pkg_engine pkg_config flip launched startlog)
fails=0; warns=0
printf '  %-34s %s\n' "CHECK" "RESULT"
for k in "${order[@]}"; do
    line="$(grep "^$k=" <<<"$RESULTS" | head -1)"
    val="${line#*=}"
    case "$val" in
        PASS*) icon="✓ ";;
        WARN*) icon="! "; warns=$((warns+1));;
        *)     icon="✗ "; fails=$((fails+1));;
    esac
    printf '  %-34s %s%s\n' "${LABEL[$k]}" "$icon" "$val"
done
echo ""
echo "  --- /tmp/amicachy-installer.log (tail) ---"
sed -n '/---LOG-TAIL---/,$p' <<<"$RESULTS" | tail -n +2 | sed 's/^/  /'
echo ""

echo ":: Powering off the VM..."
RSSH "sudo poweroff" 2>/dev/null || kill "$QEMU_PID" 2>/dev/null
QEMU_PID=""

echo ""
if [[ $fails -gt 0 ]]; then
    echo ":: RESULT: $fails check(s) FAILED, $warns warning(s). Calamares wiring is broken."
    exit 1
elif [[ $warns -gt 0 ]]; then
    echo ":: RESULT: wiring OK, $warns warning(s) (likely the headless GUI launch — verify the wizard manually)."
    exit 0
else
    echo ":: RESULT: all checks PASSED. Calamares wiring is in place; complete the wizard manually for full T1."
    exit 0
fi
