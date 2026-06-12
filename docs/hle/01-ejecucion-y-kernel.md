# 01 — Arquitectura de ejecución y "kernel" HLE

Cubre: capas de implementación, integración con Musashi, multinúcleo/multihilo,
scheduler, tasks/señales/mensajes, modelo de memoria y protección de memoria.

## 1. Arquitectura por capas — prioridad de implementación

| Capa | Componente | Notas |
|---|---|---|
| 1 | CPU + trampolín (Rust + Musashi) | `musashi-sys` (bindgen sobre Musashi en C, no reescribir), `musashi-rs` (capa segura). Watchpoints en los offsets de la jump table de cada librería base. Factible en semanas. |
| 2 | exec.library (`amicachy-exec`) | Lo más crítico: tasks, memoria, señales, puertos de mensajes, semáforos. AmigaOS es single-process **cooperativo** (no preemptivo), lo que facilita mucho la implementación. |
| 3 | dos.library + intuition.library | dos.library mapea bien a POSIX. Intuition (screens, windows, gadgets, layers/rastports) es el trabajo grande. Incluye la infraestructura **BOOPSI** (clases de gadget/imagen), base imprescindible para ReAction y MUI. |
| 4 | graphics.library + blitter | Decisión: emular blitter píxel a píxel (correcto, lento) vs interceptar y reimplementar con primitivas modernas (rápido, más complejo). **Recomendación:** interceptar las llamadas de graphics.library y reimplementar con wgpu; NO emular copper/blitter a nivel hardware desde el día 1. |
| 4.5 | **gadtools.library** + **ReAction** (clases BOOPSI) | Toolkits de widgets que **emite nuestro propio compilador DASH** (`gt_*` → GadTools, `ra_*` → ReAction). Ambos se construyen *sobre* Intuition, no son librerías independientes: GadTools es un wrapper de los gadgets de Intuition (necesita la `VisualInfo` del screen); ReAction es un conjunto de gadget classes BOOPSI (`window.class`, `layout.gadget`, `button.gadget`, `chooser.gadget`, …). **Prioridad alta** para el ecosistema AmiCachy — es lo que ejecutan las apps generadas con DASH. Ver detalle abajo. |
| 5 | MUI (`amicachy-mui`) | Librería de Stefan Stuntz, modelo de clases BOOPSI propio (`muimaster.library`), independiente de ReAction. Más compleja pero desacoplada. Necesaria para el grueso del software **clásico externo** (la mayoría de apps Amiga serias usan MUI), no para lo que produce DASH — por eso va **después** de GadTools/ReAction. |

> **Rendimiento de la CPU:** Musashi interpretado es suficiente para todo el desarrollo
> inicial y para el grueso del software. Para cargas CPU-bound (renderers tipo
> LightWave 5) se contempla un JIT opcional vía Cranelift en una fase 2; ver
> [08-jit-cpu-68k.md](08-jit-cpu-68k.md).

### Toolkits de widgets (GadTools, ReAction, MUI)

Ninguno de los tres es una librería autónoma: todos descansan sobre Intuition. El orden
de prioridad lo marca **qué emite DASH** (ver el compilador en `FreeMEM/dash`,
`compiler/amiga_builtins.py`), no la complejidad histórica de cada toolkit.

| Toolkit | Crate / librería HLE | Depende de | Estado en DASH | Prioridad HLE |
|---|---|---|---|---|
| **GadTools** | `gadtools.library` (sobre `amicachy-intuition`) | gadgets de Intuition + `VisualInfo` del screen | **soportado** (`gt_*`, 15 fns) | Alta — primer toolkit "real" tras Intuition base |
| **ReAction** | gadget classes BOOPSI (sobre `amicachy-intuition`) | infraestructura BOOPSI de Intuition | **soportado** (`ra_*`, 62 fns: layout, chooser, scroller, palette, canvas…) | Alta — es el camino principal de las apps DASH |
| **MUI** | `amicachy-mui` (`muimaster.library`) | BOOPSI propio, framework aparte | **no implementado** en DASH | Media — compatibilidad con software clásico externo, va al final |

**Implicaciones de diseño:**

