#!/usr/bin/env bash
# AmiCachy — Boot the system installed by Calamares onto the boot-iso scratch
# disk, WITHOUT the ISO attached, so UEFI/systemd-boot loads the installed
# system (not the live installer). Verifies the F3 end state: systemd-boot menu
# (Classic 68k + Asset Manager) -> Amiberry.
#
# Uses the same scratch disk + UEFI NVRAM that `dev_vm.sh boot-iso` created, so
# run this right after an install completes.
#
# Usage: ./tools/boot_installed.sh [DISK.qcow2]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

DISK="${1:-dev/test-iso-scratch.qcow2}"
VARS="dev/OVMF_VARS-test-iso.fd"
[[ -f "$DISK" ]] || { echo "ERROR: installed disk not found: $DISK" >&2; exit 1; }
[[ -f "$VARS" ]] || { echo "ERROR: UEFI vars not found: $VARS (run dev_vm.sh boot-iso first)" >&2; exit 1; }

OVMF_CODE=""
for f in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE_4M.fd \
         /usr/share/edk2/x64/OVMF_CODE.fd; do
    [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
done
[[ -n "$OVMF_CODE" ]] || { echo "ERROR: OVMF firmware not found." >&2; exit 1; }

DISPLAY_ARGS=(-device virtio-vga-gl -display gtk,gl=on,grab-on-hover=on)
[[ "${DISPLAY_MODE:-auto}" == "safe" ]] && DISPLAY_ARGS=(-device virtio-vga -display gtk,grab-on-hover=on)

echo ":: Booting the INSTALLED system (no ISO) from $DISK"
echo "   Expect: systemd-boot menu (Classic 68k + Asset Manager) -> Amiberry"

exec qemu-system-x86_64 \
    -enable-kvm -machine q35 -cpu host -m "${RAM:-4096}" -smp "${CPUS:-2}" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file="$DISK",format=qcow2,if=none,id=hd0 \
    -device virtio-blk-pci,drive=hd0 \
    "${DISPLAY_ARGS[@]}" \
    -device intel-hda -device hda-duplex
