# 02 — Compositor y escritorio (Workbench propio)

Cubre: elección de compositor (Cage vs Smithay), arquitectura de
`amicachy-compositor`, el escritorio AmiCachyShell y el sistema de Preferencias.

## 1. Compositor: Cage vs Smithay

### Cage (usado actualmente para Amiberry/FS-UAE)

- Compositor Wayland minimalista, filosofía "kiosk": una sola app fullscreen, sin
  gestión de múltiples ventanas/workspaces.
- Perfecto para Amiberry (single fullscreen app).
- **Insuficiente para AmiCachy-HLE:** no puede gestionar simultáneamente ventanas HLE
  (Musashi) + apps Linux nativas.

Niri/Hyprland/Sway son compositores completos de uso diario (tiling, animaciones…) —
tampoco es lo que se necesita aquí.

### Smithay (recomendado para `amicachy-compositor`)

- Librería Rust de "bloques de construcción" para compositores Wayland (no es un
  compositor en sí; análogo a Django para web apps).
- Módulos principales: `backend` (sesión, stack gráfico, input) y `wayland` (protocolo).
- Construido sobre `calloop` (event loop por callbacks): permite estado mutable
  centralizado sin `Arc<Mutex<T>>`.
- Soporta protocolos core/extendidos, libseat, tablets, XWayland (opcional), DRM/KMS,
  multi-GPU, libinput.
- Compositores de referencia para aprender:
  - **smallvil:** mínimo, educativo, pocas centenas de líneas (punto de partida).
  - **anvil:** completo, multi-GPU, XWayland, múltiples backends (Udev, Winit, X11) —
    mirar para la parte DRM/KMS.

### Arquitectura resultante

```
Linux kernel
    │
    ▼
DRM/KMS + libinput
    │        │
    └─Smithay┘
        │
        ▼
  amicachy-compositor (Rust)
    ├── calloop event loop
    ├── Space (smithay::desktop)
    │   ├── Ventanas HLE (Musashi)
    │   ├── Ventanas Wayland nativas
    │   └── Decoraciones estilo Workbench (renombrar branding)
    └── GLES/wgpu renderer
```

**Lo que Smithay ya resuelve:** protocolo Wayland completo, DRM/KMS (encaja con la
detección de GPU ya existente en `amilaunch.sh`), input vía libinput,
superficies/subsuperficies, multi-monitor.

**Lo que hay que implementar encima:** layout visual estilo Workbench (iconos, drawers,
posicionamiento de ventanas), decoraciones de ventana estilo Amiga, integración con
Musashi (ventanas HLE como superficies Wayland alimentadas por el framebuffer de
Intuition), menú y sistema de iconos.

**Cage se mantiene** para los modos Amiberry/QEMU existentes (sigue siendo perfecto
ahí). El modo HLE arranca su propio compositor basado en Smithay en lugar de Cage.

### Wayland vs XWayland

- **Wayland nativo:** la app habla el protocolo directamente (wgpu, SDL2 con backend
  Wayland, GTK4, Qt6, apps modernas).
- **XWayland:** capa de compatibilidad solo para apps que hablan X11 (legacy, GTK2/Qt4).
- `amicachy-desktop` y las ventanas HLE (wgpu) son Wayland nativo por diseño.
- **Recomendación:** Wayland nativo por defecto; XWayland como paquete **opcional**
  activable por el usuario (Cage soporta compilarse con opción xwayland).

## 2. Workbench: reimplementación propia vs apps Linux

**Opción A — Workbench como frontend de apps Linux** (Thunar, mpv, etc. con theming
Amiga, estilo Dank Material Shell/Cairo-Dock):

- Rápido de implementar.
- **Problema fatal:** Musashi/binarios 68k esperan hablar con exec/dos/Intuition, no con
  GTK/Qt. Dos mundos sin puente.

**Opción B — Sistema propio completo desde cero** (screens, windows, icons, drawers —
semántica AmigaOS real; apps Linux como ventanas "de segundo ciudadano", al estilo
MorphOS Ambient):

- Coherencia total, pero enormemente ambicioso (AROS lleva décadas en esto).

**Recomendación: Opción B con alcance limitado.** `amicachy-compositor` (Smithay)
gestiona **dos tipos de ventana**:

- **Ventanas HLE** (binario 68k vía Musashi) → gestionadas por `amicachy-intuition`.
- **Ventanas Linux nativas** (Wayland nativo, opcionalmente XWayland) → decoradas con
  estilo Amiga "por fuera".

```
┌─────────────────────────────────────────────────────┐
│ AmiCachyShell (Workbench propio)                    │
│  ┌────────────────┐   ┌─────────────────────────┐   │
│  │ Ventana HLE    │   │ Ventana Linux nativa    │   │
│  │ (68k/Musashi)  │   │ (terminal, editor, …)   │   │
│  └────────────────┘   └─────────────────────────┘   │
│  Iconos, drawers, menú — semántica AmigaOS          │
└─────────────────────────────────────────────────────┘
```

### Orden de implementación sugerido

1. Shell visual: fondo, iconos, menú Amiga, decoración de ventanas estilo WB.
2. Integración de apps Linux nativas (Wayland nativo; XWayland opcional).
3. Ventanas HLE: primer binario 68k corriendo en el shell.
4. Sistema de Preferencias declarativo.
5. GadTools y ReAction sobre Intuition/BOOPSI (es lo que emite DASH; ver
   [01-ejecucion-y-kernel.md](01-ejecucion-y-kernel.md) §1).
6. MUI (`amicachy-mui`), al final — compatibilidad con software clásico externo.

## 3. Sistema de configuración (no estilo GNOME/dconf)

Fichero declarativo simple, p. ej. `~/.amicachy/prefs.toml`:

```toml
[workbench]
screen_mode = "1920x1080x32"
backdrop = "blue"  # o ruta a imagen IFF

[fonts]
system = "Topaz"
screen = "Diamond"

[palette]
# paleta clásica o extendida RTG

[[apps.drawer]]
name = "Utilities"
icon = "drawer.info"
items = ["Shell", "Calculator", "VSCode"]
```

Cada categoría de Preferencias es un ejecutable separado, como en el Workbench original
("Prefs"). Las preferencias persistentes a nivel de sistema viven en `ENVARC:` (ver
[04-filesystem-assigns-permisos.md](04-filesystem-assigns-permisos.md) y
[05-arranque-y-shell.md](05-arranque-y-shell.md)).
