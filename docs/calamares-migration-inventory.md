# Inventario de migración del instalador a Calamares

> Estado: F1 del plan de migración Calamares.
> Fecha: 2026-05-23.
> Objetivo: mapear cada pieza del instalador PySide6 actual (`tools/installer/` + scripts en `archiso/airootfs/usr/bin/`) a una de tres categorías: **lo cubre Calamares de serie**, **hay que reimplementar como módulo Calamares**, **se descarta**. Sirve de hoja de ruta detallada para las fases F3–F6.

---

## 1. Resumen ejecutivo

| Bloque | Líneas | Calamares cubre | Migrar | Descartar |
|---|---:|---:|---:|---:|
| `backend.py` (ops disco/pacstrap/bootloader/chroot) | 732 | ~60% | ~25% | ~15% |
| `workers.py` (QThreads) | 311 | ~80% | ~15% (audit hw) | ~5% |
| `pages.py` (UI wizard) | 1101 | ~50% | ~40% (3 ViewModules QML) | ~10% |
| `hardware.py` + `tools/hardware_audit.py` | ~25 + ext | 0% | 100% (process module) | 0% |
| `resources.py` (constantes, BOOT_ENTRIES) | 75 | 0% | 100% (módulo amicachy-profiles) | 0% |
| `slideshow.py` + `theme.py` | ~220 | 0% (a QML branding) | 100% (assets) | 0% |
| Scripts `archiso/airootfs/usr/bin/amicachy-*` | varios | 0% | 0% (siguen en squashfs payload) | 0% |

**Módulos Calamares custom a desarrollar**: 5
- 1 ViewModule QML: `amicachy-hardware`
- 1 ViewModule QML: `amicachy-profiles`
- 1 ViewModule QML: `amicachy-addons`
- 1 Python process module: `amicachy-foreign-os`
- 1 Python process module: `amicachy-postinstall` (agrupa: roms, mac fallback, profiles loader entries, addons fetch)

**Paquete nuevo necesario**: `amicachy-base` (en `pkg/`) que ya incluya todo lo que hoy escribe `configure_system()` (PAM, autologin, labwc config, .bash_profile, AMIGA_DIRS, perf service, plymouth theme, scripts amicachy-*). Así Calamares solo despliega el squashfs y los módulos custom hacen lo específico de AmiCachy. Decisión clave: **mover trabajo de "post-install configuration" a "pre-built rootfs payload"**.

---

## 2. Inventario detallado de `backend.py`

| Función | LOC | Categoría | Reemplazo Calamares | Notas |
|---|---:|---|---|---|
| `CommandRunner`, `run_chroot` | 50 | Descartar | Helpers internos de Calamares (`libcalamares.utils.target_env_call`, logging vía `libcalamares.utils.debug`) | El patrón "stream stdout línea a línea con log a archivo" es nativo en Calamares. |
| `_write_file` | 4 | Descartar | `libcalamares.utils.write_text_file` | — |
| `_device_children` / `_unmount_device` / `release_install_target` | 70 | Descartar | `partition` module (KPMcore) | KPMcore desmonta y libera holders antes de modificar particiones. |
| `clear_filesystem_signatures` | 15 | Descartar | `partition` module (wipefs por debajo) | — |
| `format_ext4` | 13 | Descartar | `partition` module | Calamares soporta ext4/btrfs/xfs/f2fs/fat32 nativamente. |
| `recreate_partition` (in-place delete+create) | 45 | Descartar | `partition` modo "Replace a partition" | Calamares hace exactamente esto. |
| **`partition_disk` (wipefs + GPT + 3 particiones)** | 44 | **Descartar (peligroso)** | `partition.conf` con 4 modos | Esta función es la que destruye discos hoy. **Ver F4 del plan**. |
| `mount_filesystems` | 11 | Descartar | `mount` module + `partition` lo gestiona | — |
| `setup_pacman` (claves GPG CachyOS) | 9 | Migrar (al payload) | El squashfs incluye CachyOS keyring ya firmado | Se ejecuta en el build de la ISO, no en el instalador. |
| `read_package_list` / `run_pacstrap` | 23 | **Descartar** si vamos por `unpackfs`+squashfs (recomendado). Migrar a Python process module si conservamos pacstrap. | `unpackfs` module | **Decisión F0**: ir a squashfs precompilado. |
| `generate_fstab` (genfstab -L) | 7 | Descartar | `fstab` module | — |
| **`configure_system`** | 200 | **Mayoría a payload, parte a módulos** | Mezcla | Desglose abajo. |
| `_iter_rom_files` / `copy_rom_payload` | 50 | **Migrar** → módulo `amicachy-postinstall` (submódulo `roms`) | Python process module | Busca ROMs en `/run/archiso/bootmnt` y `/run/media/amiga`, copia a `/home/amiga/kickstarts/`. |
| **`install_bootloader`** | 46 | Split: `bootctl install` → Calamares `bootloader`; entradas de perfil → módulo custom | `bootloader` + `amicachy-postinstall.profiles` | Las entradas multi-perfil con `amiprofile=` son la identidad AmiCachy. |
| `install_addon` (runuser amiga + amicachy-fetch-asset) | 14 | Migrar → módulo `amicachy-postinstall` (submódulo `addons`) | Python process module | Itera `selected_addons` y llama al binario que ya vive en el sistema instalado. |
| `install_mac_fallback_bootloader` | 18 | Migrar → módulo `amicachy-postinstall` (submódulo `mac_fallback`) | Python process module | Copia `systemd-bootx64.efi` a `EFI/BOOT/BOOTX64.EFI` para que Apple lo encuentre. |
| `final_cleanup` / `emergency_cleanup` | 22 | Descartar | `umount` module | — |

