# MASTER_PLAN.md: Arquitectura Técnica y Roadmap

## 1. Stack Tecnológico
- **Base:** CachyOS (Repositories x86-64-v3/v4).
- **Kernel:** `linux-cachyos` con flags: `quiet splash mitigations=off nowatchdog`.
- **Compositores Wayland:**
    - **Cage:** Para perfiles de emulación pura (lanza una sola app a pantalla completa).
    - **Labwc:** Para el perfil de desarrollo (manejo de ventanas ligero).
- **Emulador:** Amiberry v7.1+ (compilado con soporte Wayland/KMS y SDL3).
- **Gestor de Arranque:** `systemd-boot` (rápido y minimalista).

## 2. Sistema de Perfiles (Multi-Boot)
El archivo `loader.conf` de systemd-boot gestionará entradas que pasan el parámetro `amiprofile` al kernel:
- `classic_68k`: Lanza Amiberry configurado como A500/A1200.
- `ppc_nitro`: Lanza Amiberry con QEMU-PPC y prioridad `chrt -f 52`.
- `dev_station`: Lanza Labwc con VS Code + Amiberry + Shared Folders.
- `aros_live`: (Solo en ISO) Arranca el sistema AROS directamente para pruebas.

## 3. Lógica del Instalador (AmiCachyInstall)
El instalador será una aplicación Python/PySide6 ejecutada en la ISO Live (bajo Cage):
- **Hardware Audit:** 1. Verificar nivel de instrucción CPU (v2, v3, v4).
    2. Comprobar soporte de virtualización (VT-x/AMD-V).
    3. Ejecutar benchmark de cálculo mononúcleo para validar potencial PPC.
- **Configuración Automática:** Si la CPU es apta, instalar el kernel v3/v4 correspondiente y aplicar los tweaks de latencia.

## 4. Flujo de Arranque (AmiLaunch)
Un script de inicio en `/usr/bin/amilaunch` leerá `/proc/cmdline`:
```bash
PROFILE=$(cat /proc/cmdline | grep -oP 'amiprofile=\K\S+')
case $PROFILE in
  classic_68k) exec cage -- amiberry --config /path/a1200.uae ;;
  ppc_nitro)   exec cage -- amiberry --config /path/os41.uae ;;
  dev_station) exec labwc -s /path/dev_startup.sh ;;
esac
```

## 5. Plan de futuro: AmiCachy-HLE (modo nativo)

Nuevo modo de arranque alternativo a Amiberry/FS-UAE: en lugar de emular el hardware
completo (LLE), se reimplementa el **contrato de AmigaOS** en Rust (HLE), con Musashi
como core 68k vía FFI. Target: aplicaciones (productividad, desarrollo); los juegos con
acceso directo a hardware siguen en Amiberry/FS-UAE.

**Documentación de ingeniería completa en [`docs/hle/`](docs/hle/README.md)** (fuente
original: `docs/AmiCachy-HLE_Arquitectura.txt`). Piezas principales:

- **Ejecución:** `musashi-sys`/`musashi-rs` + `amicachy-exec` (scheduler cooperativo,
  tasks, señales, memoria) + `amicachy-dos` → hilo dedicado `SCHED_FIFO` (BORE
  penalizaría un proceso que no cede); renderer/audio/IO en hilos aparte
  ([doc 01](docs/hle/01-ejecucion-y-kernel.md)).
- **Escritorio:** `amicachy-compositor` propio basado en **Smithay** (Cage se queda
  para los modos Amiberry/QEMU); Workbench propio con ventanas HLE + ventanas Linux
  nativas ([doc 02](docs/hle/02-compositor-y-escritorio.md)).
- **Devices:** Paula→cpal, bsdsocket→libc, PRT:→CUPS, clipboard→Wayland, etc.
  ([doc 03](docs/hle/03-perifericos-y-devices.md)).
- **Filesystem:** assigns sobre `/opt/amicachy`, ENV/ENVARC, protection bits vía
  xattr, usuario único `amiga` ([doc 04](docs/hle/04-filesystem-assigns-permisos.md)).
- **Boot:** `amicachy-early.service` + startup-sequence real + `LoadWB`; objetivo ~2 s
  a escritorio ([doc 05](docs/hle/05-arranque-y-shell.md)).
- **DASH cross-target:** 68k/x86_64/aarch64 con `libamicachy-intuition` como runtime
  común; repo local en `~/Projects/FreeMEMLang`
  ([doc 06](docs/hle/06-dash-cross-target.md)).
- **Paquetes:** gestor `acp` (Aminet + pacman + repo propio `.acz`), repo overlay
  pacman en GitHub Pages ([doc 07](docs/hle/07-paquetes-y-repositorios.md)).

**Roadmap:** mes 1–2 Musashi + exec mínimo; mes 3–4 dos.library (hito: shell AmigaOS);
mes 5–6 Intuition sobre wgpu; mes 7+ Workbench/MUI/Paula.

**Primer PR:** `pkg/amicachy-hle/` con `amicachy-desktop` mínimo (Cage + ventana wgpu
azul Workbench + texto "AmiCachy HLE — WIP" en Topaz), sin Musashi — solo validar
pipeline PKGBUILD/boot entry/Cage.

**Restricciones:** no usar el leak de AmigaOS 3.1 (clean room sobre NDK pública);
naming siempre prefijado `amicachy-*` (nunca "Amiga"/"Workbench"/"Intuition" como
marca).

## 6. Deuda técnica

_(Sin deuda activa.)_

