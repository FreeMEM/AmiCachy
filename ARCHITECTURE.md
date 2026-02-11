# AmiCachyEnv: Technical Architecture & Specification

## 1. Project Vision
AmiCachyEnv is a high-performance, minimalist Amiga environment built on **CachyOS (Arch Linux)**. It provides a "near-metal" experience by hiding the Linux layer, optimizing kernel latency for emulation, and providing specialized profiles (68k, PPC, and Development).

## 2. Core Tech Stack
* **Base OS:** CachyOS (x86-64-v3/v4 optimized kernels).
* **Kernel:** `linux-cachyos` (BORE scheduler). Boot flags: `quiet splash mitigations=off`.
* **Display Server:** Wayland (Native).
    * **Cage:** (Kiosk mode) for 68k/PPC emulation profiles.
    * **Labwc:** (Windowed) for the Development profile.
* **Emulator:** Amiberry v7.1+ (Wayland/KMS support + QEMU PPC bridge).
* **Bootloader:** `systemd-boot` with multi-profile support.

## 3. System Architecture & Boot Flow
1. **UEFI -> systemd-boot:** User selects profile (Classic, PPC, or Dev).
2. **Kernel Init:** Loads with `amiprofile=PROFILE_ID`.
3. **Auto-login:** TTY1 autologin to user `amiga`.
4. **AmiLaunch Script:** Parses `/proc/cmdline` and executes the corresponding session:
    * `classic_68k`: `cage -- amiberry --config a1200.uae`
    * `ppc_nitro`: `cage -- amiberry --config os41.uae` (with Real-time priority).
    * `dev_station`: `labwc -s start_dev_env.sh` (VS Code + Amiberry).

## 4. Hardware Audit & Benchmark (Pre-Install)
The installer must validate the following before allowing PPC installation:
* **Architecture:** Verify x86-64-v3 (AVX2) or v4 (AVX512).
* **Virtualization:** Ensure VT-x/AMD-V is enabled for QEMU-PPC.
* **Single-Core Bench:** A Python stress test to estimate if the CPU can surpass native PPC hardware (e.g., AmigaOne X5000).

## 5. Development Environment (AmiCachyDev)
A specialized profile designed for my custom language (Transpiler -> C -> Amiga Native).
* **Workflow:** Hybrid Linux-Amiga development.
* **Tools:** VS Code (OSS) + Custom MUI Design Extension.
* **Integration:** Automatic shared folders between Linux and Amiberry (`DEV:` drive).
* **Debug Bridge:** Communication between VS Code and Amiberry for real-time debugging.

## 6. LiveISO & Installer
* **Live Mode:** Boots directly into Amiberry with AROS (Wayland/Cage).
* **Installer:** PySide6 GUI with:
    * Disk partitioning (EFI, Root, Persistant Amiga_Data).
    * Slideshow of Amiga graphics during `pacstrap`.
    * Automatic `systemd-boot` entry generation based on user selection.
* **Branding:** Silent boot with Plymouth (Amiga Boing Ball/Workbench themes) to hide Linux origins (Android-style abstraction).

## 7. Implementation Priorities
1. **Task 1:** Create `profiledef.sh` for Archiso with CachyOS repos.
2. **Task 2:** Script `hardware_audit.py` (PySide6) for benchmarking.
3. **Task 3:** Script `amilaunch.sh` to handle profile-based booting.
4. **Task 4:** Configure Labwc environment for the Dev Station.
