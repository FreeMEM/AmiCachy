# 05 — Arranque: startup-sequence, ciclo de boot y shell

Cubre: la cadena de arranque completa, units de systemd, `amicachy-init`,
startup-sequence/user-startup, `LoadWB`, `amicachy-shell`, preferencias persistentes y
apagado.

> **Revisión de arranque.** Al pasar `amicachy-hle` a escritorio multi-distro
> ([09-escritorio-independiente.md](09-escritorio-independiente.md) §3), el camino de
> arranque por defecto en una distro genérica es como **sesión Wayland** lanzada por el
> display manager (`.desktop` en `/usr/share/wayland-sessions/`), no por units de systemd
> propias. La cadena con units que se describe aquí sigue siendo válida para el arranque
> tipo *appliance* de la ISO de AmiCachy (boot directo a `amicachy-desktop` sin greeter).
> Las rutas `/opt/amicachy` de los ejemplos se trasladan al layout FHS/XDG del doc 09.

## 1. Estructura clásica de AmigaOS

- `S:startup-sequence` → script principal de arranque.
- `S:user-startup` → personalizaciones del usuario (no tocar el principal).

En AmiCachy, el "ejecutor" de estos scripts es `amicachy-dos`.

## 2. Cadena de arranque completa

```
BIOS/UEFI
    │
systemd-boot (ya existe en AmiCachy)
    │
Plymouth (logo AmiCachy)
    │
systemd (CachyOS base)
    │
amicachy-early.service    ← monta tmpfs, prepara /run/amicachy
    │
amicachy-assigns.service  ← inicializa AssignTable
    │
amicachy-desktop          ← proceso principal (Smithay + HLE)
    │
startup-sequence          ← ejecutado por amicachy-dos
    │
Escritorio AmiCachy visible
```

## 3. Unit de systemd — amicachy-early.service

```ini
[Unit]
Description=AmiCachy early environment
Before=amicachy-desktop.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/amicachy/Native/bin/amicachy-init
User=amiga

[Install]
WantedBy=amicachy-desktop.service
```

`amicachy-init` (Rust) hace tres cosas (equivalente exacto a lo que hace AmigaOS real
al arrancar):

```rust
fn main() {
    // 1. Monta RAM: como tmpfs
    mount("tmpfs", "/run/amicachy", "tmpfs", MS_NOEXEC, "size=256M");

    // 2. Crea estructura de RAM:
    fs::create_dir_all("/run/amicachy/env").unwrap();
    fs::create_dir_all("/run/amicachy/tmp").unwrap();

    // 3. Copia ENV: desde ENVARC: (persistente → volátil)
    copy_dir(
        "/opt/amicachy/System/Prefs/Env-Archive",
        "/run/amicachy/env"
    );
}
```

## 4. Startup-Sequence (ejemplo)

```
; AmiCachy Startup-Sequence
; No editar - usar User-Startup para personalizaciones

; Asignar directorios estándar
Assign >NIL: C: SYS:C
Assign >NIL: S: SYS:S
Assign >NIL: LIBS: SYS:Libs
Assign >NIL: DEVS: SYS:Devs
Assign >NIL: FONTS: SYS:Fonts
Assign >NIL: T: RAM:T
Assign >NIL: ENV: RAM:Env
Assign >NIL: ENVARC: SYS:Prefs/Env-Archive

; Arrancar subsistemas
Run >NIL: amicachy-audio        ; Paula -> PipeWire
Run >NIL: amicachy-input        ; libinput -> input.device
Run >NIL: amicachy-net          ; bsdsocket.library

; Cargar fuentes del sistema
LoadFont >NIL: FONTS:Topaz/8
LoadFont >NIL: FONTS:Diamond/8

; Leer preferencias
GetEnv Workbench/ScreenMode >ENV:T/screenmode

; Ejecutar personalizaciones del usuario
Execute S:User-Startup

; Arrancar el escritorio
LoadWB
```

Cada comando (`Assign`, `Run`, `Execute`, `LoadWB`…) lo implementa `amicachy-dos` como
comando de `C:`, igual que en AmigaOS real.

## 5. LoadWB — punto de arranque del escritorio

