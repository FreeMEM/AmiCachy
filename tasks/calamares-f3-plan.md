# Plan F3 — Esqueleto Calamares (happy path T1)

## Context

La migración del instalador AmiCachy de PySide6 a Calamares ya tiene hechas F1
(inventario), F2.a–c (VMs baseline) y **F3.0** (paquete `pkg/amicachy-base/`, el
rootfs payload del target). F3 es el primer instalador Calamares **funcional**:
debe instalar AmiCachy en un **disco vacío** (escenario T1) y producir un sistema
que arranca a un perfil AmiCachy real (Amiberry), validable de extremo a extremo en
la VM `dev/dualboot-vm/`. Dual-boot real (F4), branding pulido (F5) y las páginas
QML de hardware/perfiles/addons (F6) quedan fuera.

**Dato que fija el alcance:** el `case *)` de `amilaunch.sh:472-476` hace `exit 1`
si `amiprofile=` está vacío/desconocido. Por tanto un sistema instalado **sin
entradas systemd-boot con `amiprofile=` no arranca a nada útil** → F3 obliga a
generar esas entradas. `cachyos-calamares 3.4.1-8` está disponible en repos CachyOS.

**Decisiones de alcance confirmadas con el usuario:**
1. **Boot entries → módulo Python** `amicachy-postinstall` (sub-job `profiles`), no
   shellprocess. Código reutilizable tal cual en F6.
2. **Payload → squashfs target separado y limpio** (sin instalador/Calamares dentro),
   no el squashfs único del live.
3. **Reemplazar ya el instalador viejo en el live** (Calamares arranca desde F3; el
   switchover de `tools/installer/` → `installer-legacy/` formal sigue siendo F8).

---

## Componentes a construir

### A. Paquete `pkg/calamares-config-amicachy/` (núcleo de F3)

PKGBUILD `arch=any` análogo a `pkg/amicachy-base/PKGBUILD` (assets propios bajo
`files/`, sin compilar). Construido por `tools/build_calamares_config.sh` (clon de
`tools/build_amicachy_base.sh`). Instala:

- **`etc/calamares/settings.conf`** — secuencias `show` y `exec` (ver §D).
- **`etc/calamares/modules/*.conf`** — config de cada módulo estándar (§D).
- **`etc/calamares/branding/amicachy/`** — branding **mínimo** F3 (`branding.desc`
  con nombre/colores AmiCachy + slide placeholder). El pulido Workbench es F5.
- **Módulo Python custom** (ver §B), instalado en
  `usr/lib/calamares/modules/amicachy-postinstall/`.

### B. Módulo Python `amicachy-postinstall` (sub-job `profiles` solo)

Estructura estándar de job Calamares Python:
```
usr/lib/calamares/modules/amicachy-postinstall/
├── module.desc        # type: job, interface: python, script: main.py
└── main.py            # def run(): genera loader.conf + entries
etc/calamares/modules/amicachy-postinstall.conf   # datos (perfiles, cmdline)
```
`main.py::run()`:
- `root = libcalamares.globalstorage.value("rootMountPoint")`.
- Lee `amicachy-postinstall.conf`: `default_profile` (=`classic_68k`),
  `always_install` (=`[asset_manager]`), y la tabla de perfiles (id, filename,
  title, options) con **el cmdline silenciado del live** (`00-install.conf:4`:
  `loglevel=0 rd.systemd.show_status=false … vt.global_cursor_default=0` + bloque
  NVIDIA), NO el de `resources.py` (que usa `loglevel=3`).
- En F3 el conjunto a instalar = `[default_profile] + always_install`. **Diseñado
  para F6**: leerá la selección real de `globalstorage["amicachy_profiles"]` cuando
  exista la página QML; si no hay clave, usa el default (comportamiento F3).
- Escribe `<root>/boot/loader/loader.conf` (`default 01-classic-68k.conf`, timeout 5,
  editor no, console-mode max) y `<root>/boot/loader/entries/{01-classic-68k,04-asset-manager}.conf`.
- Contrato a preservar palabra por palabra: `amiprofile=<id>`, y `mitigations=off
  nowatchdog` **solo** en classic_68k/ppc_nitro (inventario §6).
