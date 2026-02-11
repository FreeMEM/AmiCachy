*[Espanol](README.es.md)*

# The Soul of AmiCachyEnv

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
