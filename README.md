*[Espanol](README.es.md)*

# The Soul of AmiCachy

## 1. The Mission: "The Ultimate Amiga on PC"
This project is not "a Linux distro with an emulator". The goal is to build a CachyOS-based system that transforms a modern PC into a high-performance Amiga workstation. We want the user to forget there's a Linux kernel underneath; the system should behave like a dedicated appliance (console-style or Android-like).

## 2. Why CachyOS Instead of Debian/Standard Arch?
Most projects use Debian for stability, but we prioritize latency and raw power.

**Optimized Kernels:** CachyOS compiles its kernels for specific CPU levels (x86-64-v3 and v4). This allows us to leverage modern instructions (AVX-512) that drastically accelerate heavy emulation.

**Zero Latency:** We use the BORE scheduler. In emulation, the delay between pressing a button and seeing the reaction on screen (input lag) is the enemy. CachyOS gives us the fastest base in the current Linux ecosystem.

**No Mitigations:** For users who want to squeeze every bit of PowerPC performance, we disable kernel security mitigations (Spectre/Meltdown). In a retro-gaming/dev system, gaining that 10-15% speed boost matters more than server-grade security.

## 3. The PowerPC Challenge (AmigaOS 4.1)
Native Amiga PPC hardware (like the AmigaOne X5000) is expensive and hard to find. We want this system, through Amiberry 7.1 and QEMU-PPC, to surpass (or at least match) that performance.

To achieve this, the system must be self-configuring. If it detects a powerful processor, it should assign real-time priorities to the emulation process.

## 4. Aesthetics and User Experience (Anti-Linux)
The system must stay "hidden".

**Silent Boot:** No white text scrolling by. We want a clean boot with the Amiga logo.

**Wayland/Cage:** We won't use desktops like GNOME or KDE. We use Cage, a compositor that launches a single application fullscreen. If the user picks "Amiga 1200", the PC boots and — without seeing a single Linux menu — the Workbench appears.

### Cage: Wayland in Its Purest Form

Cage is not an application running "inside" a desktop; it **is** the graphics server (compositor) itself. It replaces what in the old Linux world was X11 or in the modern one is GNOME/KDE.

**We eliminate the middleman.** In a normal distro the graphics chain is:

```
Kernel → Graphics Server → Desktop (panel, wallpaper, menus) → Amiberry
```

With Cage, the chain becomes:

```
Kernel → Cage → Amiberry
```

**Full frame control.** As a native Wayland compositor, Cage gives Amiberry total control of the screen. This is what allows Amiberry v7.1 to use KMS (Kernel Mode Setting): the image goes practically straight from emulation to the graphics card.

**Result:** we eliminate 99% of stuttering problems and the lag that makes playing Pinball Dreams unplayable.

**GPU:** Graphics card detection must be automatic to use native KMS/Wayland drivers, eliminating tearing and improving scroll smoothness in games.

## 5. The Developer Profile (Hybrid Dev)
We don't just want to play, we want to create.

I'm developing a language that transpiles to C for Amiga and a VS Code extension for designing GUIs with MUI.

I need a boot mode where VS Code (modern) and Amiberry (retro) coexist seamlessly, sharing files in real time. It's a "hybrid development workstation".

## 6. Multi-Boot: One PC, Many Amigas
The system must let the user choose their "machine" at power-on:

- An Amiga 500 for purists.
- An Amiga 1200 with RTG for 68k graphics power.
- An AmigaOS 4.1 for the PowerPC experience.
- A Development Environment for programming.

Each option must be an optimized, self-contained environment, but sharing the same library of files and ROMs.

---

## 7. Development Guide

### CPU compatibility

AmiCachy auto-detects your CPU's architecture level and adapts automatically:

| CPU level | Examples | Repos used | Packages | Performance |
|-----------|----------|-----------|----------|-------------|
| **generic** | Any x86-64 CPU since 2003 | `cachyos`, Arch base | Plain x86-64 | Slowest, max compatibility |
| **v3** (AVX2) | Intel Haswell+ (2013), AMD Excavator+ (2015) | `cachyos-v3` + above | Optimized v3 | Full speed on most modern PCs |
| **v4** (AVX-512) | Intel Rocket Lake+ (2021), AMD Zen 4+ (2022) | `cachyos-znver4` + above | Optimized v4 | ~5% over v3 on supported CPUs |

