# 06 — DASH como lenguaje cross-target

Cubre: el estado actual de DASH, el objetivo multi-target (68k/x86_64/aarch64/wasm), el
"runtime problem" y `libamicachy-intuition` como pieza que une HLE y nativo.

## 1. Estado actual de DASH

- Repo: <https://github.com/FreeMEM/dash> (checkout local: `~/Projects/FreeMEMLang`).
- **D.A.S.H. — Development Amiga Synthesis Hub.**
- Pipeline: `.dash` → Parser (Lark) → AST → Analyzer → CodeGen → C → GCC
  (`m68k-amigaos-gcc`) → ejecutable Amiga.
- Sintaxis tipo Ruby/Python, tipos inferidos.
- Acceso directo a Intuition, Graphics, Sprites, Copper, Blitter, Audio, IFF, DOS, RTG,
  Double Buffering, FFI.
- Estructura: `compiler/` (`grammar.py`, `transformer.py`, `ast_nodes.py`,
  `analyzer.py`, `codegen.py`, `amiga_builtins.py`), `runtime/`, `lib/amiga/` (módulos
  `.dash`: intuition, graphics, blitter, copper, sprites, audio, iff, dos, rtg,
  doublebuf, memory), `examples/`, `blixel/` (programa de ejemplo completo: core, io,
  tools, ui), `tests/`, `docs/`.
- Genera C estándar → la cross-compilation es casi gratis: solo cambia el toolchain del
  target.

## 2. Objetivo

DASH debe poder generar también binarios nativos x86_64 y aarch64 indicando solo el
target (además de 68k/AmigaOS):

```
DASH source (.dash)
        │
        ▼
    DASH compiler
        │
        ├── --target=m68k-amigaos  → C → m68k-amigaos-gcc → binario 68k (HLE)
        ├── --target=x86_64-linux  → C → gcc/clang        → binario x86_64
        ├── --target=aarch64-linux → C → aarch64-linux-gcc → binario ARM64
        └── --target=wasm32        → C → emcc             → WebAssembly (futuro)
```

## 3. El "runtime problem"

Una app DASH que llama `OpenWindow()` necesita una implementación distinta según el
target. Opciones:

- **A) API unificada AmiCachy (RECOMENDADA para coherencia visual):** un runtime propio
  (`amicachy-intuition`) implementado para cada target (68k vía jump table HLE, x86
  nativo vía Rust/Wayland, wasm vía Canvas). Mismo aspecto en todos los targets
  (modelo tipo Flutter/JVM).
- **B) POSIX para targets nativos + toolkit solo en UI:** más simple, pero las apps no
  lucen igual entre plataformas.
- **C) Binarios "fat" / paquete `.acz` multi-arquitectura:**

  ```toml
  # MANIFEST.toml
  [[binary]]
  arch = "m68k"
  file = "bin/mi-app.68k"
  [[binary]]
  arch = "x86_64"
  file = "bin/mi-app.x86_64"
  [[binary]]
  arch = "aarch64"
  file = "bin/mi-app.aarch64"
  ```

  `acp install` descarga el `.acz` e instala el binario correcto para la arquitectura
  actual (ver [07-paquetes-y-repositorios.md](07-paquetes-y-repositorios.md)).

## 4. Pieza clave: libamicachy-intuition

- En 68k/HLE: jump table de `amicachy-intuition` (Rust).
- En x86/ARM nativo: `libamicachy-intuition.so` (el **mismo código Rust** compilado
  nativo).
- Mismo header C público para ambos:

```c
/* amicachy/intuition.h - mismo header en todos los targets */
typedef struct ACWindow ACWindow;
typedef struct ACEvent  ACEvent;
ACWindow* ac_open_window(const char* title, int w, int h);
void      ac_close_window(ACWindow* win);
int       ac_wait_event(ACWindow* win, ACEvent* ev);
void      ac_draw_text(ACWindow* win, int x, int y, const char* text);
```

Resultado: una app DASH compilada a 68k (corriendo vía Musashi) y la misma app compilada
a x86 nativo tienen **exactamente el mismo aspecto**, porque ambas usan
amicachy-intuition.

## 5. Refactor sugerido en el repo de DASH

Sin tocar gramática/AST/analyzer, que son 100 % portables:

```
lib/
├── amiga/        (ya existe — bindings 68k/AmigaOS)
└── amicachy/     (nuevo — bindings targets nativos)
    ├── x86_64.h
    └── aarch64.h

compiler/builtins/   (refactor de amiga_builtins.py)
├── base.py          (interfaz común: Window, EventLoop, Print, …)
├── target_68k.py    (genera llamadas a AmigaOS/HLE)
├── target_x86.py    (genera llamadas a libamicachy-intuition.so)
└── target_wasm.py   (futuro, Canvas API)
```

CLI:

```bash
./dash hola.dash -o bin/hola --target=68k       # default actual
./dash hola.dash -o bin/hola --target=x86_64
./dash hola.dash -o bin/hola --target=aarch64
./dash hola.dash -o bin/hola --target=all
```

## 6. Secuenciación

Los pasos 1–4 (refactor de builtins, definir headers, implementar `target_x86` con
stub, añadir `--target` al CLI) **se pueden hacer ya**, sin esperar a que
`amicachy-intuition` en Rust esté listo. El paso 5 (compilar
`libamicachy-intuition.so` para x86 real) depende del avance del HLE.