- La **infraestructura BOOPSI** (registro de clases, `NewObject`/`DisposeObject`,
  `SetAttrs`/`GetAttr`, `DoMethod`) hay que construirla dentro de `amicachy-intuition`
  desde la capa 3, porque **tanto ReAction como MUI** la necesitan. Es el cimiento común.
- **GadTools** es el más barato: una vez que Intuition tiene gadgets nativos, GadTools es
  un wrapper relativamente fino (`CreateGadget`, `GT_GetGadgetAttrs`, `GT_SetGadgetAttrs`,
  el bucle `GT_GetIMsg`/`GT_ReplyIMsg`). Implementarlo en cuanto Intuition esté usable.
- **ReAction** es más trabajo: hay que implementar las gadget classes que usa DASH
  (`window.class`, `layout.gadget`, `button.gadget`, `string.gadget`, `integer.gadget`,
  `checkbox.gadget`, `slider.gadget`, `chooser.gadget`, `scroller.gadget`,
  `palette.gadget`, más el `space.gadget` y los grupos de layout). El sistema de layout
  automático (h/v groups con pesos) es lo no trivial.
- **MUI** queda como capa 5 desacoplada, para correr software clásico externo; no bloquea
  el ecosistema propio AmiCachy/DASH.

> **Coordinación con DASH:** la lista canónica de llamadas a soportar es la que ya genera
> el backend 68k de DASH (`GADTOOLS_FUNCTIONS` y `REACTION_FUNCTIONS` en
> `compiler/amiga_builtins.py`). El HLE debe cubrir como mínimo ese conjunto para que un
> binario producido por DASH arranque sin huecos.

## 2. Multinúcleo y multihilo

### El problema fundamental

AmigaOS 3.x es single-core y cooperativo:

- Scheduler cooperativo (`Wait()`/`Signal()`), 256 niveles de prioridad, sin time
  slicing por defecto.
- Estructuras internas de Exec (listas, puertos) **sin locks**.
- `Forbid()`/`Permit()` deshabilitan el dispatcher completo;
  `Disable()`/`Enable()` deshabilitan interrupciones.
- Un multihilo *naive* corrompe las listas internas de Exec (el mismo problema que
  tuvieron MorphOS y AmigaOS 4 con SMP).

### Estrategias evaluadas

**Opción A — Paralelismo externo (recomendada, base del diseño):**
Musashi corre en **un único hilo** (semántica AmigaOS exacta); el paralelismo está en
las capas de alrededor:

| Core | Trabajo |
|---|---|
| 0 | Musashi + exec/dos (single-thread) |
| 1 | Renderer (Intuition/graphics → wgpu) |
| 2 | Audio (emulación Paula) |
| 3 | I/O async (filesystem, red) |

Comunicación vía canales (crossbeam/tokio); nunca estado mutable compartido directo.

**Opción B — Scheduler cooperativo sobre thread pool:** cada Task AmigaOS = corrutina /
`Future` en Rust (tokio/async); `Wait()` → `.await`. Problema: Musashi no es async,
requiere un wrapper cuidadoso.

**Opción C — SMP real con locks (como AmigaOS 4):** `Forbid`/`Permit` reimplementados
como locks reales. Rompe la compatibilidad binaria con software que asume `Forbid()`
como exclusión mutua sin overhead. Solo aplicable a apps **nativas recompiladas**, no a
binarios 68k.

**Recomendación final: combinar A + B.** Musashi en hilo dedicado (compatibilidad
binaria con software clásico); las librerías propias en Rust usan async/tokio
internamente; renderer, audio e I/O en cores separados. El software nativo recompilado
(futuro) puede usar la Opción C.

### Arquitectura de hilos concreta

| Hilo | Scheduling | Contenido |
|---|---|---|
| 1 (main) | `SCHED_FIFO` | Musashi + exec + dos. Semántica AmigaOS exacta, single-threaded. Nunca bloquea: `Wait()` = parking de Rust hasta señal. |
| 2 (render) | `SCHED_OTHER` | intuition + graphics → wgpu. Recibe `CommandBuffer` desde el hilo 1 vía `crossbeam::channel`. |
| 3 (audio) | — | Emulación Paula → cpal. Ring buffer compartido. |
| 4 (async IO) | — | Runtime tokio: filesystem, red; dos.library lo usa vía canales oneshot. |

### Nota sobre el scheduler de Linux (BORE)

