# Live persistence on a pendrive

AmiCachy supports a "casual live" mode (everything runs from RAM, nothing
persists) **and** a "persistent pendrive" mode where everything the user
saves under `~/Amiberry/` survives reboots. The two coexist on the same
ISO; behaviour is selected at boot time by the presence (or absence) of a
specifically labelled partition.

## How it works

`amicachy-persistent-data.service` runs early during the live boot. It
looks for a partition with the filesystem label **`AMICACHY_DATA`**:

- **Not present** → service exits silently. Live runs entirely from RAM.
  Anything you save is lost on shutdown.
- **Present** → the partition is mounted at `/run/amicachy-data`, and
  its `Amiberry/` subdirectory is bind-mounted on top of
  `/home/amiga/Amiberry`. The system base, packages, etc. stay
  immutable; only what Amiberry writes (configs, hardfile changes, save
  states, screenshots, lha downloads) lives on the pendrive.

`amicachy-seed-assets.service` (which only runs when the ISO was built
with `--seed-assets`) detects whether `/home/amiga/Amiberry/{roms,harddrives}`
sits on a tmpfs/overlay (live without persistence) or on real writable
storage (persistent partition mounted). In the persistent case it
**copies** the bundled HDFs into the partition so Amiga OSes that need
RW access (Coffin, AmigaOS 3.x with PFS-III) work correctly. In the
non-persistent case it falls back to symlinks.

## Preparing a pendrive

1. **Flash the public ISO** with `dd` (replace `/dev/sdX` with your
   pendrive — **wrong device wipes your disk**):

   ```bash
   sudo dd if=out/amicachy-aros-2026.05.10-x86_64.iso \
           of=/dev/sdX bs=4M status=progress oflag=sync
   ```

2. **Add a second partition** for AMICACHY_DATA. The ISO image leaves
   the rest of the pendrive unallocated, so just create a new partition
   covering the free space (with `gparted`, `cfdisk`, or `sgdisk`):

   ```bash
   sudo sgdisk --new=0:0:0 --typecode=0:8300 --change-name=0:AMICACHY_DATA /dev/sdX
   sudo partprobe /dev/sdX
   ```

   This creates `/dev/sdXN` (typically `sdX3` after the ISO partitions).

3. **Format it ext4 with the right label**:

   ```bash
   sudo mkfs.ext4 -L AMICACHY_DATA -E root_owner=1000:1000 /dev/sdX3
   ```

4. **(Optional) Pre-populate with assets**:

   ```bash
   sudo mkdir -p /mnt/amicachy
   sudo mount /dev/sdX3 /mnt/amicachy
   sudo mkdir -p /mnt/amicachy/Amiberry/{conf,roms,harddrives}
   sudo cp ~/Amiberry/kickstarts/*.rom /mnt/amicachy/Amiberry/roms/
   sudo cp ~/Amiberry/harddrives/coffin_r65_32GB.img /mnt/amicachy/Amiberry/harddrives/
   sudo chown -R 1000:1000 /mnt/amicachy/Amiberry
   sudo umount /mnt/amicachy
   ```

   This gives the same effect as a `--seed-assets` ISO build, but the
   assets live on the user's pendrive (not the public ISO) and the public
   ISO stays minimal and distributable.

Boot from the pendrive: AmiCachy detects `AMICACHY_DATA`, bind-mounts it,
and you have a fully writable Amiberry environment. Configs saved with
F12 → Save survive reboots; Coffin OS can write to `coffin_r65_32GB.img`;
new HDFs/ROMs you drop into the partition appear automatically.

## Testing in a VM (without an actual pendrive)

`dev_vm.sh boot-iso` has `--persist` for exactly this:

```bash
./tools/dev_vm.sh boot-iso out/amicachy-aros-2026.05.10-x86_64.iso \
    --reset-scratch --persist --reset-persist --persist-size 32G
```

This creates `dev/test-iso-persist.img` (raw ext4, label
`AMICACHY_DATA`, 32 GiB) and attaches it as a second USB stick. From
inside the live ISO it looks identical to a real second pendrive
partition, so the entire persistence path can be validated without
flashing physical media.

To start fresh, drop `--reset-persist` from the next run; the partition
contents survive.
