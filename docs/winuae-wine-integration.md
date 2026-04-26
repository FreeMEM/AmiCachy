# WinUAE + Wine en AmiCachy — Estudio de viabilidad

Fecha: 2026-02-15

## Motivaci&oacute;n

WinUAE tiene las mejores herramientas de debugging de cualquier emulador Amiga.
El objetivo es ofrecer WinUAE como emulador alternativo a Amiberry en AmiCachy,
seleccionable desde el Early Startup Control (F5).

## Features exclusivas de WinUAE para debugging

| Feature | WinUAE | Amiberry | FS-UAE |
|---------|--------|----------|--------|
| Debugger consola (m/d/t/w/f/o) | Shift+F12 | Compilado pero bloqueado en fullscreen | F12+D |
| Breakpoints + watchpoints con value match | Si | (bloqueado) | Si |
| DMA debugger visual (overlay ciclo a ciclo) | Si | No | No |
| Heat map de accesos a memoria | Si | No | No |
| GDB remote (TCP:2345) | Si (fork parcheado) | No | Si (uae-dap) |
| Frame profiler + flame graph | Si (vscode-amiga-debug) | No | No |
| Graphics debugger (replay blitter/copper) | Si (vscode-amiga-debug) | No | No |
| Copper debugger/trace | Si | (bloqueado) | Si |

El DMA debugger visual, heat map y frame profiler son **exclusivos de WinUAE**.

### Nota sobre Amiberry

Amiberry compila `debug.cpp` con `#define DEBUGGER`, pero el debugger est&aacute;
bloqueado por un guard en `activate_debugger()`:

```c
if (!is_interactive_console() || isfullscreen() > 0)
    return;  // silently aborts
```

Un parche para exponer el debugger v&iacute;a socket/pipe ser&iacute;a una alternativa
de bajo esfuerzo (sin Wine), pero no dar&iacute;a el DMA debugger visual ni el
frame profiler.

## Compatibilidad WinUAE + Wine

### Estado general

WinUAE funciona bajo Wine para emulaci&oacute;n b&aacute;sica (chipset, sonido, discos,
red) desde hace 15+ a&ntilde;os. Los problemas est&aacute;n en gr&aacute;ficos acelerados.

### WineHQ AppDB

Los datos est&aacute;n obsoletos (15+ a&ntilde;os):
- WinUAE 1.5: Platinum (Wine 1.0, 2008)
- WinUAE 2.0.1: Silver (Wine 1.1.38, 2010)
- No hay datos para versiones 3.x-6.x

### Versi&oacute;n recomendada

**WinUAE 5.3.0 (x86/32-bit)** como punto de partida:
- Moderno (buen emulaci&oacute;n), anterior al chipset rewrite de 6.0
- x86 es m&aacute;s fiable bajo Wine que x64
- Usar WINEPREFIX de 32 bits: `WINEARCH=win32 WINEPREFIX=~/.winuae wineboot`

### Modos gr&aacute;ficos

| Modo | C&oacute;mo funciona bajo Wine | Riesgo |
|------|-------------------------------|--------|
| GDI (b&aacute;sico) | Funciona sin problemas | Bajo |
| D3D11 (acelerado) | Via WineD3D (OpenGL) o DXVK (Vulkan) | Alto |
| DirectDraw (legacy, pre-5.x) | Eliminado en WinUAE 5.x | N/A |

**GDI mode es lo seguro** para empezar. Sin filtros/shaders pero funcional.

### Problemas conocidos