Both `build_iso.sh` and `build_iso_docker.sh` accept `--cpu-arch generic|v3|v4` (default `v3`). The output is named `amicachy-<ARCH>-DATE-x86_64.iso` so you can keep all three side by side.

```bash
./tools/build_iso_docker.sh --cpu-arch generic   # universal, any x86-64 CPU
./tools/build_iso_docker.sh --cpu-arch v3        # default — most modern PCs
./tools/build_iso_docker.sh --cpu-arch v4        # AVX-512 only
```

**Boot-time safety:** every variant ships with `amilaunch.sh`, which detects when a CPU is missing required ISA features and shows a clear error message instead of crashing with `SIGILL`.

The pacman config for each variant lives in `archiso/pacman-{generic,v3,v4}.conf`. `Architecture =` is set explicitly per file so a host with newer instructions can never accidentally pull a higher-arch package out of its local cache and ship it inside a lower-arch ISO.

### Prerequisites

You need a Linux host (Ubuntu, Fedora, Arch, etc.) with the following:

```bash
# Core tools
sudo apt install qemu-system-x86 qemu-utils ovmf gdisk dosfstools  # Debian/Ubuntu
sudo pacman -S qemu-full edk2-ovmf gptfdisk dosfstools              # Arch/CachyOS

# Docker (for building — the host doesn't need pacman/archiso)
sudo apt install docker.io && sudo usermod -aG docker $USER  # Debian/Ubuntu
sudo pacman -S docker && sudo usermod -aG docker $USER       # Arch/CachyOS
sudo systemctl enable --now docker

# KVM (verify hardware virtualization)
lsmod | grep kvm    # should show kvm_intel or kvm_amd
```

### Why Docker?

AmiCachy is based on CachyOS (an Arch Linux fork). Building the ISO requires `mkarchiso`, `pacman-key`, and access to CachyOS package repositories — tools that only exist on Arch-based systems. Docker lets us build from **any Linux host** using the official CachyOS container image, with no modifications to the host system.

### Building the ISO (for distribution)

The ISO is the final distributable artifact — a bootable `.iso` file with all profiles, the installer wizard, and the live demo modes.

```bash
# Build inside a CachyOS Docker container (works on any host)
./tools/build_iso_docker.sh                    # default: --cpu-arch v3

# Or directly on a CachyOS / Arch host (faster, no Docker):
sudo ./tools/build_iso.sh                      # default: --cpu-arch v3

# Pick the CPU baseline explicitly:
./tools/build_iso_docker.sh --cpu-arch generic # any x86-64 CPU since 2003
./tools/build_iso_docker.sh --cpu-arch v3      # Haswell+/Excavator+
./tools/build_iso_docker.sh --cpu-arch v4      # Rocket Lake+/Zen 4+

# Output: out/amicachy-<ARCH>-YYYY.MM.DD-x86_64.iso
```

`generic` is the safest choice when you don't know the target hardware; `v3` is the right default for most current PCs; `v4` only makes sense on a CPU with AVX-512.

**Clean builds by default.** `build_iso.sh` wipes `work/` before every build so that changes to `packages.x86_64` or `airootfs/` are picked up reliably (mkarchiso uses stamp files in `work/` and would otherwise silently skip stages). For fast iteration when you're only tweaking things that survive the cache, pass `--reuse-work`.

**Amiberry binary is arch-tagged and built on demand.** `tools/build_amiberry.sh --cpu-arch generic|v3|v4` produces `out/amiberry-<VER>-<REL>-<arch>-x86_64.pkg.tar.zst` with `-march=x86-64-vN -mtune=generic` baked in (overrides CachyOS's `-march=native`, which otherwise pins the binary to the build host's CPU and causes `SIGILL` on any other machine). `build_iso.sh --cpu-arch X` picks the matching `.pkg`; if it doesn't exist, it invokes `build_amiberry.sh --cpu-arch X` automatically (disable with `--no-auto-amiberry`). One-shot for all three arches at once: `./tools/build_amiberry.sh --cpu-arch all`.

**Release matrix in one command.** `tools/build_all.sh` builds the three amiberry variants, the three ISOs, and the three pendrive `.img`s in a single run. Idempotent: artifacts already in `out/` are reused unless you pass `--force`. Sub-selectable with `--arch v3,v4` and `--skip-{amiberry,iso,pendrive}`. Cache `sudo` first (`sudo -v`) so it doesn't stall mid-matrix asking for the password.

