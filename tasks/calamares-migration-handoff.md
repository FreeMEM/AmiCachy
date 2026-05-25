# Handoff: migración del instalador a Calamares

> **Estado al inicio de la nueva sesión** (2026-05-23). Lee esto entero antes de hacer nada.
> El usuario reinició Claude Code desde `/home/freemem/Projects/AmiCachy/` (la sesión anterior arrancó en otro proyecto, que causaba que los prompts de permiso mencionaran el path equivocado).

---

## TL;DR

Vamos a sustituir el instalador PySide6 actual (`tools/installer/`) por **Calamares con branding Amiga**, en una migración progresiva (no big-bang). Hay un plan de 10 fases ya validado por el usuario. F1 y F2.a están hechas; el smoke test E2E de F2.a quedó interrumpido por el lío de paths del prompt de permiso. **Siguiente acción concreta**: ejecutar el smoke test.

---

## Por qué migramos

El instalador PySide6 actual (`tools/installer/backend.py` línea 281) hace `wipefs --all --force` sobre el disco completo. **Destruye cualquier SO previo**. El usuario quiere soportar dual-boot (preservar Windows / otro Linux ya instalado), y reescribir esa lógica a mano sobre el wizard PySide6 es más trabajo que adoptar Calamares, que ya tiene módulos probados de partitioning, ESP reuse y bootloader.

**Identidad AmiCachy a preservar**:
- `systemd-boot` (no GRUB) — los perfiles con `amiprofile=` en el cmdline son la API contractual de `amilaunch.sh`
- Estética Workbench/Boing Ball
- Slideshow durante la instalación
- Páginas custom: Hardware Audit (benchmark CPU para PPC), Profile Select (68k/PPC/Dev/AssetMgr), Add-Ons (Asset Manager catalog)

---

## Decisiones cerradas (F0)

| # | Decisión | Razón |
|---|---|---|
| 1 | **Payload = squashfs precompilado + Calamares `unpackfs`** (no `pacstrap`) | Instalación 5-10× más rápida, reproducible, sin red obligatoria |
| 2 | **`systemd-boot` con módulo Python custom `amicachy-foreign-os`** para detectar Windows + otros Linux y añadir entradas chainload (no migrar a GRUB) | Preserva la identidad AmiCachy (perfiles `amiprofile=`) |
| 3 | **Config de Calamares como paquete `pkg/calamares-config-amicachy/`** (no suelta en `archiso/airootfs/etc/`) | Versionable, instalable, testeable aislada |
| 4 | ~~**Retirar `amicachy-copy-roms` en esta migración**~~ ✅ hecho (2026-05-23) | Asset Manager acepta ahora `.rom`/`.key`/`.bin` con layout `kickstart-rom`. Deuda técnica `MASTER_PLAN.md §5` resuelta. |
| 5 | **Cmdline del live como canónico** para las entradas systemd-boot generadas (`loglevel=0` + silenciadores), no el de `resources.py` (`loglevel=3`) | Experiencia "electrodoméstico" más limpia |

---

## Hallazgo estructural del inventario

**~80% de lo que hoy hace `configure_system()` (200 LOC) no debe hacerlo Calamares; debe ir empaquetado en el squashfs**. Esto requirió crear una tarea nueva (F3.0): un paquete `pkg/amicachy-base/` que incluya todos los scripts `amicachy-*` + configs (PAM cage, limits RT, autologin TTY1, labwc, /etc/skel, plymouth amicachy, perf service, mkinitcpio.conf, UAE configs, pacman+mirrorlists CachyOS). Bloquea F3.

---

## Plan de 10 fases (estado actual)