Desde Linux, todo el mundo 68k es **un proceso** (Musashi) que nunca cede
voluntariamente → BORE lo penalizaría. Solución: marcar el hilo de Musashi con
`SCHED_FIFO`/`SCHED_RR` vía `pthread_setschedparam` (similar a las prioridades RT que ya
usa Amiberry en AmiCachy):

```rust
unsafe {
    let param = libc::sched_param { sched_priority: 90 };
    libc::pthread_setschedparam(
        libc::pthread_self(), libc::SCHED_FIFO, &param
    );
}
```

## 3. Scheduler, tasks, señales y mensajes

### El scheduler real de AmigaOS

- 256 niveles de prioridad (0–255).
- Cooperativo: una tarea corre hasta `Wait()`, o hasta que una tarea de mayor prioridad
  se desbloquea.
- `Forbid()`/`Permit()` deshabilitan el dispatcher; `Disable()`/`Enable()` las
  interrupciones.
- Sin time slicing por defecto (a igual prioridad, las tareas se turnan solo en
  `Wait()`).

### Precedente: ixemul

ixemul portaba POSIX a AmigaOS (la dirección inversa a AmiCachy) y resolvió el mismo
*impedance mismatch*:

| AmigaOS | Linux/POSIX |
|---|---|
| Tasks (sin fork/exec) | Procesos con `fork()` |
| Message ports | Pipes/sockets |
| Signals (32 bits) | Señales POSIX |
| Shared libraries | `.so` con `dlopen()` |
| Single address space | Address spaces separados |

AmiCachy controla **ambos lados**, lo que simplifica respecto a los hacks de ixemul.

### Modelo de tasks

Cada Task 68k corre dentro de **un** hilo Linux (el de Musashi). El scheduler de AmigaOS
se implementa en Rust como loop cooperativo single-threaded:

```rust
pub struct Scheduler {
    ready_queue: BTreeMap<Priority, VecDeque<TaskId>>,
    current: Option<TaskId>,
    forbidden: bool,   // Forbid() activo
    disabled: bool,    // Disable() activo
}

impl Scheduler {
    pub fn dispatch(&mut self) -> TaskId {
        if self.forbidden {
            return self.current.unwrap();
        }
        self.ready_queue
            .iter().rev()
            .find(|(_, q)| !q.is_empty())
            .map(|(_, q)| q[0])
            .unwrap()
    }
}
```

### Señales (32 bits por tarea)

Bitmask de 32 señales por tarea, con `AtomicU32`:

```rust
pub struct Task {
    id: TaskId,
    priority: u8,
    signal_alloc: AtomicU32,  // señales asignadas
    signal_wait:  AtomicU32,  // en qué espera (Wait())
    signal_recv:  AtomicU32,  // señales recibidas pendientes
    stack: Vec<u8>,
    cpu_state: MusashiContext,
}
```

`Wait(mask)` suspende hasta que cualquier bit de `mask` aparece en `signal_recv`.
`Signal(task, mask)` pone bits en `signal_recv` del destino y dispara el scheduler.

### Message passing

`PutMsg`/`GetMsg`/`WaitPort`: cola FIFO de punteros a estructuras en memoria compartida.
Como todas las Tasks comparten el mismo address space emulado (el `Vec<u8>` de Musashi),
el modelo se preserva exactamente.

### Modelo de memoria

```
$000000-$1FFFFF  Chip RAM (accesible por blitter/copper/audio)
$200000-$9FFFFF  Fast RAM (solo CPU)
$C00000-$DFFFFF  Slow RAM / Ranger RAM
$F00000-$FFFFFF  ROM (Kickstart)
```

Implementación: `Vec<u8>` de 16 MB con regiones marcadas. `AllocMem()` con `MEMF_CHIP`
vs `MEMF_FAST` asigna de regiones distintas del mismo buffer.

### Interrupciones y VBlank

AmigaOS depende del VBlank (50/60 Hz) para timing. Cada frame completado del renderer
wgpu/GLES dispara un `Signal()` simulado a las tareas que esperan `SIGB_VBLANK`,
manteniendo la sincronización temporal que espera el software.

### Mapa completo de la arquitectura de ejecución