### 2.1 Desglose de `configure_system` (línea 377-575)

| Bloque | Categoría | Destino |
|---|---|---|
| Timezone (`ln -sf /usr/share/zoneinfo/UTC /etc/localtime` + `hwclock --systohc`) | Calamares cubre | `locale` + `hwclock` modules (el usuario lo elige en el wizard) |
| Locale (`locale.gen` + `locale-gen` + `locale.conf`) | Calamares cubre | `localecfg` module |
| Hostname (`/etc/hostname` → "amicachy") | Calamares cubre | `hostname` module (con default `amicachy`) |
| Console (`vconsole.conf`) | Calamares cubre | `localecfg` + `keyboard` modules |
| Pacman config con repos CachyOS | Migrar (al payload `amicachy-base`) | `/etc/pacman.conf` + `/etc/pacman.d/*-mirrorlist` viven en el squashfs |
| Mirrorlists CachyOS | Migrar (al payload) | Igual |
| `useradd amiga ... -G wheel,audio,video,input` + `passwd -d` | Calamares cubre (con tweaks) | `users` module (configurar groups, autologin, sudo) |
| Autologin TTY1 (`getty@tty1.service.d/autologin.conf`) | Migrar (al payload) | Vive en `amicachy-base` como override systemd |
| RT priority limits (`limits.d/90-amiga-rtprio.conf`) | Migrar (al payload) | Vive en `amicachy-base` |
| PAM `/etc/pam.d/cage` | Migrar (al payload) | Vive en `amicachy-base` |
| Copia scripts `amilaunch.sh`, `start_dev_env.sh` | Migrar (al payload) | Ya viven en `archiso/airootfs/usr/bin/`; el paquete `amicachy-base` los empaqueta para el target |
| UAE configs (`a1200.uae`, `os41.uae`) | Migrar (al payload) | Vive en `amicachy-base` |
| `.bash_profile` (autolaunch amilaunch en tty1) | Migrar (al payload) | Vive en `amicachy-base` (en `/etc/skel/.bash_profile`) |
| Labwc config (`autostart`, `environment`, `rc.xml`) | Migrar (al payload) | Vive en `amicachy-base` (en `/etc/skel/.config/labwc/`) |
| `AMIGA_DIRS` (kickstarts, disks, hdf, os41/...) | Migrar (al payload) | En `/etc/skel/` |
| `chown -R amiga:amiga /home/amiga` | Calamares cubre | `users` module gestiona ownership |
| `systemctl enable NetworkManager` | Calamares cubre | `services-systemd` module |
| `amicachy-cpufreq-set` + `amicachy-performance.service` | Migrar (al payload) | Vive en `amicachy-base` con `WantedBy` ya activo en build |
| Plymouth theme `amicachy` | Migrar (al payload) | Theme vive en `amicachy-base`, `plymouthd.conf` también |
| `mkinitcpio.conf` con hook plymouth | Migrar (al payload) | El squashfs ya viene con el mkinitcpio.conf correcto |
| `mkinitcpio -P` (regenerar initramfs) | Calamares cubre | `initramfs` module |
| Symlinks `plymouth-start.service` / `plymouth-quit.service` (sin `*-wait*`) | Migrar (al payload) | Vive en `amicachy-base` |

