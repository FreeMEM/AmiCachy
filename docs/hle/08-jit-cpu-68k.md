# 08 — JIT para la CPU 68k (Musashi interpretado vs alternativas)

> **Estado:** plan de futuro (fase 2). Fuente original de estas notas:
> [`docs/AmiCachy-HLE_JIT.txt`](../AmiCachy-HLE_JIT.txt).

Cubre: el punto de partida con Musashi interpretado, cuándo el rendimiento de CPU se
convierte en un problema real (LightWave 5), el conflicto entre un JIT y la intercepción
HLE y su solución vía trampolines, los niveles de "JIT" posibles, las opciones concretas
de implementación y el roadmap recomendado.

Contexto previo: la integración de Musashi y el modelo de callbacks de memoria se
describen en [01-ejecucion-y-kernel.md](01-ejecucion-y-kernel.md).

## 1. Punto de partida: Musashi interpretado

Musashi es un **interpretador de tabla de saltos**: cada opcode de 16 bits tiene una
función C que lo decodifica e implementa, indexada por una tabla de 65 536 entradas. Es
maduro, estable, fácil de integrar vía FFI/bindgen, y su modelo de callbacks de memoria
hace **trivial** interceptar accesos para el HLE:

```rust
fn memory_read(address: u32) -> u32 {
    if is_library_jump_table(address) {
        return dispatch_to_rust_implementation(address);
    }
    ram[address as usize]
}
```

Para la mayoría de software (apps, utilidades, Workbench, Intuition) esto es más que
suficiente: el 68k original corría a 7–50 MHz y un interpretado en hardware moderno tiene
margen de sobra. El cuello de botella estaría en el renderer o en las librerías AmigaOS,
no en la CPU.

## 2. El caso que cambia la ecuación: LightWave 5

**Caso real:** una escena que en Amiberry (con JIT) tarda **7 segundos** en renderizar,
en modo interpretado tardaría del orden de **2 minutos**.

Por qué LightWave es distinto al resto del software:

- El renderizado es básicamente millones de iteraciones de bucles aritméticos (punto
  fijo/flotante).
- Prácticamente **sin** llamadas a AmigaOS durante el cálculo (quizás un `Wait()`
  ocasional para refrescar el progreso).
- Es el caso opuesto a abrir una ventana en Intuition, donde la mayoría de instrucciones
  son saltos a la jump table.

**Conclusión:** para cargas CPU-bound como esta, interpretado **sí** es un problema real
y medible, y un JIT aporta una diferencia de orden de magnitud (2 min → 7 s).

## 3. El conflicto JIT vs intercepción HLE (y su solución)

**Problema general con JIT.** Un interpretador ejecuta instrucción a instrucción, por lo
que **cada** acceso a memoria pasa por los callbacks — interceptar saltos a la jump table
de AmigaOS es natural. Con JIT, un bloque de código 68k se traduce **una vez** a código
nativo y se ejecuta directamente en repeticiones posteriores **sin** pasar por callbacks.
Si ese bloque contiene un `JSR` a la jump table, el JIT necesitaría "saber" de antemano
que esa dirección es especial.

**La solución — trampolines en direcciones conocidas.** Las direcciones de la jump table
de AmigaOS son **fijas y conocidas** de antemano (definidas en la NDK). El JIT, al
traducir un bloque, puede detectar si contiene un `JSR`/`JMP` a una de esas direcciones
conocidas y generar una **llamada a Rust** en vez de código nativo de salto:

```
Traducción de bloque 68k → x86:

   MOVE.L D0,-(A7)       →  mov [rsp-4], eax                  (código nativo normal)
   JSR -552(A6)          →  call rust_dispatch_OpenLibrary    (trampolín)
   ADDQ.L #4,A7          →  add rsp, 4
```

**Resultado:** el bloque sigue siendo código nativo rápido para el 99 % de las
instrucciones (la aritmética del raytracer), y solo las llamadas a sistema (poco
frecuentes en cargas CPU-bound como LightWave) hacen el salto a Rust. Esto es justo lo
que se necesita: máxima velocidad en cómputo, intercepción solo donde hay interacción
real con AmigaOS.

## 4. Niveles de "JIT" posibles (de menos a más complejo)

