# AmiCachy-HLE — Documentación de ingeniería

> **Estado:** plan de futuro (fase de diseño). Fuente original de estas notas:
> [`docs/AmiCachy-HLE_Arquitectura.txt`](../AmiCachy-HLE_Arquitectura.txt).

## 1. Concepto

AmiCachy-HLE es un **modo de arranque alternativo** a los perfiles actuales basados en
Amiberry/FS-UAE. En lugar de emular el hardware completo (LLE), se reimplementa el
**contrato del sistema operativo AmigaOS** (HLE — High-Level Emulation):

```
Binario 68k compilado para AmigaOS
        │
        ▼
  Musashi (CPU core 68k, FFI desde Rust)
        │  JSR a offsets negativos de la jump table
        │  (ExecBase, DosBase, IntuitionBase, …)
        ▼
  Capa Rust: amicachy-exec, amicachy-dos, amicachy-intuition, …
        │
        ▼
  Linux syscalls / wgpu / cpal / libc sockets
```

**Precedentes conceptuales:** AROS (reimplementación source-compatible de AmigaOS 3.1),
WINE para Win32, Executor para Mac OS clásico 68k.

**Target realista:** aplicaciones (productividad, herramientas, software de desarrollo).
Los juegos que acceden directamente al hardware (copper/blitter) siguen siendo
territorio de Amiberry/FS-UAE. La diferencia clave frente a un emulador convencional:
Amiberry/FS-UAE emulan *todo* el hardware (Agnus, Denise, Paula…); AmiCachy-HLE emula el
*contrato del SO* — más eficiente, pero más difícil de hacer correcto.

## 2. Restricciones legales y de naming

- **Nota legal:** el leak del código fuente de AmigaOS 3.1 (finales de 2015, confirmado
  por Hyperion Entertainment) **NO debe usarse** como base de implementación, por riesgo
  de copyright y contaminación del "clean room". La API se reimplementa a partir de la
  NDK pública y documentación legal.
- **Naming:** por temas de copyright, **nunca** usar "Amiga"/"Workbench"/"Intuition"
  como nombre de marca o proyecto. Todo prefijado como AmiCachy:
  - `amicachy-compositor`
  - `amicachy-exec` (exec.library)
  - `amicachy-dos` (dos.library)
  - `amicachy-intuition` (intuition + graphics.library)
  - `amicachy-mui` (MUI)
  - `amicachy-shell`
  - `amicachy-desktop` (proceso principal)

## 3. Mapa de documentos

| Documento | Contenido |
|---|---|
| [01-ejecucion-y-kernel.md](01-ejecucion-y-kernel.md) | Capas de implementación, Musashi/FFI, multinúcleo, scheduler, tasks/señales/mensajes, modelo de memoria, protección de memoria |
| [02-compositor-y-escritorio.md](02-compositor-y-escritorio.md) | Cage vs Smithay, amicachy-compositor, Workbench propio, sistema de Preferencias |
| [03-perifericos-y-devices.md](03-perifericos-y-devices.md) | Audio/Paula, impresoras/CUPS, bsdsocket/TCP-IP, clipboard, mapa completo de devices |
| [04-filesystem-assigns-permisos.md](04-filesystem-assigns-permisos.md) | Assigns, árbol físico en `/opt/amicachy`, ENV/ENVARC, protection bits, modelo de usuarios |
| [05-arranque-y-shell.md](05-arranque-y-shell.md) | Cadena de boot, units systemd, startup-sequence, LoadWB, amicachy-shell, apagado |
| [06-dash-cross-target.md](06-dash-cross-target.md) | DASH como lenguaje cross-target (68k/x86_64/aarch64/wasm), libamicachy-intuition |
| [07-paquetes-y-repositorios.md](07-paquetes-y-repositorios.md) | Gestor `acp`, formato `.acz`, Aminet, repo overlay pacman, hosting |
| [08-jit-cpu-68k.md](08-jit-cpu-68k.md) | JIT para la CPU 68k (fase 2): Musashi interpretado vs Cranelift, trampolines jump table, niveles de JIT, roadmap |

## 4. Stack tecnológico (resumen)

- **Rust** para todo el proyecto, excepto Musashi (C maduro, vía FFI/bindgen).
- `musashi-sys` (bindgen) + `musashi-rs` (wrapper seguro).
- Crates de sistema: `amicachy-exec`, `amicachy-dos`, `amicachy-intuition`,
  `amicachy-graphics`, `amicachy-audio` (Paula).
- **Renderer:** wgpu (Wayland nativo, blitter como compute shaders); SDL2 como
  alternativa rápida inicial (renderer desacoplado, migrable).
- **Audio:** cpal (abstrae PipeWire/ALSA).
- **Input:** libinput vía Smithay.
- **Compositor:** Smithay (ver doc 02).

## 5. Roadmap de desarrollo

| Fase | Alcance | Hito demostrable |
|---|---|---|
| Mes 1–2 | `musashi-sys` + binario 68k de test + exec mínimo (AllocMem, tareas, señales) | Binario 68k ejecuta y llama a exec.library |
| Mes 3–4 | dos.library suficiente para CLI | Arranca una shell de AmigaOS |
| Mes 5–6 | Intuition básico sobre wgpu (ventanas, eventos, sin MUI) | Primera ventana HLE |
| Mes 7+ | Workbench/escritorio, MUI, Paula (audio) | Escritorio usable |

**Primer PR concreto sugerido:** `pkg/amicachy-hle/` con un `amicachy-desktop` mínimo
que arranca con Cage, abre una ventana wgpu azul Workbench y muestra el texto
"AmiCachy HLE — WIP" con fuente Topaz. Sin Musashi todavía: solo validar el pipeline de
build/PKGBUILD/boot entry/Cage.

## 6. Pendiente de decidir/explorar

- Estructura concreta del workspace de Cargo que une todas las piezas (`musashi-sys`,
  `amicachy-exec`, `amicachy-dos`, `amicachy-intuition`, `amicachy-compositor`,
  `amicachy-shell`, `amicachy-desktop`, `acp`, `amicachy-init`, …).
- Diseño del panel de Preferencias de Assigns.
- Contenido de `lib/amiga/` y el ejemplo "blixel" en el repo de DASH (para planificar el
  refactor `builtins/base.py` + `target_*.py`).
- Implementación en detalle de los callbacks de memoria de Musashi.
- PKGBUILD y entrada de boot (`amicachy-hle.conf` / `amicachy-hle.target`) para el nuevo
  modo, siguiendo el patrón de `pkg/amiberry/`.

## 7. Referencias

- AmiCachy: <https://github.com/FreeMEM/AmiCachy/>
- DASH: <https://github.com/FreeMEM/dash/>
- Musashi: core 68k en C, maduro — usar vía FFI/bindgen.
- Smithay: <https://github.com/Smithay/smithay> (compositores de referencia: *smallvil*
  para empezar, *anvil* como referencia completa DRM/KMS/XWayland).
- AROS: referencia de reimplementación source-compatible de AmigaOS 3.1 para x86.
- Leak de AmigaOS 3.1 (2015, confirmado por Hyperion): **no usar** como base de código.