**Hallazgo clave**: ~80% del trabajo de `configure_system` desaparece moviéndolo al payload (paquete `amicachy-base` que el squashfs ya incluya). El resto lo cubre Calamares estándar. Solo lo dinámico-por-usuario (timezone, locale, hostname, password) lo gestionan los módulos estándar de Calamares.

---

## 3. Inventario de `workers.py`

| Clase | LOC | Categoría | Reemplazo |
|---|---:|---|---|
| `InstallerState` (dataclass) | 25 | Descartar | Calamares usa `libcalamares.globalstorage` (KV global compartido entre módulos) |
| `HardwareAuditWorker` (QThread) | 30 | Migrar | Python process module + ViewModule QML para mostrar resultados |
| `DiskScanWorker` (QThread) | 117 | Descartar | `partition` module hace su propio scan (con KPMcore) y oculta el live device |
| `InstallWorker._do_install` (orquestador de 9 pasos) | 100 | Descartar | `settings.conf` define la secuencia; cada paso es un módulo |

---

## 4. Inventario de `pages.py` (síntesis del subagent)

| Página | LOC aprox | Categoría | Mapeo Calamares |
|---|---:|---|---|
| `WelcomePage` | 36 | Calamares cubre | `welcome` con branding custom (logo Amiga, color rojo) |
| `HardwareAuditPage` | 113 | Migrar | **ViewModule QML `amicachy-hardware`** + process module backend |
| `DiskSelectPage` (+ `DiskCard`) | 130 | Calamares cubre | `partition` (con 4 modos habilitados) |
| `ProfileSelectPage` | 112 | Migrar | **ViewModule QML `amicachy-profiles`** — checkboxes 68k/PPC/Dev + default + colorado según audit |
| `AddOnsPage` | 117 | Migrar | **ViewModule QML `amicachy-addons`** — catálogo `/usr/share/amicachy/asset-catalog.json` con doble consent (license + install) |
| `ConfirmPage` | 66 | Calamares cubre | `summary` module |
| `InstallPage` (con `SlideshowWidget`) | 79 | Calamares cubre | Calamares tiene `show.qml` en branding (slideshow nativo) |
| `FinishPage` | 49 | Calamares cubre | `finished` module |
| `ErrorPage` | 54 | Calamares cubre | Calamares gestiona errores nativamente |
| `InstallerWizard` (QStackedWidget orquestador) | 170 | Descartar | Calamares ES el wizard |

---

## 5. Scripts `archiso/airootfs/usr/bin/` — qué pasa con cada uno

| Script | Categoría | Destino tras migración |
|---|---|---|
| `amicachy-installer` | **Descartar** | Sustituido por `calamares` (autostart del live cambia) |
| `amilaunch.sh` | **Se queda intacto** | Empaquetar en `amicachy-base`. Es el dispatcher de perfiles, identidad AmiCachy. |
| `amicachy-amiberry-session` | Se queda | Empaquetar en `amicachy-base` |
| `amicachy-cpufreq-set` | Se queda | Empaquetar en `amicachy-base` |
| `amicachy-earlystartup` | Se queda | Empaquetar en `amicachy-base` |
| `amicachy-fetch-asset` | Se queda | El módulo `amicachy-addons` lo invoca vía `runuser amiga` |
| `amicachy-fix-mac-boot` | Se queda | Empaquetar en `amicachy-base` (post-install helper) |
| `amicachy-grow-data` | Se queda | Empaquetar en `amicachy-base` (crece partición DATA en primer boot) |
| `amicachy-link-host-assets` | Se queda | Empaquetar en `amicachy-base` |
| `amicachy-persistent-data` | Se queda | Empaquetar en `amicachy-base` |
| `amicachy-seed-assets` | Se queda | Empaquetar en `amicachy-base` |
| `amicachy-set-amiga-password` | Se queda | Empaquetar en `amicachy-base` |
| `amicachy-wifi-debug` | Se queda | Empaquetar en `amicachy-base` |
| `start_dev_env.sh` | Se queda | Empaquetar en `amicachy-base` |