```rust
// C:/LoadWB implementado en amicachy-dos
pub fn load_wb(args: &[&str]) -> Result<()> {
    // Señala a amicachy-desktop que el startup ha terminado
    ipc::send(DesktopIpc::StartupComplete {
        screen_mode: env::get("Workbench/ScreenMode"),
        backdrop:    env::get("Workbench/Backdrop"),
    })?;
    Ok(())
}
```

Hasta `LoadWB`, el compositor solo muestra Plymouth. Al recibir `StartupComplete`,
aparece el escritorio (misma transición visual que AmigaOS real).

## 6. User-Startup

Personalizaciones del usuario; nunca tocar el script principal:

```
; S:User-Startup

; Añadir mis programas al path
Assign >NIL: Work: User:Documents
Assign >NIL: Music: User:Music

; Variables personales
SetEnv Editor "SYS:C/Ed"
SetEnv Browser "Storage:Programs/IBrowse/IBrowse"

; Programas que arrancan con el sistema
Run >NIL: Storage:Programs/Dopus5/DOpus
```

`acp install` puede añadir líneas a User-Startup automáticamente (con permiso/diálogo
al usuario) cuando un paquete necesita arrancar al inicio.

## 7. Shell de AmiCachy (amicachy-shell)

Binario nativo x86 que implementa la **sintaxis del shell de AmigaOS** (NewShell), no
bash/zsh:

```
1.AmiCachy> Dir SYS:C
1.AmiCachy> Copy Work:fichero TO RAM:
1.AmiCachy> Run >NIL: Storage:Programs/DOpus5/DOpus
1.AmiCachy>
```

`Dir` en lugar de `ls`, `Copy` en lugar de `cp`, `Delete` en lugar de `rm`, pipes con
`|`, redirección con `>`/`>>`, etc. Por debajo traduce a syscalls Linux, pero el usuario
ve un shell AmigaOS. Si quiere bash, abre una terminal Linux explícita desde el menú de
herramientas (no es el default).

## 8. Preferencias persistentes (sistema ENV completo)

```
ENVARC:
├── Workbench/
│   ├── ScreenMode      ← "1920x1080x32"
│   ├── Backdrop        ← "LIBS:backdrops/amicachy.iff"
│   └── WBPattern       ← patrón del fondo
├── Sys/
│   ├── NoCapsLock      ← existe = feature activa
│   └── Language        ← "español"
├── Font/
│   ├── screen.font     ← "Diamond/8"
│   └── system.font     ← "Topaz/8"
└── amicachy/
    ├── compositor.prefs
    └── sound.prefs
```

Cada fichero: texto plano o binario IFF según el tipo. `amicachy-desktop` los lee al
arrancar vía `GetEnv`. Los paneles de Preferencias escriben vía `SetEnv` + `SaveENV`
(sincroniza `ENV:` → `ENVARC:`).

## 9. Tiempos de arranque estimados (hardware moderno, CachyOS)

| t | Evento |
|---|---|
| 0.0 s | UEFI → systemd-boot |
| 0.8 s | Plymouth visible (logo AmiCachy) |
| 1.2 s | amicachy-early: tmpfs montado, `ENV:` inicializado |
| 1.4 s | amicachy-desktop arranca: Smithay/DRM/KMS activo |
| 1.6 s | startup-sequence comienza |
| 1.8 s | Subsistemas audio/input/red arrancados |
| 2.0 s | `LoadWB` → escritorio visible |

~2 segundos de encendido a escritorio — comparable a un Amiga real con acelerador
rápido, más rápido que distros Linux convencionales.

## 10. Apagado

AmigaOS no tiene apagado formal; AmiCachy sí, para sincronizar `ENV:` → `ENVARC:`:

```
; S:shutdown-sequence
SaveENV                          ; ENV: -> ENVARC: (persistir)
amicachy-audio --quit            ; flush buffers de audio
amicachy-net --quit              ; cerrar conexiones
; systemd se encarga del resto
```

Diálogo visual al usuario:

```
┌───────────────────────────────┐
│                               │
│   ¿Apagar AmiCachy?           │
│                               │
│   [Apagar]  [Reiniciar]       │
│   [Cancelar]                  │
│                               │
└───────────────────────────────┘
```