| ID | Fase | Estado | Notas |
|---|---|---|---|
| F1 | Inventario de migración Calamares | ✅ COMPLETADO | Entregable: `docs/calamares-migration-inventory.md` (515 líneas, ya escrito) |
| F2.a | Scaffolding VM dualboot | ✅ COMPLETADO (2026-05-23) | Entregable: `dev/dualboot-vm/`. Smoke test E2E con ISO live: pasa |
| F2.b | Baseline Debian (ext4 + GRUB-EFI) | ✅ COMPLETADO (2026-05-24) | Entregable: `baselines/debian12-ext4-grub.qcow2` (~1.8 GB, Debian 13.5.0 — el slot mantiene el nombre "debian12" por historia). Build automatizado en ~3 min con `scripts/build-baseline-debian.sh` (~700 MB ISO cacheada). Smoke test standalone: boot E2E hasta login prompt OK |
| F2.c | Baseline Windows 11 (NTFS + ESP) | ✅ COMPLETADO (2026-05-24) | Entregable: `baselines/win11-ntfs.qcow2` (~13 GB, Win11 25H2 Spanish, cuenta tester/tester). Build **semi-manual**: `scripts/build-baseline-windows.sh` automatiza descarga/virtio/remaster ISO no-prompt + fases specialize/oobeSystem, pero 25H2 (SetupPrep.exe nuevo) ignora autounattend en la fase windowsPE → ~5 clicks manuales en clave/edición/partición. Ver [[project_win11_baseline_autounattend]] |
| F3.0 | Paquete `amicachy-base` | ⏳ pendiente | **Bloquea F3**. Empaquetar todo lo que hoy escribe `configure_system()` |
| F3 | Esqueleto Calamares (happy path T1) | 🔒 bloqueada por F1, F2.a, F3.0 | Paquete `pkg/calamares-config-amicachy/` + módulos estándar + cambio de autostart live |
| F4 | Dual-boot real (T2, T3) | 🔒 bloqueada solo por F3 (F2.b/F2.c ✅) | Módulos custom `amicachy-foreign-os`, `amicachy-preflight`, `amicachy-postinstall.profiles`. Baselines Debian+Win11 ya disponibles para overlays |
| F5 | Branding Workbench/Amiga | ⏳ pendiente, paralelizable | QML branding + slideshow (port de `slideshow.py`) |
| F6 | Módulos AmiCachy custom | 🔒 bloqueada por F3 | `amicachy-hardware`, `amicachy-profiles`, `amicachy-addons` (QML) + `amicachy-postinstall` (Python) |
| F7 | Matriz completa T1–T6 | 🔒 bloqueada por F4, F6 | Validar con `verify-untouched.sh` |
| F8 | Switchover y cleanup | 🔒 bloqueada por F7 | Mover `tools/installer/` → `tools/installer-legacy/`, ISO final |
| — | Retirar `amicachy-copy-roms` | ✅ COMPLETADO (2026-05-23) | Deuda técnica (decisión 4) resuelta — Asset Manager acepta `.rom`/`.key`/`.bin` |

---

## Lo que ya está en disco (entregables F1 + F2.a)

### F1 — Inventario
- **`docs/calamares-migration-inventory.md`** (515 líneas): mapeo función a función de `backend.py`/`workers.py`/`pages.py` clasificado en "Calamares cubre / migrar / descartar". Incluye contrato `amilaunch`/`amiprofile=` a preservar, diferencias live vs instalado, riesgos identificados y lista de 5 módulos Calamares custom a desarrollar.

### F2.a — Scaffolding VM dualboot
```
dev/dualboot-vm/
├── .gitignore
├── README.md                                    (146 líneas)
├── ovmf/
│   ├── OVMF_CODE.4m.fd → /usr/share/edk2/x64/OVMF_CODE.4m.fd
│   └── OVMF_VARS-template.4m.fd                 (528 KB, copia limpia)
├── baselines/
│   ├── .gitkeep
│   └── empty-50g.qcow2                          (193 KB sparse, creado para smoke test)
├── overlays/.gitkeep
├── logs/.gitkeep
└── scripts/
    ├── run-test.sh                              (7.8 KB) ✓ sintaxis OK + --help OK
    ├── snapshot-reset.sh                        (2.7 KB) ✓ sintaxis OK
    └── verify-untouched.sh                      (5.9 KB) ✓ sintaxis OK
```