- Fuente de verdad de la tabla de perfiles: portar desde `tools/installer/resources.py:11-44`
  (`BOOT_ENTRIES`, `LOADER_CONF_TEMPLATE`, `ALWAYS_INSTALL_ENTRIES`) ajustando el cmdline.

### C. Squashfs target separado y limpio

- **`archiso/packages-target.x86_64`** (nuevo): lista de paquetes del sistema
  instalado = `packages.x86_64` **menos** lo solo-live (`cachyos-calamares`,
  `calamares-config-amicachy`, `pyside6`, `code`, y `amicachy-installer`/data del
  wizard), **más** `amicachy-base` (vía repo local). Incluye `linux-cachyos-headers`
  que hoy se omite del live a propósito (`packages.x86_64:3-8`).
- **`tools/build_target_rootfs.sh`** (nuevo): `pacstrap -c` un dir temporal con
  `packages-target.x86_64` usando el `pacman-<arch>.conf` correcto + repo local
  (amiberry, amicachy-base), luego `mksquashfs` → `out/amicachy-target.sfs`.
- En F3, `build_iso.sh` copia `out/amicachy-target.sfs` a
  `archiso/airootfs/usr/share/amicachy/target.sfs` para que vaya en el live y
  `unpackfs` lo lea desde `/usr/share/amicachy/target.sfs` en el sistema arrancado.
  **Trade-off aceptado:** duplica tamaño (squashfs dentro del squashfs live). Nota en
  el plan: optimización futura = colocar el `.sfs` como archivo suelto en la ISO 9660
  en vez de dentro del airootfs; fuera de alcance F3.

### D. `settings.conf` — secuencia de módulos

`show` (wizard; sin QML custom — esos son F6):
`welcome → locale → keyboard → partition → users → summary`

`exec` (instalación):
```
partition → mount → unpackfs → fstab → locale → keyboard → localecfg →
hwclock → networkcfg → users → hostname → services-systemd → initramfs →
bootloader → amicachy-postinstall → umount
```
**Orden crítico (riesgo inventario §9):** `amicachy-postinstall` va **después** de
`bootloader`, para sobrescribir el `loader.conf` que Calamares escribe por defecto.
`bootloader.conf`: forzar **systemd-boot** (`bootloader: sd-boot`) — cachyos-calamares
tiende a GRUB por defecto — y `installEFIFallback: false`.

Configs de módulos estándar a fijar:
- **`partition.conf`** (T1 disco vacío): modo *erase*; layout de 3 particiones —
  EFI fat32 (label `AMIEFI`, esp, montada en `/boot`), root ext4 (label `AMICACHY`,
  `/`), data ext4 (label `AMIGADATA`, `/home/amiga/Amiga`). `efiSystemPartition: /boot`.
  Replica `backend.py::partition_disk:276-319`.
- **`unpackfs.conf`**: origen `/usr/share/amicachy/target.sfs` → destino `/`.
- **`users.conf`**: usuario `amiga`, **UID 1000** (riesgo §9), grupos
  `wheel,audio,video,input`, autologin, password vacío (passwd -d), sudo wheel.
- **`hostname`**: `amicachy`. **`services-systemd`**: enable `NetworkManager`.
- **`locale/keyboard/localecfg/hwclock/fstab/mount/initramfs/umount`**: estándar
  (defaults Arch). `initramfs` regenera con el `mkinitcpio.conf` que ya trae
  `amicachy-base` (hook plymouth).

### E. Flip del autostart del live (reemplazar el PySide6)

- **`archiso/airootfs/usr/bin/amilaunch.sh`** — `run_installer():358-393`: cambiar
  `cage -- /usr/bin/amicachy-installer` por lanzar Calamares como root bajo cage
  (vía `pkexec`/launcher que trae `cachyos-calamares`, o `cage -- sudo -E calamares`;
  el user `amiga` está en `wheel`). Mantener el bloque de fallback con log.
- **`archiso/packages.x86_64`**: añadir `cachyos-calamares`, `calamares-config-amicachy`,
  `amicachy-base` (estos dos del repo local). `amiprofile=installer` en
  `00-install.conf` se conserva (la cadena boot→amilaunch→installer no cambia, solo
  cambia *qué* instalador lanza).

