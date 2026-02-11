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