> `amicachy-copy-roms` retirado (deuda técnica de `MASTER_PLAN.md` §5 resuelta). El Asset Manager acepta ahora `.rom`/`.key`/`.bin` directamente vía "Add asset → From local file" — copia plana a `~/Amiberry/roms/`, layout `kickstart-rom` (sin UAE config; Amiberry escanea el dir).

---

## 6. Contrato `amilaunch` / `amiprofile=` (a preservar palabra por palabra)

`amilaunch.sh` lee `amiprofile=<value>` del kernel cmdline y dispatcha la sesión post-login. Es **la API contractual** que el módulo `amicachy-postinstall.profiles` debe seguir generando idéntica.

### Perfiles válidos (en el sistema instalado)

| ID | Título systemd-boot | Sesión | Cmdline extra |
|---|---|---|---|
| `classic_68k` | `AmiCachy - Classic 68k` | `cage -- amiberry --config a1200.uae` (vía labwc-emulator) | `mitigations=off nowatchdog` |
| `ppc_nitro` | `AmiCachy - PPC Nitro` | `cage -- amiberry --config os41.uae` con `chrt -f 52` | `mitigations=off nowatchdog` |
| `dev_station` | `AmiCachy - Dev Station` | `labwc -s start_dev_env.sh` (VS Code + Amiberry) | — |
| `asset_manager` | `AmiCachy - Asset Manager` | `cage -- amicachy-fetch-asset gui` | — |
| `installer` | (solo en ISO live) | `cage -- amicachy-installer` | (no se instala en disco) |

### Cmdline canónico de cada entrada instalada

```
root=LABEL=AMICACHY rw quiet splash loglevel=0
rd.systemd.show_status=false rd.udev.log_priority=3 udev.log_priority=3
systemd.show_status=false fbcon=nodefer logo.nologo
vt.global_cursor_default=0
amiprofile=<PROFILE_ID>
[mitigations=off nowatchdog]            ← solo en classic_68k y ppc_nitro
nvidia-drm.modeset=1 nvidia-drm.fbdev=1
nouveau.modeset=0 module_blacklist=nouveau
```

### Divergencia detectada entre código actual y entries del live

`resources.py:BOOT_ENTRIES` usa **`loglevel=3`** mientras que `archiso/efiboot/loader/entries/*.conf` usa **`loglevel=0`** y añade varios silenciadores (`rd.systemd.show_status=false`, `systemd.show_status=false`, `fbcon=nodefer`, `logo.nologo`). El live es más estricto (más silencioso). 

→ **Decisión para el módulo `amicachy-postinstall.profiles`**: replicar el cmdline del live (más silencioso = mejor experiencia "electrodoméstico"), no el de `resources.py`. Documentar el cambio.

### Política `ALWAYS_INSTALL_ENTRIES`

`asset_manager` se instala **siempre**, aunque el usuario no lo seleccione. El módulo `amicachy-postinstall.profiles` debe preservar esto.

### Default entry

`loader.conf` usa `default <filename>` apuntando a la entrada del perfil que el usuario haya marcado como default. El módulo lo genera con `LOADER_CONF_TEMPLATE`.

---

## 7. Diferencias críticas live vs instalado

