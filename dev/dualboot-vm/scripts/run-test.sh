#!/usr/bin/env bash
# Launch a QEMU/KVM VM to test the AmiCachy installer against a baseline disk
# image (empty, Debian, Windows...) with a side-loaded AmiCachy ISO.
#
# Default behaviour:
#   - Creates an overlay qcow2 backed by the baseline (baseline never modified).
#   - The overlay is kept after exit (timestamped) so you can inspect what the
#     installer did to the disk. Use --discard to remove it on exit.
#   - Logs serial console + QEMU monitor to logs/ for post-mortem analysis.
#
# Examples:
#   # Test on empty disk:
#   ./run-test.sh --baseline empty-50g --iso ../../../out/amicachy-*.iso
#
#   # Test dual-boot against Debian:
#   ./run-test.sh --baseline debian12-ext4 --iso ../../../out/amicachy-*.iso
#
#   # Discard overlay after run (CI-friendly):
#   ./run-test.sh --baseline empty-50g --iso ... --discard
#
#   # DESTRUCTIVE: write directly to the baseline (used by build-baseline-* scripts):
#   ./run-test.sh --baseline empty-50g --no-overlay --boot order=d

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths (resolved relative to this script's location, regardless of cwd)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUALBOOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINES_DIR="$DUALBOOT_DIR/baselines"
OVERLAYS_DIR="$DUALBOOT_DIR/overlays"
LOGS_DIR="$DUALBOOT_DIR/logs"
OVMF_DIR="$DUALBOOT_DIR/ovmf"

OVMF_CODE="$OVMF_DIR/OVMF_CODE.4m.fd"
OVMF_VARS_TEMPLATE="$OVMF_DIR/OVMF_VARS-template.4m.fd"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
BASELINE=""
ISO=""
MEMORY="4G"
CPUS="4"
DISCARD=0
NO_OVERLAY=0
USE_OVERLAY=""            # boot this existing overlay instead of creating one
REUSE_OVERLAY=0
BOOT_ORDER="dc,menu=on"   # CD first (so install media boots), then disk
BOOT_SET=0                # 1 if --boot was given explicitly
DISPLAY_MODE="gtk"
MONITOR_STDIO=0
EXTRA_QEMU_ARGS=()

usage() {
    cat <<EOF
Usage: $0 --baseline NAME [--iso PATH] [OPTIONS]

Required:
  --baseline NAME      Name (without .qcow2) of a baseline in baselines/

Options:
  --iso PATH           AmiCachy ISO to boot as install CD. If omitted, no CD is
                       attached and the VM boots straight off the disk (handy to
                       check a baseline boots on its own before a dual-boot test).
  --memory SIZE        VM RAM (default: 4G)
  --cpus N             vCPUs (default: 4)
  --discard            Delete overlay on exit (default: keep with timestamp)
  --no-overlay         DESTRUCTIVE: write directly to the baseline qcow2
                       (used by baseline-build scripts; never for tests)
  --overlay PATH       Boot an EXISTING overlay (e.g. the disk from a prior
                       install) instead of creating a fresh one. Reuses that
                       run's OVMF VARS so the installed boot manager is found.
                       --baseline not needed with this.
  --boot ORDER         QEMU -boot order (default: dc,menu=on)
  --display MODE       QEMU -display mode: gtk, sdl, none (default: gtk)
  --monitor            Attach QEMU monitor to stdio (default: unix socket in logs/)
  --                   Pass remaining args verbatim to QEMU

Examples:
  $0 --baseline empty-50g --iso ../../../out/amicachy-2026.05.23.iso
  $0 --baseline debian12-ext4 --iso ../../../out/amicachy-2026.05.23.iso --discard
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline)    BASELINE="$2"; shift 2 ;;
        --iso)         ISO="$2"; shift 2 ;;
        --memory)      MEMORY="$2"; shift 2 ;;
        --cpus)        CPUS="$2"; shift 2 ;;
        --discard)     DISCARD=1; shift ;;
        --no-overlay)  NO_OVERLAY=1; shift ;;
        --overlay)     USE_OVERLAY="$2"; shift 2 ;;
        --boot)        BOOT_ORDER="$2"; BOOT_SET=1; shift 2 ;;
        --display)     DISPLAY_MODE="$2"; shift 2 ;;
        --monitor)     MONITOR_STDIO=1; shift ;;
        --)            shift; EXTRA_QEMU_ARGS=("$@"); break ;;
        -h|--help)     usage ;;
        *)             echo "Unknown option: $1" >&2; usage ;;
    esac
