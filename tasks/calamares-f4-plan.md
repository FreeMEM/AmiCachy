# Plan F4 — Dual-boot real (T2 Windows, T3 otro Linux)

> Escrito 2026-06-14 al cerrar F3. Lee antes: `tasks/calamares-f3-gotchas.md`
> (gotchas que reaparecen) y `docs/calamares-migration-inventory.md` §6–9.

## Estado de implementación (2026-06-14)

**Código F4 implementado** (commit pendiente, paquete `calamares-config-amicachy-5`):
- ✅ A: `partition_amicachy.conf` → `initialPartitioningChoice: none` (ya no fuerza
  erase; aparecen *alongside*/*replace* solos). Comentado el reuso de ESP.
- ✅ B: módulo nuevo `amicachy-foreign-os` (`main.py` + `module.desc` + `.conf`).
  Validado con ESP sintética: Windows→`90-windows.conf`, Debian→`91-debian.conf`,
  excluye `systemd`/`BOOT`/`Linux`; en disco vacío no escribe nada.
- ✅ C: `settings.conf` → `amicachy-foreign-os` en `exec` tras `amicachy-postinstall`.
- ✅ PKGBUILD pkgrel → 5.

**Decisiones tomadas al implementar (AMIGADATA — historia, leer entera):**
La decisión osciló en la sesión del 2026-06-14 y aterrizó así (pkgrel **-8**):
- **AMIGADATA SEPARADA por defecto**, bien dimensionada: `partitionLayout` =
  AMICACHY (/, **fijo 20G**) + AMIGADATA (/home/amiga/Amiga, **100% del resto** = el
  grueso para los HDF). Aplica igual en *erase* (T1) y en *alongside*/*replace*
  (Calamares carva el par en el hueco — verificado: alongside SÍ aplica el layout).
- **Por qué separada**: una reinstalación puede "Reemplazar" solo AMICACHY y
  **conservar la librería Amiga** en AMIGADATA. Es el valor real que pedía el usuario.
- **Opt-out** = "Particionado manual" (una sola partición). Un *toggle* on/off bonito
  dentro del instalador automático **exige compilar Calamares desde fuente** (el
  `partitionLayout` se lee en config-time, `PartitionViewStep.cpp:945`; la GUI de
  particionado es C++; hoy consumimos el binario `cachyos-calamares`, no lo
  compilamos). Se descartó por coste; queda como posible fase futura (de paso
  permitiría eliminar el shim `calamares-compat-libs`).
- **Gotcha #5 vigente**: AMIGADATA monta en /home/amiga/Amiga → `useradd -m` salta
  skel → `amicachy-postinstall` lo copia (imprescindible).
- (Pendrive: cosa aparte, label `AMICACHY_DATA` por base inmutable; no confundir.)
- **T2 (Windows) — VALIDADO E2E (2026-06-26).** Dual-boot con Windows funciona:
  *alongside* encoge la NTFS, instala AmiCachy, y conviven Windows + AmiCachy
  arrancando ambos desde systemd-boot. Hubo **dos bloqueos en serie** hasta aquí:
  1. **NTFS sucia por Fast Startup (prerequisito real, NO la causa raíz).** Win11 trae
     Fast Startup activo y `shutdown /s` hace apagado híbrido (hiberna el kernel) → NTFS
     "sucia" → `ntfsresize` se niega. Fix baseline (hecho): `build-baseline-windows.sh`
     hace `powercfg /h off` antes del `shutdown /s`. Para **usuarios reales** sigue
     siendo un prerequisito (gotcha universal Windows+Linux) → componente D
     (`amicachy-preflight`) que detecte la NTFS sucia y **avise** en vez de ocultar
     alongside. (La ESP es de **512 MiB**; la nota antigua de "~100 MiB" era falsa.)
  2. **BLOQUEO REAL = faltaba `ntfsprogs` en el live (causa raíz).** Con la NTFS **ya
     limpia**, "Instalación paralela" SEGUÍA sin aparecer. Diagnóstico (descartando con
     datos: NTFS sucia → `ntfsresize --info` la valida limpia; automontaje → vda3 sin
     MOUNTPOINT; `requiredStorage` 5.5 GiB << 37.5 liberables; os-prober → ni instalado
     y Debian funcionaba igual). Causa: KPMcore solo marca una NTFS como redimensionable
     si encuentra el binario **`ntfsresize`**, y en Arch/CachyOS éste (+ mkntfs/ntfsfix/
     ntfsclone) vive en el paquete **`ntfsprogs`**, que `ntfs-3g` declara solo como
     dependencia **OPCIONAL** → no se arrastraba. El live tenía `ntfs-3g` pero NO
     `ntfsprogs` (la nota previa "ntfsresize SÍ está vía ntfs-3g" era **FALSA**). Debian
     (ext4) funcionaba porque `resize2fs` va en `e2fsprogs` (base). **Fix (commit
     43c0e14): `ntfsprogs` añadido a `archiso/packages.x86_64`.** Ver memoria
     `project_ntfs_resize_ntfsprogs`.
- **Post-instalación: Windows roba el BootOrder UEFI.** Tras arrancar Windows una vez,
  su `bootmgfw.efi` se recoloca primero en el `BootOrder` → el firmware arranca Windows
  directo en vez del systemd-boot de AmiCachy. Comportamiento **conocido** de Windows
  (no es bug; le pasa a GRUB y systemd-boot por igual). El menú y ambos SO siguen
  intactos: se recupera vía el Boot Manager del firmware (Esc/F12) eligiendo *Linux Boot
  Manager*. **Mitigación de producto pendiente** (ítem F4): opción 1 = documentar que el
  usuario arranca Windows desde el menú de AmiCachy; opción 2 = servicio oneshot que
  reafirme AmiCachy primero en el `BootOrder` (`efibootmgr -o`) en cada arranque.
- **Bench (commit c7899ba)**: `run-test.sh` añade `usb-tablet` (cursor host/invitado
  sincronizado) y activa el menú OVMF con `splash-time=8000` en arranques `--overlay`
  (para poder elegir *Linux Boot Manager* cuando Windows roba el orden).

**Estado: T2 (Windows) y T3 (otro Linux/Debian) VALIDADOS E2E.** Pendientes: el
preflight de NTFS sucia (componente D) y la mitigación del BootOrder de Windows.

---

## Context

F4 es **el motivo de toda la migración a Calamares**. El instalador PySide6 hacía
`wipefs --all` sobre el disco entero → destruía cualquier SO. F4 permite instalar
AmiCachy **junto a Windows / otro Linux** sin tocarlos, **reusar la ESP existente**
y añadir al menú de systemd-boot una entrada para arrancar el SO que ya estaba.

F3 (esqueleto, T1 disco vacío) está **validado E2E**: Calamares → particionado →
`unsquashfs` → systemd-boot (`amiprofile=classic_68k`) → Amiberry+AROS. F4 reusa
toda esa maquinaria y añade el manejo de discos con SO previo.

**Hallazgo que simplifica F4:** los modos de particionado de Calamares
(*erase* / *alongside* / *replace* / *manual*) aparecen **automáticamente** según
el contenido del disco — en un disco con Windows/Linux, el usuario ya verá
"Instalar junto a" y "Reemplazar partición" sin código nuestro. Y **systemd-boot
autodetecta Windows** (bootmgfw.efi) por defecto. Así que F4 es mayormente
**config + verificación + 1 módulo Python fino** (chainload de otros Linux).

## Componentes

### A. `partition_amicachy.conf` — habilitar dual-boot + reusar ESP
Hoy fuerza `initialPartitioningChoice: erase` + `partitionLayout` de 3 particiones
(EFI/AMICACHY/AMIGADATA). Cambios:
- **No forzar erase**: dejar que aparezcan *alongside* y *replace* (Calamares los
  muestra solos si hay particiones previas). El `partitionLayout` solo aplica a
  *erase* (T1, disco entero) — se mantiene para ese caso.
- **Reusar la ESP existente** (riesgo §9 nº2, EL crítico): cuando hay una ESP de
  Windows/Linux, Calamares debe **montarla y reusarla**, NO reformatearla (perdería
  el `bootmgfw.efi` de Windows). Verificar/ajustar `efiSystemPartition` y el flag de
  reuso. **Probar con verify-untouched que la ESP no cambia de hash salvo los
  ficheros que AmiCachy añade.**
- **AMIGADATA separada por defecto** (AMICACHY / fijo 20G + AMIGADATA el resto), en
  T1 y en dual-boot (Calamares carva el par en el hueco). Ver "Decisiones tomadas al
  implementar" arriba para el porqué (supervivencia a reinstalación) y el opt-out.

### B. Módulo Python `amicachy-foreign-os` (nuevo) — chainload del SO previo
Vive en `pkg/calamares-config-amicachy/files/usr/lib/calamares/modules/amicachy-foreign-os/`
(`module.desc` interface python + `main.py`). Estructura igual que `amicachy-postinstall`.
`run()`:
- `root = globalstorage["rootMountPoint"]`; ESP montada en `root/boot` (la reusada).
- Escanea `root/boot/EFI/*` buscando cargadores ajenos y escribe entradas Type-1 de
  systemd-boot en `root/boot/loader/entries/` (numeradas alto, p.ej. `90-windows.conf`,
  `91-<vendor>.conf`, para que salgan tras los perfiles AmiCachy):
  - **Windows**: `EFI/Microsoft/Boot/bootmgfw.efi` →
    ```
    title Windows Boot Manager
    efi   /EFI/Microsoft/Boot/bootmgfw.efi
    ```
    (sd-boot también lo autodetecta vía `auto-entries`, pero una entrada explícita es
    controlable y con título limpio).
  - **Otros Linux**: `EFI/<vendor>/{shimx64,grubx64}.efi` (debian, ubuntu, fedora,
    arch, …) → entrada con `efi /EFI/<vendor>/shimx64.efi` (preferir shim; si no, grub),
    título por vendor. **sd-boot NO autodetecta GRUB ajeno**, así que esto es
    imprescindible para T3.
  - Excluir `EFI/{systemd,BOOT,amicachy}` (lo nuestro / fallback).
- **NO** tocar el `default` del `loader.conf` (lo fija `amicachy-postinstall.profiles`
  a `classic_68k`). Solo añade entradas.
- Idempotente y tolerante a ESP sin EFI ajenos (T1: no escribe nada).

### C. `settings.conf` — orden
Añadir `amicachy-foreign-os` a la secuencia `exec` **después de `bootloader`** (y de
`amicachy-postinstall`, o justo después; lo importante es tras `bootloader`, con la
ESP ya montada). Riesgo §9 nº1: nada debe reescribir `loader.conf` después.
Instancia nueva en `instances:` si hace falta config; si no, módulo directo.

### D. `amicachy-preflight` (opcional, mínimo en F4)
Chequeos: espacio libre suficiente, detección de SO existente para avisar al usuario.
Puede ser un `contextualprocess`/`shellprocess` simple o diferirse. **No bloqueante
para el dual-boot básico**; valorar si entra en F4 o se pospone.

## Archivos

**Nuevos**
- `pkg/calamares-config-amicachy/files/usr/lib/calamares/modules/amicachy-foreign-os/{module.desc,main.py}`
- (opcional) `.../modules/amicachy-foreign-os.conf` (vendors conocidos, títulos)

**Modificados**
- `pkg/calamares-config-amicachy/files/etc/calamares/modules/partition_amicachy.conf` (modos + reuso ESP)
- `pkg/calamares-config-amicachy/files/etc/calamares/settings.conf` (+ amicachy-foreign-os en exec)
- `pkg/calamares-config-amicachy/PKGBUILD` → **bump pkgrel** (gotcha #4: si no, la ISO usa el caché)

**Reutilizar**
- `pkg/.../amicachy-postinstall/main.py` — patrón del módulo Python (loader entries)
- `dev/dualboot-vm/` — harness de test (baselines Debian+Win11 ya construidas)

## Verificación (T2 + T3)

Build (igual que F3): `build_amiberry.sh` + `build_amicachy_base.sh` +
`build_calamares_config.sh` + `build_calamares_compat.sh` + `build_target_rootfs.sh`
→ `sudo build_iso.sh --cpu-arch v3`. (amicachy-base/target.sfs/compat no cambian si
solo tocas calamares-config; basta rebuild de calamares-config + ISO.)

- **T3 (otro Linux)**: `dev/dualboot-vm/scripts/run-test.sh --baseline debian12-ext4-grub
  --iso out/<iso>`. Instalar AmiCachy en modo *alongside* (hueco libre), reusar ESP.
  Tras instalar:
  - `sudo verify-untouched.sh --baseline debian12-ext4-grub --overlay overlays/...` →
    **las particiones de Debian deben salir sin cambios** (la ESP puede cambiar SOLO
    por los ficheros nuevos de AmiCachy; root de Debian intacto).
  - Arrancar el overlay: systemd-boot muestra **Classic 68k + Asset Manager + Debian**.
    Arrancar Debian desde el menú funciona; arrancar Classic 68k → Amiberry+AROS.
- **T2 (Windows)**: igual con `--baseline win11-ntfs`. Verificar que la partición NTFS
  de Windows queda intacta, la ESP se reusa (Windows arranca desde el menú).
- Arranque del sistema instalado: usar `tools/boot_installed.sh` adaptado al overlay,
  o arrancar el overlay con run-test.sh sin ISO.

## Riesgos / notas
- ⚠️ **ESP reuse es el riesgo nº1**: si Calamares reformatea la ESP, Windows deja de
  arrancar. Verificar con verify-untouched en cada iteración. Puede requerir tocar
  `partition.conf` (no marcar la ESP para formatear) o un preflight que la proteja.
- **os-prober**: en T1 lo vimos fallar (irrelevante); en F4 **sí** importa si se
  quisiera la vía GRUB, pero como usamos **sd-boot + foreign-os propio**, os-prober NO
  es nuestro mecanismo. Ignorarlo.
- **Gotcha #5 (skel)**: si en dual-boot NO se monta AMIGADATA bajo /home/amiga, el
  problema del skel-no-copiado podría no darse — pero `amicachy-postinstall` ya copia
  skel incondicionalmente, así que cubierto.
- **Gotcha #1 (calamares stale)** y **#4 (pkgrel)** siguen vigentes.
- **Calamares stale podría arreglarse upstream** entre sesiones → si `cachyos-calamares`
  se reconstruye, quitar `calamares-compat-libs` (ver gotcha #1).
