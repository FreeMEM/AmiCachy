*[Espanol](README.es.md)*

# The Soul of AmiCachy

## 1. The Mission: "The Ultimate Amiga on PC"
This project is not "a Linux distro with an emulator". The goal is to create an evolved fork of AmiBootEnv that transforms a modern PC into a high-performance Amiga workstation. We want the user to forget there's a Linux kernel underneath; the system should behave like a dedicated appliance (console-style or Android-like).

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

| CPU level | Examples | Docker image | Packages | Performance |
|-----------|----------|-------------|----------|-------------|
| **x86-64-v3** (AVX2) | Intel Haswell+ (2013), AMD Excavator+ (2015) | `cachyos-v3` | Optimized v3 | Full speed |
| **x86-64** (generic) | Older Intel/AMD, some VMs | `cachyos` | Generic | ~10-20% slower emulation |

**All build scripts detect this automatically.** No manual configuration needed — if your CPU lacks AVX2, generic packages are used and everything works. You just lose the v3 optimization.

**For distributable ISOs** that need to boot on unknown hardware, use the `--generic` flag:

```bash
./tools/build_iso_docker.sh --generic   # ISO boots on any x86-64 CPU
```

**Boot-time safety:** If a v3-built ISO boots on a machine without AVX2, `amilaunch.sh` detects the mismatch and shows a clear error message with instructions instead of crashing.

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
./tools/build_iso_docker.sh

# Build a universal ISO that boots on any x86-64 CPU (no AVX2 needed)
./tools/build_iso_docker.sh --generic

# Output: out/amicachy-YYYY.MM.DD-x86_64.iso
```

The script auto-detects your CPU and selects the matching CachyOS Docker image and package repositories. On CPUs with AVX2, it uses optimized x86-64-v3 packages; on older CPUs, it falls back to generic x86-64 packages automatically.

Use `--generic` when building ISOs for distribution to others (unknown hardware). Without this flag, the ISO is optimized for your machine's CPU.

**Only build the ISO when you need a distributable image.** For day-to-day development, use the dev VM workflow below.

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
# Install (one-time, after building)
sudo -v && ./tools/dev_vm.sh shell
sudo pacman -U /work/out/amiberry-*.pkg.tar.zst   # /work is the project root
exit

# Alternative: copy via SSH while the VM is running
scp -P 2222 out/amiberry-*.pkg.tar.zst amiga@localhost:/tmp/
ssh -p 2222 amiga@localhost "sudo pacman -U /tmp/amiberry-*.pkg.tar.zst"
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
4. **Build amiberry** (one-time, ~5 min):
   ```bash
   ./tools/build_amiberry.sh
   # Then install it in the VM:
   sudo -v && ./tools/dev_vm.sh shell
   sudo pacman -U /work/out/amiberry-*.pkg.tar.zst
   exit
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