| Nivel | Técnica | Descripción | Coste / mejora |
|---|---|---|---|
| 1 | Cache de bloques básicos (*threaded interpretation*) | En vez de decodificar cada instrucción cada vez, se decodifica un bloque una vez y se guarda un array de punteros a función ya resueltos. Sigue siendo interpretado, pero evita el overhead de re-decodificación. | Relativamente factible, sin romper el modelo de callbacks de Musashi. Mejora **~20–40 %**. |
| 2 | Dynarec simple (traducción 1:1) | Por cada instrucción 68k se genera la secuencia equivalente de instrucciones x86/ARM, sin optimizar entre instrucciones (lo que hace Cyclone68000). | Trabajo grande: backend de generación de código, *allocation* de registros (D0–D7/A0–A7 → registros x86 o memoria), manejo de flags (no se mapean 1:1 con x86), invalidación de cache para *self-modifying code* (común en demos Amiga). |
| 3 | JIT optimizante real (estilo UAE JIT, DOSBox dynrec, LLVM/Cranelift con optimizaciones) | Análisis de bloques, *allocation* de registros entre instrucciones, eliminación de cálculos de flags redundantes, etc. | Proyecto de meses/años por sí solo — UAE JIT lleva 20+ años de iteración. |

## 5. Opciones de implementación concretas

### Opción A — Extraer el JIT de UAE (WinUAE/FS-UAE/Amiberry)

Ya existe, ya da los resultados (7 s en LightWave). Pero:

- Muy acoplado al resto de UAE (timing de ciclos, *hardware emulation*) — extraerlo
  limpio sería casi tanto trabajo como escribir uno nuevo.
- También necesitaría los mismos trampolines de jump table.
- Licencia GPL podría condicionar la integración en AmiCachy.

**No recomendada** como vía directa.

### Opción B — Cranelift (recomendada)

- Backend de compilación en Rust, usado por Wasmtime.
- En vez de escribir un dynarec 68k→x86 a mano, se escribe un traductor **68k →
  Cranelift IR**; Cranelift se encarga de:
  - generación de código nativo,
  - *allocation* de registros,
  - parte de las optimizaciones.
- Encaja naturalmente con el resto del stack en Rust.
- El trampolín de jump table se implementa en el traductor: al traducir un `JSR`,
  comprobar si el *target* es una dirección conocida de AmigaOS y emitir una llamada
  directa a la función Rust correspondiente en vez de traducir el salto.
- Trabajo acotado: **~80 instrucciones base** del 68k a traducir a IR, no miles.

## 6. Roadmap recomendado

| Fase | Cuándo | Alcance |
|---|---|---|
| Fase 1 | Ahora — desarrollo del HLE | Musashi interpretado para todo: `amicachy-exec`, `amicachy-dos`, `amicachy-intuition`, etc. El rendimiento no es el foco; lo que importa es tener el contrato de AmigaOS funcionando. |
| Fase 2 | Cuando el HLE básico funcione | Explorar Cranelift como JIT **opcional** para la CPU 68k: traductor 68k → Cranelift IR (proyecto serio pero acotado, ~80 instrucciones base); trampolines hacia Rust en las direcciones de jump table conocidas (NDK de AmigaOS); modo "JIT" activable por aplicación o detectado automáticamente (apps con poco I/O a sistema —tipo renderers, raytracers— se benefician más). |

**Arquitectura resultante:**

```
amicachy-hle
├── cpu::interpreted (Musashi)
│     → modo normal, máxima compatibilidad,
│       intercepción HLE trivial vía callbacks
└── cpu::jit (traductor 68k → Cranelift IR)
      → modo "performance" para apps CPU-bound conocidas
         (LightWave y similares)
      → trampolines a Rust en direcciones de jump table
         conocidas para mantener compatibilidad HLE
```

## 7. Conclusión

- **Musashi interpretado** es suficiente y correcto para el grueso del ecosistema
  (Workbench, apps, utilidades) y para todo el desarrollo inicial del HLE.
- **JIT (vía Cranelift)** se justifica para cargas CPU-bound concretas como LightWave 5,
  donde la diferencia es de orden de magnitud (2 min → 7 s).
- El "conflicto" entre JIT e intercepción HLE se resuelve con **trampolines hacia Rust**
  en las direcciones conocidas de la jump table de AmigaOS — el JIT detecta esos saltos en
  tiempo de traducción del bloque y emite llamadas directas en vez de código nativo de
  salto.
- Es un proyecto serio (meses, no semanas) pero **acotado y con objetivo medible**, a
  abordar en una **fase 2** una vez el HLE básico (exec/dos/intuition sobre Musashi
  interpretado) esté funcionando.