```
Hilo Linux SCHED_FIFO (Musashi + amicachy-exec)
├── Scheduler cooperativo (BTreeMap de prioridades)
├── Task list (Vec<Task> con AtomicU32 de señales)
├── Memory map (Vec<u8> 16MB con regiones)
├── Message ports (HashMap<PortId, VecDeque<MsgPtr>>)
└── Jump table interceptor
    ├── exec.library  → amicachy-exec (Rust)
    ├── dos.library   → amicachy-dos (Rust)
    └── intuition     → amicachy-intuition (Rust)
        └─→ crossbeam::channel → Hilo renderer

Hilo Linux SCHED_OTHER (renderer)
└── wgpu/GLES → DRM/KMS → pantalla
```

## 4. Protección de memoria

### Realidad de AmigaOS

Sin protección de memoria: cualquier tarea puede leer/escribir cualquier dirección. Un
puntero corrupto no da segfault, machaca otra estructura. `Forbid()`/`Disable()` bastan
para exclusión mutua porque no hay MMU activa (deliberado, ni en 68020/030/040).

### Ventaja gratuita en AmiCachy

Musashi opera sobre un `Vec<u8>` propio (~16 MB). Desde el binario 68k, ese buffer **es**
todo el universo visible:

```
Proceso amicachy-desktop (Rust, x86_64)
├── Código Rust          ← inaccesible desde 68k
├── Musashi engine
└── memoria emulada []   ← único espacio visible para 68k
    ├── 0x000000 Chip RAM
    ├── 0x200000 Fast RAM
    └── 0xF00000 Kickstart/jump tables
```

Un binario 68k buggy/malicioso solo daña ese `Vec<u8>`; no puede escapar al proceso
host → mejor protección que un Amiga real.

### Problemas reales (dentro del espacio emulado)

1. **Corrupción entre tareas 68k:** sin protección entre ellas, igual que en AmigaOS
   real (es el contrato histórico). Modo debug opcional: `amicachy-exec` marca regiones
   asignadas y detecta escrituras fuera de rango (útil en desarrollo con DASH).
2. **Acceso a hardware mapeado** (p. ej. `0xDFF000`, custom chips): interceptar con
   callbacks de Musashi:

   ```rust
   fn memory_write(address: u32, value: u32, size: AccessSize) {
       match address {
           0xDFF000..=0xDFF1FF => custom_chips.write(address, value),
           0x000000..=0x1FFFFF => ram[address as usize] = value as u8,
           _ => musashi.trigger_bus_error(address),
       }
   }
   ```
3. **Stack overflow dentro del espacio emulado:** AmigaOS no lo detecta. Opcional:
   marcar la página inferior del stack con un patrón conocido (`0xDEADBEEF`) y
   verificarlo periódicamente.

### Protecciones a implementar desde el principio

- **Guardas/magic numbers** en estructuras críticas de `amicachy-exec` (ExecBase,
  listas de tareas, message ports):

  ```rust
  pub struct ExecBase {
      magic: u32,  // 0xAC_EXEC_42
      lib_node: LibNode,
      task_ready: List,
      task_wait: List,
  }
  impl ExecBase {
      pub fn verify(&self) -> bool { self.magic == 0xAC_EXEC_42 }
  }
  ```

  Si `verify()` falla → reset limpio del entorno HLE en lugar de un crash misterioso.
- **Aislamiento entre sesiones:** cada instancia HLE = su propio `Vec<u8>` separado.
  Gratis con la arquitectura de procesos Linux (cada `amicachy-desktop` es un proceso
  separado).

**DASH y protección:** los binarios DASH para `target=68k` tienen el mismo aislamiento
que cualquier binario 68k. Se puede activar `-fstack-protector-strong` en
`m68k-amigaos-gcc` para canarios de stack, sin romper compatibilidad.

### Tabla resumen de amenazas

| Amenaza | Nivel | Solución |
|---|---|---|
| Binario 68k accede a memoria del host | Inexistente | Aislamiento por arquitectura (gratis) |
| Binario 68k corrompe otra tarea 68k | Real | Contrato histórico; detección en modo debug |
| Acceso a hardware mapeado | Real | Callbacks Musashi + whitelist de registros |
| Stack overflow en espacio emulado | Real | Magic patterns en zona de guarda (opcional) |
| Corrupción de estructuras amicachy-exec | Real | Magic numbers + `verify()` en paths críticos |
