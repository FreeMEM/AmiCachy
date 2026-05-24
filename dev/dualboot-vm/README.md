# Dual-boot VM test bench

QEMU/KVM harness for testing the AmiCachy installer against pre-existing OS
installations (Debian, Windows, etc.) without risking real hardware.

This is the safety net for the Calamares migration (`docs/calamares-migration-inventory.md`,
phase F2 of the migration plan): every dual-boot scenario gets a reproducible
baseline disk image, a non-destructive overlay for each test run, and a
verification step that proves the installer didn't touch the pre-existing OS.

## Layout

```
dev/dualboot-vm/
├── scripts/
│   ├── run-test.sh             # Launch a VM with a baseline + AmiCachy ISO
│   ├── snapshot-reset.sh       # Clean up overlays / per-run OVMF VARS / logs
│   ├── verify-untouched.sh     # Compare baseline vs overlay partition hashes
│   ├── build-baseline-debian.sh   # (F2.b — pending)
│   └── build-baseline-windows.sh  # (F2.c — pending)
├── ovmf/
│   ├── OVMF_CODE.4m.fd            # symlink → /usr/share/edk2/x64/...
│   └── OVMF_VARS-template.4m.fd   # template (copied per run)
├── baselines/                  # immutable qcow2 (gitignored, large)
├── overlays/                   # per-run qcow2 backed by a baseline (gitignored)
└── logs/                       # serial + monitor logs per run (gitignored)
```

## Prerequisites

System packages (CachyOS / Arch):
```
sudo pacman -S qemu-full edk2-ovmf parted util-linux coreutils
```

KVM access: `/dev/kvm` must be readable (`crw-rw-rw-` works; group `kvm` also fine).

## Quick start

### 1. Build (or copy) a baseline

Baselines are large qcow2 files with a pre-installed OS, **never modified by
test runs**. Build them once with the `build-baseline-*.sh` scripts (F2.b, F2.c)
or copy them in manually:

```bash
# Empty 50 GB disk (no OS installed, for "fresh install" tests)
qemu-img create -f qcow2 baselines/empty-50g.qcow2 50G
```

### 2. Run a test

```bash
cd dev/dualboot-vm
./scripts/run-test.sh \
    --baseline empty-50g \
    --iso ../../out/amicachy-2026.05.23.iso
```

This:
1. Creates a timestamped overlay qcow2 backed by the baseline (`overlays/empty-50g-<ts>.qcow2`).
2. Copies the OVMF VARS template (so each VM has fresh UEFI NVRAM).
3. Boots QEMU with KVM acceleration, virtio disk, virtio network, intel-hda audio.
4. Streams the serial console to `logs/<run-id>.serial.log`.
5. On exit, **keeps the overlay** so you can inspect what the installer did
   (use `--discard` to remove it instead).

### 3. Verify the pre-existing OS is intact

After running a dual-boot test (e.g. against `debian12-ext4`):

```bash
sudo ./scripts/verify-untouched.sh \
    --baseline debian12-ext4 \
    --overlay overlays/debian12-ext4-20260524-103045.qcow2
```

Mounts both qcow2 read-only via `qemu-nbd`, hashes every partition, and prints
a comparison table. A `CHANGED` row on a pre-existing OS partition means
**the installer modified data that belongs to the other OS** — bug to fix.

### 4. Clean up

```bash
# Interactive
./scripts/snapshot-reset.sh

# CI: delete artifacts older than 7 days, no prompt
./scripts/snapshot-reset.sh --yes --older-than 7
```

## Test matrix (from migration plan F7)

| ID  | Baseline             | Scenario                                  | Expected                              |
|-----|----------------------|-------------------------------------------|---------------------------------------|
| T1  | `empty-50g`          | "Erase entire disk" mode                  | AmiCachy installs; only OS            |
| T2  | `debian12-ext4`      | "Install alongside" using free space      | Both OSes boot; systemd-boot has Debian entry |
| T3  | `win11-ntfs`         | "Install alongside" using free space      | Both OSes boot; systemd-boot has Windows entry |
| T4  | `debian12-ext4`      | "Replace partition" over Debian's /home   | Debian still boots; AmiCachy uses ex-/home |
| T5  | `win11-ntfs` + empty | Multi-disk: AmiCachy on second drive      | Both boot from unified menu           |
| T6  | `debian12-luks-lvm`  | "Install alongside" with LUKS+LVM existing| Debian intact; AmiCachy in free space |

T1–T3 are required for F4 (dual-boot real). T4–T6 are insurance for F7.

## Boot order semantics

By default `run-test.sh` uses `--boot dc,menu=on`:
- **CD first**: the AmiCachy ISO boots so you can run the installer
- **Disk second**: after install + reboot, the VM falls through to the
  freshly installed AmiCachy on disk (assuming systemd-boot was set up
  correctly)

Press F12 at QEMU start to choose manually (e.g. force boot from disk to
verify the post-install state without running the installer again).

## Networking

User-mode networking is enabled with `hostfwd=tcp::2222-:22`, so once the
guest has SSH up:

```bash
ssh -p 2222 amiga@localhost
```

No bridge configuration needed, no root privileges to launch the VM.

## Notes & limitations

- **OVMF VARS are per-run**: each test gets fresh UEFI NVRAM. If you want to
  test "second boot after install" without re-running the ISO, pass
  `--no-overlay` and inspect manually (advanced, destructive to the baseline).
- **`verify-untouched.sh` needs sudo** because `qemu-nbd` needs to load the
  `nbd` kernel module and `/dev/nbdN` is root-owned. There's no clean
  rootless alternative for block-level inspection.
- **No Secure Boot in this phase**: the OVMF firmware is the non-SB variant.
  If we ever need to validate SB scenarios, add `OVMF_CODE.secboot.4m.fd`
  and sign the shim — out of scope for now (`docs/calamares-migration-inventory.md` F2.a).
- **Baseline integrity**: never run `--no-overlay` against a baseline you
  want to preserve. The script warns and sleeps 2 s before proceeding.