```bash
./tools/build_all.sh                       # everything, all three arches
./tools/build_all.sh --arch v3             # one arch end-to-end
./tools/build_all.sh --skip-pendrive       # ISOs + amiberry only
./tools/build_all.sh --force               # rebuild even if outputs exist
```

**Pre-loading user-supplied content into the ISO.** `build_iso.sh` accepts `--seed-assets DIR` where `DIR` contains a `kickstarts/` and/or `harddrives/` subtree. Anything inside is bundled into the ISO and exposed to Amiberry on first boot. Useful if you want to build a complete personal image with your own legally-obtained Kickstart ROMs and HDFs, instead of providing them at runtime through the Asset Manager.

**Building flashable pendrive images.** `tools/build_pendrive.sh` wraps any AmiCachy ISO with a small (256 MB) `AMICACHY_DATA` seed partition (NTFS by default so Windows mounts it natively) into a single `.img` you can flash with one `dd`. The image is intentionally compact — on the first boot from the pendrive, `amicachy-grow-data.service` automatically expands `AMICACHY_DATA` to fill all remaining space on the stick (NTFS/ext4; exFAT is left alone). So a 64 GB pendrive ends up with ~63 GB of writable user space without forcing you to ship a 60 GB `.img`. Run `./tools/build_pendrive.sh --help` for the full set of flags (assets, seed size, filesystem type).

**Building the installer (Calamares, F3/F4).** AmiCachy's installer is **Calamares** with Amiga branding: its configuration (sequence, branding, and the `amicachy-postinstall`/`amicachy-foreign-os` Python jobs) lives in the `pkg/calamares-config-amicachy/` package, and the system it installs is deployed from a **separate clean squashfs** (not the live one). So `build_iso.sh` expects a few packages in the local repo; if you touch the installer, rebuild them in this order (each drops its artifact in `out/`):

```bash
./tools/build_amicachy_base.sh                 # package with the installed-system (target) assets
./tools/build_calamares_config.sh              # Calamares config/branding/modules (bump pkgrel when you touch it!)
./tools/build_calamares_compat.sh              # temporary lib shim (yaml-cpp/boost); drop when upstream rebuilds
./tools/build_target_rootfs.sh --cpu-arch v3   # squashfs of the installed system (~6 min, Docker)
sudo ./tools/build_iso.sh --cpu-arch v3        # bundles the packages + target.sfs into the ISO
```

If you only changed `calamares-config`, just `build_calamares_config.sh` (bumping `pkgrel`, or mkarchiso reinstalls the cached copy) + `build_iso.sh` is enough. The full design, the `amiprofile=` contract, and the recurring gotchas live in `tasks/calamares-migration-handoff.md` and `tasks/calamares-f3-gotchas.md`.

**Only build the ISO when you need a distributable image.** For day-to-day development, use the dev VM workflow below.

**Reclaiming disk space.** Every build run drops a fresh dated artifact in `out/` (ISOs ~2-4 GB, pendrives up to ~34 GB), and each dual-boot test leaves a multi-GB overlay in `dev/`, so those dirs balloon fast. `tools/clean.sh` prunes them **safely** (dry-run by default; never touches the `dev/dualboot-vm/` baselines, the newest ISO, or `out/amicachy-target.sfs`). `./tools/clean.sh` shows what it would free; `./tools/clean.sh --yes` does the safe sweep (old ISOs + test overlays + `dev/` scratch). Optional extra reclaim: `--pendrives` (release `.img` images), `--loaded` (asset-loaded ISO + `.7z`), `--dev-vms` (big VM scratch disks). See `./tools/clean.sh --help`.

#### Hardware support notes

- **NVIDIA GPUs.** Shipping ISOs include the proprietary NVIDIA driver (`nvidia-open-dkms` + `nvidia-utils`, Turing+ supported) and blacklist nouveau via the kernel cmdline. This is the only configuration where Wayland/EGL works reliably on RTX 20xx/30xx/40xx — nouveau's GSP path is still flaky on Ampere and breaks cage/wlroots. `nvidia-utils` is under the NVIDIA Software License (redistribution-clean for free distribution; the LICENSE ships at `/usr/share/licenses/nvidia-utils/LICENSE`).
- **Multi-GPU machines.** `amilaunch.sh` picks the DRM card whose connector is actually `connected` (largest preferred mode wins ties) and pins wlroots to it via `WLR_DRM_DEVICES`. Plug your cable into whichever GPU you want to drive the session — laptops with hybrid graphics, sobremesa with dGPU + iGPU, etc., are all handled the same way.
- **Firmware blobs.** `linux-firmware` was split upstream in late 2025; we explicitly include the consumer-hardware splits (nvidia, amdgpu, intel, broadcom, atheros, realtek, mediatek, …) so RTX 20xx+ kernels boot at all (without `linux-firmware-nvidia` they hang at Plymouth on bare metal).

