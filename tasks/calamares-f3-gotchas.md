# F3 — gotchas resueltos durante el test T1 (2026-06-14)

El happy path T1 de Calamares se validó E2E (disco vacío → instalar → reboot →
systemd-boot `amiprofile=classic_68k` → Plymouth → autologin → amilaunch →
Amiberry+AROS). Por el camino aparecieron 6 problemas. Quedan documentados aquí
porque varios reaparecerán en F4 (dual-boot) y en cada rebuild.

## 1. `cachyos-calamares` stale → calamares no arranca (libs)  ⚠️ DEUDA VIVA
`cachyos-calamares 3.4.1-8` está compilado contra `yaml-cpp 0.8` y `boost 1.89`,
pero el repo CachyOS ya va por `0.9` / `1.91` sin reconstruir calamares →
`calamares: error while loading shared libraries: libyaml-cpp.so.0.8 /
libboost_*.so.1.89.0`. Las deps a nivel de paquete se cumplen, pero el soname no.
**Fix:** `pkg/calamares-compat-libs` shipea las libs viejas (yaml-cpp 0.8 + las 47
de boost 1.89) sacadas del Arch Linux Archive (sha256, sin binarios en git).
**Quitar** cuando upstream reconstruya cachyos-calamares (drop del paquete + su
línea en packages.x86_64 + el bucle de build_iso + el EXCLUDE de build_target_rootfs).

## 2. `build_target_rootfs.sh` — 5 sub-bugs de empaquetado (commit 8a8cea2)
- `repo-add` de CachyOS (reescrito en Rust) **panic si no se ejecuta desde el dir
  del repo** → `cd` al repo + nombres relativos.
- Copiaba TODOS los amiberry → coger solo el más reciente (re-procesaba duplicados).
- `amicachy-base` choca con bash/mkinitcpio/plymouth en `/etc` → instalarlo APARTE
  tras pacstrap con `pacman -U --overwrite`.
- `--overwrite '/etc/*'` no casa: pacman usa rutas **relativas** (sin barra) → usar
  `--overwrite "*"`; y comillas **dobles** (el bloque corre en `docker bash -c '...'`,
  las simples rompen el quoting → el shell del contenedor expande el glob).
- `backup=` de amicachy-base deja `mkinitcpio.conf`/`plymouthd.conf` como `.pacnew`
  (gana la versión por defecto) → aplicar los `.pacnew` tras instalar.

## 3. `unpackfs` falla en el live → desplegar con `unsquashfs` (commit 51ce0bc)
El `target.sfs` vive sobre el **overlayfs** (cowspace de archiso) y el kernel
**rechaza respaldar un loop device con un fichero en overlayfs** →
`mount -o loop: failed to set up loop device` (aunque haya loop devices libres;
diagnosticado en el live: loop cargado, /dev/loop* presentes, `losetup -f` OK).
**Fix:** sustituir el módulo `unpackfs` por un `shellprocess` que ejecuta
`unsquashfs -f -d ${ROOT} /usr/share/amicachy/target.sfs` (lee en espacio de
usuario, sin loop). squashfs-tools ya está en el live (dep de cachyos-calamares).

## 4. Caché de pacman — subir `pkgrel` SIEMPRE que cambien los ficheros
Reconstruir `calamares-config-amicachy` a la misma `1.0.0-1` hacía que mkarchiso
reinstalara la **copia vieja cacheada** (ni branding ni fixes entraban). El síntoma
era "mis cambios no aparecen en la ISO". **Regla:** bump de `pkgrel` en cada cambio
de los paquetes locales (calamares-config va por `-3`).

## 5. `/etc/skel` no se copia a `/home/amiga` → amilaunch no arranca (commit del fix)
AMIGADATA se monta en `/home/amiga/Amiga`, así que **`/home/amiga` ya existe** cuando
Calamares crea el usuario → `useradd -m` **no copia skel** si el home existe → falta
`~/.bash_profile` → la shell de login en tty1 no ejecuta amilaunch → cae a bash.
**Fix:** `amicachy-postinstall` copia `/etc/skel` a `/home/amiga` (sin pisar el dir
`Amiga`) + `chown amiga:amiga`. **Vigente** (pkgrel -8): AMIGADATA volvió como
partición por defecto, así que este gotcha sigue activo. Cualquier partición montada
bajo el home lo recrea.

## 6. Locale no generado + keymap de consola
Sin pacstrap no hay hook que ejecute `locale-gen` → el locale elegido (es_ES.UTF-8)
no existe → `setlocale: cannot change locale` en cada login. **Fix:**
`amicachy-postinstall` ejecuta `locale-gen`. **Pendiente menor:** el keymap de
*consola* (vconsole) sale `us` aunque se elija español — el teclado gráfico
(Amiberry/cage, vía xkb de Calamares) sí es correcto, así que es solo cosmético para
shells de mantenimiento. Workaround manual: `loadkeys es` + `KEYMAP=es` en
`/etc/vconsole.conf`.

## Otros (no bloqueantes)
- `EGL_BAD_ALLOC` en `eglQueryDevicesEXT` bajo cage headless → se recupera vía virgl.
- `os-prober cannot start` en el log de Calamares → irrelevante en T1 (disco vacío);
  vigilar en F4 (dual-boot, donde os-prober sí importa para detectar otros SO).
- **sshd del live no responde** (banner timeout) en QEMU → impide depurar por SSH;
  usar la terminal de fallback de amilaunch (cerrar Calamares) o el guest→host por
  `10.0.2.2` (abrir el puerto en el firewall del host).