- **D3D11**: glitches al cambiar modos de pantalla, crashes al resize (Wine bug #30405)
- **D3D11 shaders/filtros**: memoria leak (arreglado en 6.0.x), no probado bajo Wine
- **GLXBadFBConfig**: en algunas combinaciones Mesa/driver. Fix: `MESA_GL_VERSION_OVERRIDE=4.5`
- **F12 settings popup**: bug hist&oacute;rico donde la ventana de settings se reabre en bucle al cerrar
- **RTG (Picasso96) bajo D3D11+Wine**: territorio no probado

### Sonido

- Funciona en pruebas b&aacute;sicas
- MIDI passthrough funciona bajo Wine (confirmado en foros amiga.org)
- Wine-staging tiene mejor resampling para sample rates bajos (relevante para Paula)

### Input

- Captura de rat&oacute;n: requiere `winecfg` "Automatically capture mouse in fullscreen"
- Linux puede detectar ratones como joysticks (`/dev/input/js*`): ajustar udev rules
- Gamepads: funcionan via DirectInput si permisos `/dev/input/event*` est&aacute;n bien

### Puerto serie

- WinUAE soporta COM ports y modo TCP/IP serial
- Bajo Wine: COM ports se mapean a `/dev/ttyS*` via `~/.wine/dosdevices/com1` symlink
- No hay tests p&uacute;blicos de serial bajo Wine+WinUAE
- bsdsocket.library (TCP/IP Amiga via host) funciona (Winsock &rarr; BSD sockets)

## Wine + Wayland/Cage

### Estado del driver Wayland de Wine

- Wine 9.22 (Nov 2024): driver Wayland habilitado en build por defecto
- Wine 10.0 (Ene 2025): activo por defecto, pero prefiere X11 si `$DISPLAY` existe
- Wine 10.3 (Mar 2025): soporte clipboard en driver Wayland

**Limitaci&oacute;n clave**: el driver Wayland nativo de Wine no soporta Vulkan,
lo que descarta DXVK. Solo funciona WineD3D (OpenGL).

### Arquitectura recomendada: XWayland dentro de cage

```
cage (compilado con -Dxwayland=true)
  └── XWayland (auto-spawned)
        └── Wine (driver X11 maduro)
              └── WinUAE
```

- Cage del paquete CachyOS soporta XWayland (dep opcional: `xorg-server-xwayland`)
- Wine detecta `$DISPLAY` de XWayland y usa su driver X11 (mucho m&aacute;s maduro)
- Cage forza fullscreen autom&aacute;ticamente
- DXVK funciona por esta v&iacute;a (X11 + Vulkan)

**Alternativa nativa Wayland**: forzar con `env -u DISPLAY wine app.exe` o
registry key `HKCU\Software\Wine\Drivers /v Graphics /d wayland`. Funciona
para GDI y OpenGL pero sin Vulkan/DXVK.

### Problemas conocidos con Wine + wlroots

- wlroots 0.19 rompi&oacute; API con 0.18: cage necesita estar sincronizado
- Regresi&oacute;n de rendimiento reportada en sway master (3 FPS vs 60 FPS, Feb 2024)
- Teclados no-QWERTY pueden tener problemas con driver Wayland nativo
- Ventanas transitorias/di&aacute;logos pueden comportarse raro en Wayland nativo (XWayland lo evita)

## Integraci&oacute;n con AmiCachy

### Flujo propuesto

```
Boot -> F5? -> Early Startup GUI
                 ├── Emulator: [x] Amiberry  [ ] WinUAE
                 └── [Use] / [Save]

amilaunch.sh:
  if emulator == winuae:
      run_winuae "$config"
  else:
      run_amiberry "$config"
```

### Cambios necesarios

| Componente | Cambio | Esfuerzo |
|------------|--------|----------|
| Paquetes sistema | `wine`, `xorg-server-xwayland` | Bajo |
| WINEPREFIX setup | Script de primer arranque o pre-baked en imagen | Bajo |
| WinUAE binario | Descargar .zip, extraer a `/usr/share/winuae/` | Bajo |
| `amilaunch.sh` | Nueva `run_winuae()`, selecci&oacute;n por variable | Bajo |
| Early Startup `menu.py` | Habilitar radio "WinUAE", guardar selecci&oacute;n | Bajo |
| `config.py` | Guardar/leer selecci&oacute;n de emulador | Bajo |
| Formato UAE | WinUAE lee .uae nativo (compatible) | Bajo |
| Gr&aacute;ficos GDI (MVP) | Forzar GDI mode en config WinUAE bajo Wine | Medio |
| Gr&aacute;ficos D3D11 | WineD3D o DXVK, testing extenso | Alto |
| GDB remote + vscode | Fork parcheado de WinUAE, exponer TCP:2345 | Medio-Alto |

### Estimaci&oacute;n de esfuerzo

| Fase | Alcance | D&iacute;as estimados | Riesgo |
|------|---------|---------------------|--------|
| MVP: GDI + debugger consola | Emulaci&oacute;n funcional + Shift+F12 | 3-4 | Medio |
| D3D11 acelerado | Filtros, shaders, RTG | +2-3 | Alto |
| GDB remote + vscode-amiga-debug | Debugging remoto completo | +2-3 | Medio-Alto |
| **Total completo** | | **7-10** | **Alto** |

## Alternativas evaluadas

### FS-UAE + uae-dap (alternativa nativa Linux)

- Nativo, sin Wine
- Debugger consola completo (F12+D)
- GDB remote via [uae-dap](https://github.com/grahambates/uae-dap) (Debian x64, macOS, Windows)
- Funciona con VSCode (DAP), NeoVim (nvim-dap), Emacs (dap-mode)
- **No tiene**: DMA debugger visual, heat map, frame profiler

### Parchear Amiberry

- Quitar guard de `activate_debugger()` en `src/debug.cpp`
- Exponer debugger via socket/pipe (ej: SIGUSR1 + named pipe)
- O a&ntilde;adir GDB RSP server (portar de fork WinUAE/FS-UAE)
- Esfuerzo menor que Wine pero sin features visuales

## Estrategia recomendada por fases

1. **Fase 1 (r&aacute;pida)**: Parchear Amiberry para desbloquear debugger via socket
2. **Fase 2 (media)**: A&ntilde;adir FS-UAE como emulador alternativo con GDB remote
3. **Fase 3 (completa)**: WinUAE + Wine en modo GDI para DMA debugger visual

## Referencias

- [WinUAE 6.0.2](https://www.winuae.net/2025/12/22/winuae-6-0-2/)
- [WinUAE debugger reference](https://www.amigacoding.com/index.php/WinUAE_debugger)
- [vscode-amiga-debug](https://github.com/BartmanAbyss/vscode-amiga-debug)
- [uae-dap](https://github.com/grahambates/uae-dap)
- [mcp-winuae-emu](https://github.com/axewater/mcp-winuae-emu)
- [Wine 10.0 Wayland](https://www.phoronix.com/news/Wine-10.0-Released)
- [Wine Bug #30405 (WinUAE D3D crash)](https://list.winehq.org/mailman3/hyperkitty/list/wine-bugs@winehq.org/thread/LTOXM37NMOWMXWXNQYBQLNMVK4MNRVEC/)
- [cnc-ddraw (DirectDraw reimpl)](https://github.com/FunkyFr3sh/cnc-ddraw)
- [DXVK](https://github.com/doitsujin/dxvk)
- [Cage kiosk compositor](https://github.com/cage-kiosk/cage)
- [wine-wayland (varmd)](https://github.com/varmd/wine-wayland)
- [Collabora: Wine Wayland driver](https://www.collabora.com/news-and-blog/news-and-events/a-wayland-driver-for-wine.html)