### Development VM (fast iteration)

Rebuilding the ISO for every change is slow (10+ minutes). The dev VM gives you a **seconds-fast** edit-test cycle:

```
  Edit files ──> Sync (5 sec) ──> Boot VM (10 sec) ──> Test ──> Repeat
```

#### Initial setup (one-time)

```bash
# Cache sudo credentials first (needed for qemu-nbd disk mounting)
sudo -v && ./tools/dev_vm.sh create
```

This creates a 40 GB qcow2 virtual disk, partitions it (EFI + root), runs `pacstrap` via Docker with all AmiCachy packages, overlays the airootfs configuration, installs systemd-boot, and configures autologin. Takes ~10 minutes on the first run.

#### Edit-test cycle

```bash
# 1. Edit any project file
vim archiso/airootfs/usr/bin/amilaunch.sh

# 2. Sync changes to the VM disk (seconds)
sudo -v && ./tools/dev_vm.sh sync

# 3. Boot and test
./tools/dev_vm.sh boot

# 4. In another terminal, watch the boot log in real time
./tools/dev_vm.sh log
```

#### All commands

| Command | Description |
|---------|-------------|
| `./tools/dev_vm.sh create` | One-time: create disk, pacstrap, configure (uses Docker) |
| `./tools/dev_vm.sh sync` | Sync airootfs + boot entries + installer tools (seconds) |
| `./tools/dev_vm.sh boot` | Launch the VM with QEMU/KVM + UEFI |
| `./tools/dev_vm.sh boot-iso <ISO>` | Boot a built ISO under the same QEMU setup, with a scratch qcow2 as install target. Add `--persist` to attach a second USB stick labelled `AMICACHY_DATA`. |
| `./tools/dev_vm.sh boot-img <IMG>` | Boot a pendrive `.img` (output of `build_pendrive.sh`) as a USB stick. Copies the `.img` to `dev/` so the original stays pristine and grows the copy with `--disk-size 8G` (default) to exercise `amicachy-grow-data`. Add `--debug` to patch the systemd-boot entries for verbose kernel/journal output in `dev/img-serial.log`. |
| `./tools/dev_vm.sh install <pkg\|name>` | Install local .pkg.tar.zst or repo packages into the VM (uses Docker) |
| `./tools/dev_vm.sh log` | Tail the serial boot log in real time (`--full` for complete log) |
| `./tools/dev_vm.sh shell` | Mount the disk for manual inspection (interactive subshell) |
| `./tools/dev_vm.sh destroy` | Remove the dev VM disk and all artifacts |

> **Note:** `create`, `sync`, and `shell` need `sudo` for disk mounting (`qemu-nbd`). Run `sudo -v` beforehand to cache credentials.

#### Configuration

Environment variables let you customize the VM:

```bash
RAM=8192 CPUS=4 ./tools/dev_vm.sh boot       # more resources
DISK_SIZE=80G ./tools/dev_vm.sh create        # larger disk
DISPLAY_MODE=safe ./tools/dev_vm.sh boot      # no GL acceleration (fallback)
```

#### Debugging

All kernel and service output is captured via serial console to `dev/boot.log`:

```bash
# Real-time log while VM is running (in a separate terminal)
./tools/dev_vm.sh log

# Full log after VM exits
./tools/dev_vm.sh log --full
```

At the systemd-boot menu, press `e` to edit kernel parameters (e.g., remove `quiet splash` for verbose boot).

#### SSH access

The VM exposes port 2222 for SSH:

```bash
ssh -p 2222 amiga@localhost   # password: amiga
```

### Building Amiberry (the emulator)

Amiberry is not available as a pre-built package in Arch/CachyOS repositories. We compile it from source with CachyOS optimizations for maximum emulation performance:

- **x86-64-v3 CFLAGS** (AVX2) from CachyOS's `makepkg.conf`
- **Link-Time Optimization** (LTO) via CMake
- **DBUS control** for programmatic emulator management
- **IPC socket** for future debug bridge (VS Code <-> Amiberry)

```bash
# Build the amiberry .pkg.tar.zst inside Docker (~5 min)
./tools/build_amiberry.sh

# Output: out/amiberry-7.1.1-1-x86_64.pkg.tar.zst
```

The PKGBUILD is at `pkg/amiberry/PKGBUILD`.

#### Amiberry in the dev VM

Build once, install once — the package **persists in the qcow2 disk** across reboots. You only need to reinstall if you `destroy` the VM or want to update to a newer version.

```bash
# Install (one-time, after building — uses Docker + arch-chroot)
sudo -v && ./tools/dev_vm.sh install out/amiberry-*.pkg.tar.zst
```

#### Amiberry in the ISO

When building the ISO, the build script **automatically detects** the compiled amiberry package in `out/` and includes it. No manual steps needed:

```bash
# 1. Build amiberry (if not already done)
./tools/build_amiberry.sh

# 2. Build ISO — amiberry is included automatically
./tools/build_iso_docker.sh
```

If no amiberry package is found in `out/`, the ISO builds without it and prints a warning.

### Dual-boot test bench (installing alongside Windows/Linux)

To verify the installer **respects a pre-existing OS** (doesn't wipe an existing Windows/Linux), there's a QEMU/KVM bench in `dev/dualboot-vm/`: reproducible baselines, non-destructive overlays (the baseline is never touched), and partition-level verification. Full guide in `dev/dualboot-vm/README.md`; the gist:

**1) Build the baselines (once).** qcow2 disks with a pre-installed OS that test runs never modify:

```bash
cd dev/dualboot-vm
qemu-img create -f qcow2 baselines/empty-50g.qcow2 50G   # empty disk ("erase disk" test)
./scripts/build-baseline-debian.sh                        # Debian (ext4+GRUB-EFI), unattended (~10-20 min)
./scripts/build-baseline-windows.sh                       # Windows 11 (NTFS+ESP), SEMI-MANUAL (see below)
```

> **The Windows baseline is semi-manual.** Microsoft blocks automated ISO downloads by IP, so you normally drop your own `Win11_*.iso` into `dev/dualboot-vm/.cache/`. And on 24H2/25H2 the new setup engine ignores `autounattend.xml` during the windowsPE phase, so you click through ~5 prompts (key / edition / partition) during the build; the `specialize`/`oobeSystem` passes (account `tester`/`tester`, OOBE skip, locale) do apply. Details in the script header.

**2) Test the alongside install** (same flow as a real ISO):

```bash
# a) Boot the baseline ON ITS OWN (no --iso) to confirm the existing OS still boots:
./scripts/run-test.sh --baseline debian12-ext4-grub

# b) Install AmiCachy on top, picking "Install alongside" in Calamares:
./scripts/run-test.sh --baseline debian12-ext4-grub --iso ../../out/amicachy-v3-latest.iso

# c) Boot the INSTALLED disk (the big overlay, several GB), reusing its NVRAM, to
#    see the systemd-boot menu with AmiCachy + the previous OS:
./scripts/run-test.sh --overlay overlays/<big-overlay>.qcow2
```

**3) Verify the pre-existing OS is intact:**

```bash
sudo ./scripts/verify-untouched.sh --baseline debian12-ext4-grub \
     --overlay overlays/<big-overlay>.qcow2
```

Compares per-partition hashes. A pre-existing-OS partition showing `CHANGED` is a bug — **except** in "Install alongside", which **intentionally shrinks** the neighbour partition (`resize2fs` preserves the data): there the real proof is that the other OS still boots from the menu.

### Testing the ISO with KVM/libvirt

Once you have a built ISO, test it in a full UEFI virtual machine:

```bash
./tools/test_iso.sh                    # uses the latest ISO in out/
./tools/test_iso.sh path/to/file.iso   # specify ISO
./tools/test_iso.sh --destroy          # recreate the VM from scratch
```

This uses `virt-install` to create a VM with UEFI boot (OVMF), a 40 GB virtio scratch disk, and SPICE display. Requires `virt-manager` (`virt-install`, `virsh`, `virt-viewer`) and `libvirtd` running.

### Setting up KVM/libvirt + Vagrant

