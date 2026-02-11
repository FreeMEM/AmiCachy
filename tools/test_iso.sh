#!/usr/bin/env bash
# AmiCachy — Launch the ISO in a KVM/libvirt VM for testing.
# Uses virt-install with UEFI boot, SPICE display, and a scratch disk
# for testing the installer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_NAME="amicachy-test"
RAM=4096
CPUS=2
DISK_SIZE=40  # GiB — enough for EFI + root + data partitions

usage() {
    echo "Usage: $(basename "$0") [ISO_PATH]"
    echo ""
    echo "If ISO_PATH is omitted, uses the most recent .iso in out/."
    echo ""
    echo "The VM is created with:"
    echo "  - UEFI boot (OVMF)"
    echo "  - ${RAM} MiB RAM, ${CPUS} vCPUs"
    echo "  - ${DISK_SIZE} GiB virtio scratch disk"
    echo "  - SPICE display (opens virt-viewer)"
    echo ""
    echo "Options:"
    echo "  --destroy    Remove existing VM before creating a new one"
    echo "  -h, --help   Show this help"
    exit 0
}

find_iso() {
    local iso
    iso=$(ls -t "${PROJECT_DIR}/out/"*.iso 2>/dev/null | head -1)
    if [[ -z "$iso" ]]; then
        echo "ERROR: No ISO found in ${PROJECT_DIR}/out/" >&2
        echo "       Run build_iso.sh or build_iso_docker.sh first." >&2
        exit 1
    fi
    echo "$iso"
}

destroy_vm() {
    if virsh list --all --name 2>/dev/null | grep -q "^${VM_NAME}$"; then
        echo ":: Destroying existing VM '${VM_NAME}'..."
        virsh destroy "$VM_NAME" 2>/dev/null || true
        virsh undefine "$VM_NAME" --nvram --remove-all-storage 2>/dev/null || true
    fi
}

# --- Parse args ---
DESTROY=0
ISO_PATH=""
for arg in "$@"; do
    case "$arg" in
        --destroy) DESTROY=1 ;;
        -h|--help) usage ;;
        *)
            if [[ -f "$arg" ]]; then
                ISO_PATH="$arg"
            else
                echo "ERROR: File not found: $arg" >&2
                exit 1
            fi
            ;;
    esac
done

# --- Preflight checks ---
for cmd in virt-install virsh virt-viewer; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found. Install virt-manager." >&2
        exit 1
    fi
done

if ! virsh uri &>/dev/null; then
    echo "ERROR: Cannot connect to libvirtd. Is the service running?" >&2
    echo "       sudo systemctl start libvirtd" >&2
    exit 1
fi

if [[ -z "$ISO_PATH" ]]; then
    ISO_PATH=$(find_iso)
fi

echo ":: ISO: ${ISO_PATH}"
echo ":: VM:  ${VM_NAME} (${CPUS} vCPUs, ${RAM} MiB RAM, ${DISK_SIZE} GiB disk)"

# --- Destroy old VM if requested or if it already exists ---
if [[ $DESTROY -eq 1 ]]; then
    destroy_vm
elif virsh list --all --name 2>/dev/null | grep -q "^${VM_NAME}$"; then
    echo ""
    echo "WARNING: VM '${VM_NAME}' already exists."
    echo "         Use --destroy to recreate it, or connect with:"
    echo "         virt-viewer ${VM_NAME}"
    exit 1
fi

# --- Find OVMF firmware ---
OVMF_CODE=""
for candidate in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    if [[ -f "$candidate" ]]; then
        OVMF_CODE="$candidate"
        break
    fi
done
if [[ -z "$OVMF_CODE" ]]; then
    echo "ERROR: OVMF firmware not found. Install ovmf package." >&2
    exit 1
fi

# --- Create and boot VM ---
echo ":: Creating VM with UEFI boot..."
echo ""

virt-install \
    --name "$VM_NAME" \
    --memory "$RAM" \
    --vcpus "$CPUS" \
    --machine q35 \
    --boot uefi,loader="$OVMF_CODE",loader.readonly=yes,loader.type=pflash \
    --cdrom "$ISO_PATH" \
    --disk size="$DISK_SIZE",bus=virtio,format=qcow2 \
    --os-variant archlinux \
    --network network=default,model=virtio \
    --graphics spice,listen=none \
    --video virtio \
    --channel spicevmc \
    --noautoconsole

echo ""
echo ":: VM created. Opening display..."
virt-viewer --connect qemu:///system --attach "$VM_NAME" &

echo ""
echo ":: VM is running. Useful commands:"
echo "   virt-viewer --connect qemu:///system --attach ${VM_NAME}   # reconnect display"
echo "   virsh console ${VM_NAME}        # serial console"
echo "   virsh destroy ${VM_NAME}        # force stop"
echo "   virsh undefine ${VM_NAME} --nvram --remove-all-storage  # delete"
