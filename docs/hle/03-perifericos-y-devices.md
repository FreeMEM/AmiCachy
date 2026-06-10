# 03 — Periféricos y devices

Cubre: audio (Paula), impresoras, TCP/IP, serial/paralelo, CD-ROM, clipboard y el mapa
completo de devices AmigaOS → implementación AmiCachy-HLE.

## 1. Audio — Paula

Hardware real: 4 canales DMA, PCM 8-bit, registros en `0xDFF0A0–0xDFF0DF`.

**Nivel 1 — Register emulation** (software que habla directo al hardware): interceptar
escrituras vía callback de Musashi:

```
0xDFF0A0 → paula.set_sample_pointer(CH0, value)  (AUD0LCH/L)
0xDFF0A4 → paula.set_period(CH0, value)          (AUD0PER)
0xDFF0A6 → paula.set_volume(CH0, value)          (AUD0VOL)
```

Paula genera PCM → cpal.

**Nivel 2 — audio.device HLE** (software que usa la API estándar): interceptar en la
jump table igual que exec.library.

**Stack:** emulación Paula (Rust) → ring buffer → cpal → PipeWire/ALSA. cpal abstrae
PipeWire automáticamente en CachyOS.

## 2. Impresoras

AmigaOS: `printer.device`; las apps imprimen a `PRT:` como fichero DOS
(PostScript/PCL/texto plano).

AmiCachy: `PRT:` → fichero temporal → CUPS:

```
DosOpen("PRT:")  → crea /tmp/amicachy-print-XXXX
DosClose("PRT:") → lp /tmp/amicachy-print-XXXX
```

El usuario configura la impresora en CUPS desde Linux normalmente. Un panel de
Preferencias en AmiCachy lista las impresoras CUPS disponibles. Sin reinventar drivers.

## 3. TCP/IP — bsdsocket.library

El caso más elegante: `bsdsocket.library` (AmiTCP/Miami/Genesis) es prácticamente BSD
sockets directo (`socket`/`connect`/`send`/`recv`/`select` casi idénticos a POSIX).
Mapping casi 1:1:

```
"socket"  => libc::socket(domain, sock_type, protocol)
"connect" => libc::connect(fd, addr, addrlen)
"send"    => libc::send(fd, buf, len, flags)
"recv"    => libc::recv(fd, buf, len, flags)
"select"  => libc::select(nfds, readfds, writefds, exceptfds, timeout)
```

El "truco": traducción de estructuras (`sockaddr` 68k es big-endian, con offsets
distintos) — trabajo mecánico, no conceptualmente difícil.

Resultado: cualquier app 68k con bsdsocket.library tiene **red real** vía el stack
TCP/IP de Linux, de forma transparente. DNS: `gethostbyname()` → `getaddrinfo()` de
Linux.

## 4. Serial / paralelo

- `serial.device` → `/dev/ttyS*`
- `parallel.device` → `/dev/lp*`
- Si no hay hardware real, el open del device falla limpiamente.

## 5. CD-ROM / filesystem

- `cd.device` → `/dev/sr0` vía libcdio (ISO9660 nativo en Linux).
- `trackdisk.device` → ficheros `.adf` en `~/amicachy/floppies/` (igual que Amiberry).

## 6. Clipboard

`clipboard.device` (unidades IFF) → portapapeles de Wayland vía wl-clipboard.
Copiar/pegar entre apps 68k y apps Linux nativas de forma transparente — detalle pequeño
pero da sensación de integración real.

## 7. Mapa completo de devices

| AmigaOS device | Implementación AmiCachy-HLE |
|---|---|
| audio.device | Emulación Paula → cpal → PipeWire |
| bsdsocket.library | libc BSD sockets (casi 1:1) |
| printer.device | Fichero temporal → CUPS |
| serial.device | `/dev/ttyS*` (si existe) |
| parallel.device | `/dev/lp*` (si existe) |
| clipboard.device | wl-clipboard (Wayland) |
| trackdisk.device | Ficheros `.adf` |
| cd.device | `/dev/sr0` vía libcdio |
| timer.device | `clock_gettime(CLOCK_MONOTONIC)` |
| input.device | libinput vía Smithay |
| keyboard.device | libinput vía Smithay |
| gameport.device | `/dev/input/js*` (joystick Linux) |

## 8. Orden de implementación por impacto en compatibilidad

1. **timer.device** — dependencia silenciosa de muchísimas apps (sleeps/timeouts),
   trivial de implementar.
2. **bsdsocket.library** — alto impacto, mapping casi directo.
3. **audio.device + Paula** — necesario para apps multimedia.
4. **clipboard.device** — pequeño pero da sensación de integración.
5. **trackdisk → .adf** — software que accede a discos.
6. **printer.device → CUPS** — simple y útil.
7. **serial/parallel** — opcional, solo con hardware real.