For a reproducible development environment, you can use Vagrant with the libvirt provider:

#### 1. Install KVM and libvirt

```bash
# Debian/Ubuntu
sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients \
    virt-manager bridge-utils

# Arch/CachyOS
sudo pacman -S qemu-full libvirt virt-manager dnsmasq iptables-nft

# Enable and start
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt $USER
# Log out and back in for the group to take effect
```

#### 2. Verify KVM works

```bash
virsh list --all         # should connect without errors
kvm-ok                   # (Ubuntu) or check /dev/kvm exists
```

#### 3. Install Vagrant with libvirt (optional)

Vagrant automates VM lifecycle if you prefer it over the `dev_vm.sh` / `test_iso.sh` scripts:

```bash
# Install Vagrant
sudo apt install vagrant           # Debian/Ubuntu
sudo pacman -S vagrant             # Arch/CachyOS

# Install the libvirt provider plugin
vagrant plugin install vagrant-libvirt

# Use with the built ISO
# (You would create a Vagrantfile that boots the ISO — see Vagrant docs)
```

### Project structure

```
AmiCachy/
├── archiso/                    # Archiso profile (ISO source)
│   ├── profiledef.sh           # ISO build settings
│   ├── pacman.conf             # Package repositories
│   ├── packages.x86_64         # Package list (~60 packages)
│   ├── airootfs/               # Filesystem overlay (configs, scripts)
│   │   ├── etc/                # System config (locale, autologin, plymouth)
│   │   ├── home/amiga/         # Default user home (labwc, bash_profile)
│   │   ├── usr/bin/            # amilaunch.sh, start_dev_env.sh, installer
│   │   └── usr/share/amicachy/ # UAE configs, plymouth theme
│   └── efiboot/loader/entries/ # systemd-boot entries (6 profiles)
├── pkg/
│   └── amiberry/PKGBUILD       # Amiberry package (CachyOS optimized, LTO)
├── tools/
│   ├── build_iso.sh            # ISO build (requires Arch/CachyOS host)
│   ├── build_iso_docker.sh     # ISO build via Docker (any Linux host)
│   ├── build_amiberry.sh       # Compile amiberry via Docker
│   ├── dev_vm.sh               # Development VM manager (fast iteration)
│   ├── test_iso.sh             # Test ISO in KVM/libvirt VM
│   ├── hardware_audit.py       # Standalone hardware audit GUI
│   ├── lib/cpu_arch.sh         # CPU arch detection (shared by all scripts)
│   └── installer/              # PySide6 installer wizard (7 pages)
├── dev/                        # [gitignored] Dev VM disk + logs
├── out/                        # [gitignored] Built ISOs and packages
├── ARCHITECTURE.md             # Technical specification
├── MASTER_PLAN.md              # Roadmap and tech stack
├── README.md                   # This file (English)
└── README.es.md                # Spanish version
```

### Contributing

1. **Fork and clone** the repository
2. **Install prerequisites** (see above): Docker, QEMU/KVM, OVMF
3. **Create the dev VM** (one-time, ~10 min):
   ```bash
   sudo -v && ./tools/dev_vm.sh create
   ```
4. **Build and install amiberry** (one-time, ~5 min):
   ```bash
   ./tools/build_amiberry.sh
   sudo -v && ./tools/dev_vm.sh install out/amiberry-*.pkg.tar.zst
   ```
5. **Edit-test cycle**:
   ```bash
   # Edit files in archiso/airootfs/ or tools/
   sudo -v && ./tools/dev_vm.sh sync
   ./tools/dev_vm.sh boot
   # In another terminal: ./tools/dev_vm.sh log
   ```
6. **Build the full ISO** when ready for distribution (amiberry is included automatically from `out/`):
   ```bash
   ./tools/build_iso_docker.sh            # optimized for your CPU
   ./tools/build_iso_docker.sh --generic  # universal (any x86-64)
   ```
7. **Submit a pull request**

## License

AmiCachy is released under the GNU General Public License v3.0 — see [LICENSE](LICENSE) for the full text.

Copyright (C) 2026 Francisco Antonio Tapias Bravo (FreeMEM)

Third-party components retain their original licenses (Amiberry, AROS, CachyOS packages, Plymouth themes, etc.). Optional bundles fetched at runtime through the Asset Manager (e.g. AROS Vision) are governed by their own upstream licenses, shown to the user before download.