### F. Integración en el build

- **`tools/build_iso.sh`**: extender la lógica de repo local (hoy solo `amiberry-*`,
  líneas 194-274) para incluir también `amicachy-base-*` y `calamares-config-amicachy-*`;
  invocar `build_amicachy_base.sh`, `build_calamares_config.sh` y
  `build_target_rootfs.sh` (o documentar el orden) antes de `mkarchiso`; copiar el
  `target.sfs` a `airootfs` y limpiarlo en el `trap … EXIT` (junto a
  `unbundle_installer_data`, línea 398).

---

## Archivos

**Nuevos**
- `pkg/calamares-config-amicachy/PKGBUILD`
- `pkg/calamares-config-amicachy/files/etc/calamares/settings.conf`
- `pkg/calamares-config-amicachy/files/etc/calamares/modules/{partition,unpackfs,mount,fstab,users,locale,bootloader,services-systemd,initramfs,welcome,amicachy-postinstall}.conf`
- `pkg/calamares-config-amicachy/files/etc/calamares/branding/amicachy/branding.desc` (+ placeholder)
- `pkg/calamares-config-amicachy/files/usr/lib/calamares/modules/amicachy-postinstall/{module.desc,main.py}`
- `tools/build_calamares_config.sh`
- `tools/build_target_rootfs.sh`
- `archiso/packages-target.x86_64`

**Modificados**
- `archiso/airootfs/usr/bin/amilaunch.sh` (run_installer → Calamares)
- `archiso/packages.x86_64` (+calamares, +config, +amicachy-base)
- `tools/build_iso.sh` (repo local + target.sfs + orden de builds)

**Reutilizar (no reescribir)**
- `tools/installer/resources.py:11-44` — tabla BOOT_ENTRIES/loader (portar a `amicachy-postinstall.conf`)
- `tools/installer/backend.py:276-319` — layout de particiones (replicar en `partition.conf`)
- `pkg/amicachy-base/` — ya provee scripts+configs del target; el target.sfs lo instala
- `tools/build_amicachy_base.sh` — patrón para los dos wrappers nuevos

---

## Verificación (T1, end-to-end)

1. Construir paquetes y ISO:
   `tools/build_amicachy_base.sh` → `build_calamares_config.sh` →
   `build_target_rootfs.sh` → `tools/build_iso.sh` (o el orden que integre F).
2. Arrancar la ISO en la VM con disco vacío:
   `dev/dualboot-vm/scripts/run-test.sh --baseline empty-50g --iso out/<nueva>.iso`
3. En la VM: **Calamares** arranca (no el PySide6). Completar wizard (locale, teclado,
   disco = el vacío de 50G, usuario amiga). Instalar. Reboot.
4. Comprobar en el sistema instalado:
   - systemd-boot muestra **Classic 68k** (default) y **Asset Manager**.
   - Arranca classic_68k → **Amiberry** (no el fallback de amilaunch).
   - `id amiga` → **uid=1000**, grupos wheel/audio/video/input.
   - `cat /proc/cmdline` → `amiprofile=classic_68k` + silenciadores + `mitigations=off
     nowatchdog`; la entrada asset_manager **sin** `mitigations=off`.
   - El target **no** contiene `calamares`/`amicachy-installer`/`pyside6`
     (validar squashfs limpio).
5. `dev/dualboot-vm/scripts/verify-untouched.sh` no aplica a T1 (disco vacío) pero
   confirmar que el resto del flujo (overlay, serial log) queda limpio.

## Riesgos / notas de implementación
- **systemd-boot, no GRUB**: forzar en `bootloader.conf`; verificar que
  cachyos-calamares respeta `sd-boot` (si su PKGBUILD parchea a grub, puede requerir
  un `bootloader.conf` explícito o un override del módulo).
- **Calamares como root en el live**: resolver privilegios (pkexec/polkit del paquete
  vs sudo); el user `amiga` es wheel.
- **Orden bootloader → postinstall** es la causa nº1 de regresión (loader.conf
  pisado). Tenerlo fijo en `settings.conf` desde el principio.
- **Tamaño de la ISO** crece por el target.sfs embebido; aceptado para F3, optimizar
  después.