done

# --baseline is required to create an overlay; --overlay supplies its own disk
# and makes --baseline unnecessary.
if [[ -z "$BASELINE" && -z "$USE_OVERLAY" ]]; then
    echo "ERROR: --baseline (or --overlay) required" >&2; usage
fi

# --iso is optional: without it, no install CD is attached and the VM boots
# straight off the disk (e.g. to verify a baseline boots on its own, or to boot
# the disk produced by a prior install via --overlay).
if [[ -z "$ISO" && $BOOT_SET -eq 0 ]]; then
    BOOT_ORDER="c"   # disk only — there is no CD to boot
fi

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
if [[ -z "$USE_OVERLAY" ]]; then
    BASELINE_PATH="$BASELINES_DIR/${BASELINE}.qcow2"
    [[ -f "$BASELINE_PATH" ]] || {
        echo "ERROR: Baseline not found: $BASELINE_PATH" >&2
        echo "Available baselines:" >&2
        ls -1 "$BASELINES_DIR"/*.qcow2 2>/dev/null | sed 's|.*/||;s|\.qcow2$||;s|^|  - |' >&2
        exit 2
    }
fi

if [[ -n "$ISO" ]]; then
    [[ -f "$ISO" ]] || { echo "ERROR: ISO not found: $ISO" >&2; exit 2; }
    ISO="$(cd "$(dirname "$ISO")" && pwd)/$(basename "$ISO")"
fi

[[ -e "$OVMF_CODE" ]] || { echo "ERROR: OVMF_CODE missing: $OVMF_CODE" >&2; exit 3; }
[[ -f "$OVMF_VARS_TEMPLATE" ]] || { echo "ERROR: OVMF_VARS template missing: $OVMF_VARS_TEMPLATE" >&2; exit 3; }
[[ -e /dev/kvm ]] || { echo "ERROR: /dev/kvm not accessible — install qemu-full and check group membership" >&2; exit 3; }

# ---------------------------------------------------------------------------
# Set up per-run artifacts
# ---------------------------------------------------------------------------
if [[ -n "$USE_OVERLAY" ]]; then
    # Boot an existing overlay (e.g. the disk from a prior install) as-is.
    [[ -f "$USE_OVERLAY" ]] || { echo "ERROR: overlay not found: $USE_OVERLAY" >&2; exit 2; }
    DISK_PATH="$(cd "$(dirname "$USE_OVERLAY")" && pwd)/$(basename "$USE_OVERLAY")"
    RUN_ID="$(basename "$USE_OVERLAY" .qcow2)"
    REUSE_OVERLAY=1
    echo ">>> Booting existing overlay: $DISK_PATH"
else
    TS="$(date +%Y%m%d-%H%M%S)"
    RUN_ID="${BASELINE}-${TS}"
    if [[ $NO_OVERLAY -eq 1 ]]; then
        echo ">>> WARNING: --no-overlay set, baseline $BASELINE_PATH will be modified!"
        sleep 2
        DISK_PATH="$BASELINE_PATH"
    else
        DISK_PATH="$OVERLAYS_DIR/${RUN_ID}.qcow2"
        echo ">>> Creating overlay: $DISK_PATH (backed by $BASELINE)"
        qemu-img create -q -f qcow2 -b "$BASELINE_PATH" -F qcow2 "$DISK_PATH"
    fi
fi