**Cómo funciona `run-test.sh`** (resumen, ver README para detalle completo):
- Crea overlay qcow2 backed por el baseline (baseline nunca se toca)
- Copia OVMF VARS template (cada VM tiene fresh UEFI NVRAM)
- Lanza QEMU+KVM con virtio disk, virtio net (hostfwd :2222→:22), intel-hda, display gtk por defecto
- Streamea serial console a `logs/<run-id>.serial.log`
- Por defecto MANTIENE el overlay tras salida (`--discard` para borrar)
- `--no-overlay` es destructivo (solo para construir baselines, F2.b/F2.c)

### Decisiones técnicas internas de F2.a
- OVMF 4MB (no 2MB), variante no-SecureBoot (`OVMF_CODE.4m.fd` no `OVMF_CODE.secboot.4m.fd`)
- Sin bridge, networking user-mode con port forward para SSH
- `verify-untouched.sh` requiere sudo (qemu-nbd carga módulo nbd)
- Boot order default `dc,menu=on`: CD primero (install), disco después (post-install reboot)

---

## Próxima acción concreta

**Ejecutar smoke test E2E de F2.a** con un disco vacío y la ISO/IMG más reciente. Comando exacto:

```bash
/home/freemem/Projects/AmiCachy/dev/dualboot-vm/scripts/run-test.sh \
    --baseline empty-50g \
    --iso /home/freemem/Projects/AmiCachy/out/amicachy-pendrive-2026.05.18.img \
    --display none --discard -- -daemonize
```

Después de lanzarlo:
1. Esperar ~20 s para que arranque OVMF + isohybrid
2. Verificar proceso QEMU vivo (`pgrep -a qemu-system-x86_64`)
3. Inspeccionar `logs/<run-id>.serial.log` para confirmar boot sin pánico
4. Matar QEMU (`pkill qemu-system-x86_64` o vía monitor socket)

Nota: el `.img` es ISO 9660 + MBR híbrido ("isohybrid"), por eso funciona como `-drive media=cdrom` sin ajustar el script.

Si el smoke test pasa: marcar F2.a definitivamente cerrada y elegir siguiente paso.

---

## Tareas tras el smoke test (en orden recomendado)

| Cuando hagas... | Bloqueas/desbloqueas... |
|---|---|
| F2.b (baseline Debian, ~1 día) | Junto con F2.c desbloquea F4 |
| F2.c (baseline Windows, ~1 día) | Junto con F2.b desbloquea F4 |
| F3.0 (paquete amicachy-base) | Desbloquea F3 |
| F5 (branding QML) | Paralelizable, no bloquea nada |

Si quieres mostrar avance rápido al usuario, F3.0 + F5 son buenas piezas para hacer en paralelo mientras esperas a que F2.b/F2.c maduren.

---

## Riesgos pendientes (de `docs/calamares-migration-inventory.md §9`)

1. Calamares `bootloader` puede sobrescribir `loader.conf` antes de que corra el módulo custom de perfiles → orden de módulos en `settings.conf` debe ser estricto
2. Calamares `partition` puede reemplazar ESP existente en dual-boot → validar `efiSystemPartition: /boot/efi` en T2/T3
3. `amilaunch.sh` espera scripts en `/usr/bin/` → `amicachy-base` debe instalar ahí

---

## Convenciones que ya guardé en memoria del proyecto

- No `Co-Authored-By:` en commits (ya estaba)
- Email `devel@freemem.space` (ya estaba)
- No mascar `plymouth-quit{,-wait}.service` (ya estaba, ojo al regenerar configs)
- Mantener `agetty` autologin para el user `amiga` (no migrar a systemd PAMName=login)

Estas viven en `~/.claude/projects/-home-freemem-Projects-AmiCachy/memory/` y se cargan automáticamente.