| Aspecto | Live (archiso) | Instalado (a generar por Calamares) |
|---|---|---|
| Path al kernel | `/%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux-cachyos` (archiso substituye) | `/vmlinuz-linux-cachyos` (en ESP montada en `/boot`) |
| Root | `archisobasedir=... archisolabel=...` | `root=LABEL=AMICACHY rw` |
| Entradas del live a NO generar en target | `00-install.conf`, `05-try-live-68k.conf`, `06-try-live-dev.conf` | (omitir) |
| Entradas a generar en target | `01-classic-68k.conf`, `02-ppc-nitro.conf`, `03-dev-station.conf`, `04-asset-manager.conf` | (según selección + `ALWAYS_INSTALL_ENTRIES`) |

---

## 8. Lista de entregables que salen de este inventario

Insumos para F3–F6:

1. **Paquete `amicachy-base`** (nuevo, en `pkg/amicachy-base/`): empaqueta todos los scripts `amicachy-*` + `amilaunch.sh`, configs PAM/limits/autologin/labwc/skel/plymouth/perf-service/UAE configs. Lo consume el squashfs (en archiso → packages.x86_64) y queda disponible en el sistema instalado.
2. **Paquete `calamares-config-amicachy`** (nuevo, en `pkg/calamares-config-amicachy/`): `settings.conf`, configs de módulos estándar, branding QML.
3. **Módulo QML `amicachy-hardware`** (en el paquete anterior, bajo `modules/`): port de `HardwareAuditPage` + `HardwareAuditWorker`. Llama a `tools/hardware_audit.py` (que sigue donde está).
4. **Módulo QML `amicachy-profiles`**: port de `ProfileSelectPage`.
5. **Módulo QML `amicachy-addons`**: port de `AddOnsPage` + lectura de `/usr/share/amicachy/asset-catalog.json`.
6. **Módulo Python `amicachy-foreign-os`** (clave para dual-boot): detecta Windows + otros Linux y genera entradas chainload en systemd-boot.
7. **Módulo Python `amicachy-postinstall`** (agrupa varios sub-jobs): `roms`, `mac_fallback`, `profiles` (loader entries con `amiprofile=`), `addons` (invoca `amicachy-fetch-asset`).
8. **Live ISO**: cambiar autostart del usuario `amiga` de `amicachy-installer` a `calamares`.

---

## 9. Riesgos identificados

| Riesgo | Mitigación |
|---|---|
| Calamares sobrescribe `loader.conf` con su default antes de que `amicachy-postinstall.profiles` corra | Configurar orden de módulos en `settings.conf`: `bootloader` antes que `amicachy-postinstall`; en `bootloader.conf` poner `installEFIFallback: false` y dejar que nuestro módulo termine de escribir. |
| Calamares `partition` reemplaza ESP existente en dual-boot | `efiSystemPartition: /boot/efi` + verificar que detecta y reusa la ESP del SO existente (test T2/T3 en F7) |
| Pacman keys de CachyOS no presentes en el target | Resuelto si vamos por squashfs payload (el rootfs ya viene con `/etc/pacman.d/gnupg/` poblado) |
| El usuario `amiga` debe tener exactamente UID 1000, groups específicos, password vacío | Configurar `users.conf` rigurosamente. Validar contra `archiso/profiledef.sh` (`["/home/amiga"]="1000:1000:750"`) |
| `mitigations=off nowatchdog` se omite en perfiles donde NO debe ir (dev_station, asset_manager) | Verificar en `amicachy-postinstall.profiles` con tests unitarios sobre cmdline generado |
| `amilaunch.sh` espera scripts en `/usr/bin/`; si el paquete `amicachy-base` cambia rutas, se rompe el live | Documentar y testear: `amicachy-base` debe instalar TODO en `/usr/bin/` |

---

## 10. Próximos pasos

- F2.a: Scaffolding VM dualboot (paralelizable, no depende de esto)
- F2.b/F2.c: Baselines Debian + Windows
- F3: Esqueleto Calamares + paquete `amicachy-base` + `calamares-config-amicachy`
- F4: Dual-boot + `amicachy-foreign-os`
- F5: Branding QML
- F6: Módulos custom (hardware, profiles, addons, postinstall)
- F7: Validación matriz T1–T6
- F8: Switchover + cleanup

> Retirada de `amicachy-copy-roms` ✅ completada — Asset Manager acepta `.rom`/`.key`/`.bin`, script y `.desktop` borrados, línea quitada de `archiso/profiledef.sh`.