# Per-run OVMF VARS (NVRAM). For --overlay we reuse the VARS written during that
# run's install (it holds the boot entries efibootmgr added, e.g. AmiCachy's
# systemd-boot); a fresh template would make the firmware fall back to the
# removable path and likely boot the other OS instead.
VARS_PATH="$OVMF_DIR/OVMF_VARS-run-${RUN_ID}.4m.fd"
if [[ $REUSE_OVERLAY -eq 1 && -f "$VARS_PATH" ]]; then
    echo ">>> Reusing matching OVMF VARS (NVRAM): $VARS_PATH"
elif [[ $REUSE_OVERLAY -eq 1 ]]; then
    echo ">>> WARNING: no matching VARS ($VARS_PATH) for this overlay — using a fresh"
    echo "    template. The firmware may boot the removable fallback (the other OS)"
    echo "    instead of the installed boot manager."
    cp "$OVMF_VARS_TEMPLATE" "$VARS_PATH"
else
    cp "$OVMF_VARS_TEMPLATE" "$VARS_PATH"
fi

SERIAL_LOG="$LOGS_DIR/${RUN_ID}.serial.log"
MONITOR_SOCK="$LOGS_DIR/${RUN_ID}.monitor.sock"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    rm -f "$MONITOR_SOCK"
    if [[ $DISCARD -eq 1 && $NO_OVERLAY -eq 0 && $REUSE_OVERLAY -eq 0 ]]; then
        echo ">>> Discarding overlay $DISK_PATH"
        rm -f "$DISK_PATH" "$VARS_PATH"
    else
        echo ">>> Overlay kept: $DISK_PATH"
        echo ">>> OVMF VARS kept: $VARS_PATH"
        echo ">>> Serial log:    $SERIAL_LOG"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Build QEMU command
# ---------------------------------------------------------------------------
QEMU_ARGS=(
    -name "AmiCachy dualboot test: ${RUN_ID}"
    -machine q35,accel=kvm
    -cpu host
    -smp "$CPUS"
    -m "$MEMORY"

    # UEFI firmware: read-only CODE + per-run mutable VARS
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
    -drive "if=pflash,format=raw,file=${VARS_PATH}"

    # Main disk: baseline overlay (or baseline itself if --no-overlay)
    -drive "file=${DISK_PATH},format=qcow2,if=virtio,cache=writeback"

    # Boot order: CD first (install), then disk (post-install reboot). With no
    # ISO this was forced to "c" above (disk only).
    -boot "$BOOT_ORDER"

    # User-mode networking (no privileges needed). Forward host:2222 → guest:22.
    -netdev user,id=net0,hostfwd=tcp::2222-:22
    -device virtio-net-pci,netdev=net0

    # Display + audio
    -display "$DISPLAY_MODE"
    -device intel-hda
    -device hda-duplex
    -vga virtio

    # Logging: serial console (great for catching kernel panics)
    -serial "file:${SERIAL_LOG}"
)

# Attach the install ISO as a bootable CD only when one was given.
if [[ -n "$ISO" ]]; then
    QEMU_ARGS+=(-drive "file=${ISO},format=raw,if=ide,media=cdrom,readonly=on")
fi

if [[ $MONITOR_STDIO -eq 1 ]]; then
    QEMU_ARGS+=(-monitor stdio)
else
    QEMU_ARGS+=(-monitor "unix:${MONITOR_SOCK},server,nowait")
fi

QEMU_ARGS+=("${EXTRA_QEMU_ARGS[@]}")

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
echo ">>> Run ID:     $RUN_ID"
echo ">>> Disk:       $DISK_PATH"
echo ">>> ISO:        ${ISO:-<none> (booting disk only)}"
echo ">>> Monitor:    ${MONITOR_SOCK} (use 'socat - UNIX-CONNECT:${MONITOR_SOCK}')"
echo ">>> Memory:     $MEMORY    CPUs: $CPUS"
echo ">>> Launching QEMU..."
echo ""

exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
