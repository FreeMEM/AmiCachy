*[English](README.md)*

# El Alma de AmiCachy

## 1. La Mision: "El Amiga definitivo en PC"
Este proyecto no es una "distro de Linux con un emulador". El objetivo es construir un sistema basado en CachyOS que transforme un PC moderno en una estacion de trabajo Amiga de alto rendimiento. Queremos que el usuario olvide que hay un Kernel Linux debajo; el sistema debe comportarse como un electrodomestico dedicado (estilo consola o Android).

## 2. ¿Por que CachyOS y no Debian/Arch estandar?
La mayoria de los proyectos usan Debian por estabilidad, pero nosotros priorizamos la latencia y la potencia bruta.

**Kernels Optimizado:** CachyOS compila sus kernels para niveles especificos de CPU (x86-64-v3 y v4). Esto nos permite aprovechar instrucciones modernas (AVX-512) que aceleran drasticamente la emulacion pesada.

**Latencia Cero:** Usamos el scheduler BORE. En emulacion, el retraso entre pulsar un boton y ver la reaccion en pantalla (input lag) es el enemigo. CachyOS nos da la base mas rapida del ecosistema Linux actual.

**Sin Mitigaciones:** Para usuarios que quieren exprimir el PowerPC, desactivaremos las mitigaciones de seguridad del kernel (Spectre/Meltdown). En un sistema retro-gaming/dev, ganar ese 10-15% de velocidad es mas importante que la seguridad de un servidor.

## 3. El Desafio del PowerPC (AmigaOS 4.1)
El hardware nativo de Amiga PPC (como la AmigaOne X5000) es caro y dificil de conseguir. Queremos que este sistema, mediante Amiberry 7.1 y QEMU-PPC, supere (o al menos iguale) ese rendimiento.

Para lograrlo, el sistema debe ser capaz de autoconfigurarse. Si detecta un procesador potente, debe asignar prioridades de tiempo real al proceso de emulacion.

## 4. Estetica y Experiencia de Usuario (Anti-Linux)
El sistema debe estar "oculto".

**Silent Boot:** Nada de letras blancas scrolleando. Queremos un arranque limpio con el logo de Amiga.

**Wayland/Cage:** No usaremos escritorios como GNOME o KDE. Usaremos Cage, un compositor que lanza una sola aplicacion a pantalla completa. Si el usuario elige "Amiga 1200", el PC arranca y, sin ver un solo menu de Linux, aparece el Workbench.

### Cage: Wayland en su forma mas pura

Cage no es una aplicacion que corre "dentro" de un escritorio; **es** el servidor grafico (compositor) en si mismo. Sustituye a lo que en el mundo antiguo de Linux era X11 o en el moderno es GNOME/KDE.

**Eliminamos el intermediario.** En una distro normal la cadena grafica es:

```
Kernel → Servidor Grafico → Escritorio (panel, fondo, menus) → Amiberry
```

Con Cage, la cadena se reduce a:

```
Kernel → Cage → Amiberry
```

**Control total del frame.** Al ser un compositor de Wayland nativo, Cage le da a Amiberry el control total de la pantalla. Esto es lo que permite que Amiberry v7.1 use KMS (Kernel Mode Setting): la imagen va practicamente directa de la emulacion a la tarjeta grafica.

**Resultado:** nos quitamos de encima el 99% de los problemas de stuttering (tirones) y ese lag que hace que jugar al Pinball Dreams sea injugable.

**GPU:** La deteccion de la tarjeta grafica debe ser automatica para usar drivers KMS/Wayland nativos, eliminando el tearing y mejorando la fluidez del scroll en los juegos.

## 5. El Perfil del Desarrollador (Hybrid Dev)
No solo queremos jugar, queremos crear.

Estoy desarrollando un lenguaje que transpila a C para Amiga y una extension de VS Code para disenar GUIs con MUI.

Necesito un modo de arranque donde convivan VS Code (moderno) y Amiberry (retro) de forma transparente, compartiendo archivos en tiempo real. Es una "estacion de desarrollo hibrida".

## 6. Multi-Boot: Un PC, muchos Amigas
El sistema debe permitir al usuario elegir su "maquina" al encender el PC:

- Un Amiga 500 para puristas.
- Un Amiga 1200 con RTG para potencia grafica 68k.
- Un AmigaOS 4.1 para la experiencia PowerPC.
- Un Entorno de Desarrollo para programar.

Cada opcion debe ser un entorno optimizado y estanco, pero compartiendo la misma biblioteca de archivos y ROMs.

---

## 7. Guia de Desarrollo

### Compatibilidad de CPU

AmiCachy detecta automaticamente el nivel de arquitectura de tu CPU y se adapta:

| Nivel CPU | Ejemplos | Repos usados | Paquetes | Rendimiento |
|-----------|----------|-------------|----------|-------------|
| **generic** | Cualquier CPU x86-64 desde 2003 | `cachyos`, base Arch | x86-64 plano | El mas lento, maxima compatibilidad |
| **v3** (AVX2) | Intel Haswell+ (2013), AMD Excavator+ (2015) | `cachyos-v3` + anteriores | Optimizados v3 | Velocidad plena en la mayoria de PCs modernos |
| **v4** (AVX-512) | Intel Rocket Lake+ (2021), AMD Zen 4+ (2022) | `cachyos-znver4` + anteriores | Optimizados v4 | ~5% sobre v3 en CPUs compatibles |

Tanto `build_iso.sh` como `build_iso_docker.sh` aceptan `--cpu-arch generic|v3|v4` (por defecto `v3`). El nombre de salida es `amicachy-<ARCH>-DATE-x86_64.iso` para que puedas tener las tres variantes a la vez.

```bash
./tools/build_iso_docker.sh --cpu-arch generic   # universal, cualquier CPU x86-64
./tools/build_iso_docker.sh --cpu-arch v3        # por defecto - PCs modernos
./tools/build_iso_docker.sh --cpu-arch v4        # solo si hay AVX-512
```

**Seguridad en arranque:** todas las variantes incluyen `amilaunch.sh`, que detecta cuando una CPU carece de las instrucciones requeridas y muestra un mensaje claro en vez de petar con `SIGILL`.

La configuracion de pacman para cada variante esta en `archiso/pacman-{generic,v3,v4}.conf`. `Architecture =` esta fijado explicitamente por archivo, asi un host con instrucciones mas modernas nunca puede colar accidentalmente un paquete de mayor nivel desde su cache local hacia una ISO de menor nivel.

### Requisitos previos

Necesitas un host Linux (Ubuntu, Fedora, Arch, etc.) con lo siguiente:

```bash
# Herramientas base
sudo apt install qemu-system-x86 qemu-utils ovmf gdisk dosfstools  # Debian/Ubuntu
sudo pacman -S qemu-full edk2-ovmf gptfdisk dosfstools              # Arch/CachyOS

# Docker (para construir — el host no necesita pacman/archiso)
sudo apt install docker.io && sudo usermod -aG docker $USER  # Debian/Ubuntu
sudo pacman -S docker && sudo usermod -aG docker $USER       # Arch/CachyOS
sudo systemctl enable --now docker

# KVM (verificar virtualizacion por hardware)
lsmod | grep kvm    # debe mostrar kvm_intel o kvm_amd
```

### Por que Docker?

AmiCachy esta basado en CachyOS (un fork de Arch Linux). Construir la ISO requiere `mkarchiso`, `pacman-key` y acceso a los repositorios de paquetes de CachyOS — herramientas que solo existen en sistemas basados en Arch. Docker nos permite construir desde **cualquier host Linux** usando la imagen oficial de CachyOS, sin modificar el sistema anfitrion.

### Construir la ISO (para distribucion)

La ISO es el artefacto final distribuible — un archivo `.iso` arrancable con todos los perfiles, el wizard instalador y los modos live de prueba.

```bash
# Construir dentro de un contenedor Docker de CachyOS (funciona en cualquier host)
./tools/build_iso_docker.sh                    # por defecto: --cpu-arch v3

# O directamente en un host CachyOS / Arch (mas rapido, sin Docker):
sudo ./tools/build_iso.sh                      # por defecto: --cpu-arch v3

# Elige el baseline de CPU explicitamente:
./tools/build_iso_docker.sh --cpu-arch generic # cualquier CPU x86-64 desde 2003
./tools/build_iso_docker.sh --cpu-arch v3      # Haswell+/Excavator+
./tools/build_iso_docker.sh --cpu-arch v4      # Rocket Lake+/Zen 4+

# Resultado: out/amicachy-<ARCH>-YYYY.MM.DD-x86_64.iso
```

`generic` es la opcion mas segura cuando no conoces el hardware destino; `v3` es el default razonable para la mayoria de PCs actuales; `v4` solo tiene sentido en una CPU con AVX-512.

**Builds limpias por defecto.** `build_iso.sh` borra `work/` antes de cada build para que los cambios en `packages.x86_64` o `airootfs/` se apliquen siempre (mkarchiso usa stamp files en `work/` y se saltaria etapas silenciosamente). Para iterar rapido cuando solo cambias cosas que el cache no invalida, pasa `--reuse-work`.

**El binario de Amiberry esta etiquetado por arch y se construye on-demand.** `tools/build_amiberry.sh --cpu-arch generic|v3|v4` produce `out/amiberry-<VER>-<REL>-<arch>-x86_64.pkg.tar.zst` con `-march=x86-64-vN -mtune=generic` forzado (anula el `-march=native` de CachyOS, que de otro modo deja el binario atado a la CPU del host de build y provoca `SIGILL` en cualquier otra maquina). `build_iso.sh --cpu-arch X` elige el `.pkg` correspondiente; si no existe, llama a `build_amiberry.sh --cpu-arch X` automaticamente (desactiva con `--no-auto-amiberry`). De golpe las tres arches: `./tools/build_amiberry.sh --cpu-arch all`.

**Matriz de release en un solo comando.** `tools/build_all.sh` construye las tres variantes de amiberry, las tres ISOs y los tres `.img` de pendrive en una sola pasada. Idempotente: los artefactos ya presentes en `out/` se reutilizan a no ser que pases `--force`. Subselecionable con `--arch v3,v4` y `--skip-{amiberry,iso,pendrive}`. Cachea sudo antes (`sudo -v`) para que no se quede a media matriz pidiendo contrasena.

```bash
./tools/build_all.sh                       # todo, las tres arches
./tools/build_all.sh --arch v3             # una arch end-to-end
./tools/build_all.sh --skip-pendrive       # ISOs + amiberry, sin pendrives
./tools/build_all.sh --force               # rebuild aunque ya existan
```

**Pre-cargar contenido propio en la ISO.** `build_iso.sh` acepta `--seed-assets DIR` donde `DIR` contiene un arbol `kickstarts/` y/o `harddrives/`. Lo que haya dentro se incluye en la ISO y queda disponible para Amiberry en el primer arranque. Util si quieres construir una imagen personal completa con tus propias Kickstart ROMs y HDFs (obtenidos legalmente), en vez de aportarlos en runtime mediante el Asset Manager.

**Construir imagenes flasheables para pendrive.** `tools/build_pendrive.sh` envuelve cualquier ISO de AmiCachy con una particion seed pequena (256 MB) `AMICACHY_DATA` (NTFS por defecto para que Windows la monte de forma nativa) en un unico `.img` que se flashea con un solo `dd`. La imagen se mantiene compacta a proposito — en el primer arranque desde el pendrive, `amicachy-grow-data.service` expande automaticamente `AMICACHY_DATA` para ocupar todo el espacio libre del stick (NTFS/ext4; exFAT se deja como esta). Asi, un pendrive de 64 GB acaba con ~63 GB de espacio escribible sin forzarte a distribuir un `.img` de 60 GB. Ejecuta `./tools/build_pendrive.sh --help` para ver todas las opciones (assets, tamano del seed, tipo de filesystem).

**Solo construye la ISO cuando necesites una imagen distribuible.** Para el desarrollo del dia a dia, usa el flujo de la VM de desarrollo.

#### Notas de compatibilidad hardware

- **GPUs NVIDIA.** Las ISOs publicadas incluyen el driver propietario de NVIDIA (`nvidia-open-dkms` + `nvidia-utils`, soporta Turing+) y blacklistean nouveau via cmdline. Es la unica configuracion en la que Wayland/EGL funciona de forma fiable en RTX 20xx/30xx/40xx — el camino GSP de nouveau todavia falla con Ampere y rompe cage/wlroots. `nvidia-utils` esta bajo la NVIDIA Software License (limpia para redistribucion gratuita; el LICENSE se instala en `/usr/share/licenses/nvidia-utils/LICENSE`).
- **Maquinas multi-GPU.** `amilaunch.sh` elige la tarjeta DRM cuyo conector aparece `connected` (en empate gana el de mayor modo nativo) y fija wlroots a esa via `WLR_DRM_DEVICES`. Conecta el cable a la GPU que quieras usar — portatiles con graficos hibridos, sobremesas con dGPU + iGPU, etc., se manejan todos igual.
- **Firmware blobs.** A finales de 2025 `linux-firmware` se fragmento upstream; incluimos explicitamente los splits de hardware de consumo (nvidia, amdgpu, intel, broadcom, atheros, realtek, mediatek, …) para que los kernels arranquen en RTX 20xx+ (sin `linux-firmware-nvidia` se cuelgan en Plymouth en hardware real).

### VM de desarrollo (iteracion rapida)

Reconstruir la ISO para cada cambio es lento (10+ minutos). La VM de desarrollo te da un ciclo de prueba de **segundos**:

```
  Editar archivos ──> Sync (5 seg) ──> Arrancar VM (10 seg) ──> Probar ──> Repetir
```

#### Configuracion inicial (una sola vez)

```bash
# Cachear credenciales de sudo antes (necesario para montar el disco con qemu-nbd)
sudo -v && ./tools/dev_vm.sh create
```

Esto crea un disco virtual qcow2 de 40 GB, lo particiona (EFI + root), ejecuta `pacstrap` via Docker con todos los paquetes de AmiCachy, aplica la configuracion de airootfs, instala systemd-boot y configura el autologin. Tarda ~10 minutos la primera vez.

#### Ciclo editar-probar

```bash
# 1. Editar cualquier archivo del proyecto
vim archiso/airootfs/usr/bin/amilaunch.sh

# 2. Sincronizar cambios al disco de la VM (segundos)
sudo -v && ./tools/dev_vm.sh sync

# 3. Arrancar y probar
./tools/dev_vm.sh boot

# 4. En otra terminal, ver el log de arranque en tiempo real
./tools/dev_vm.sh log
```

#### Todos los comandos

| Comando | Descripcion |
|---------|-------------|
| `./tools/dev_vm.sh create` | Una vez: crear disco, pacstrap, configurar (usa Docker) |
| `./tools/dev_vm.sh sync` | Sincronizar airootfs + boot entries + installer (segundos) |
| `./tools/dev_vm.sh boot` | Lanzar la VM con QEMU/KVM + UEFI |
| `./tools/dev_vm.sh boot-iso <ISO>` | Arrancar una ISO ya construida bajo el mismo QEMU, con un qcow2 scratch como destino de instalacion. Anade `--persist` para conectar un segundo "USB stick" con label `AMICACHY_DATA`. |
| `./tools/dev_vm.sh boot-img <IMG>` | Arrancar un `.img` de pendrive (salida de `build_pendrive.sh`) como USB stick. Copia el `.img` a `dev/` para no tocar el original y lo crece con `--disk-size 8G` (por defecto) para ejercitar `amicachy-grow-data`. Anade `--debug` para parchear las entries de systemd-boot y volcar todo el output del kernel/journal en `dev/img-serial.log`. |
| `./tools/dev_vm.sh install <pkg\|nombre>` | Instalar paquetes .pkg.tar.zst locales o del repo en la VM (usa Docker) |
| `./tools/dev_vm.sh log` | Ver el log de arranque en tiempo real (`--full` para log completo) |
| `./tools/dev_vm.sh shell` | Montar el disco para inspeccion manual (subshell interactivo) |
| `./tools/dev_vm.sh destroy` | Eliminar el disco de la VM y todos los artefactos |

> **Nota:** `create`, `sync` y `shell` necesitan `sudo` para montar el disco (`qemu-nbd`). Ejecuta `sudo -v` antes para cachear las credenciales.

#### Configuracion

Variables de entorno para personalizar la VM:

```bash
RAM=8192 CPUS=4 ./tools/dev_vm.sh boot       # mas recursos
DISK_SIZE=80G ./tools/dev_vm.sh create        # disco mas grande
DISPLAY_MODE=safe ./tools/dev_vm.sh boot      # sin aceleracion GL (fallback)
```

#### Depuracion

Toda la salida del kernel y servicios se captura via consola serie en `dev/boot.log`:

```bash
# Log en tiempo real mientras la VM corre (en otra terminal)
./tools/dev_vm.sh log

# Log completo tras cerrar la VM
./tools/dev_vm.sh log --full
```

En el menu de systemd-boot, pulsa `e` para editar parametros del kernel (ej. quitar `quiet splash` para arranque verbose).

#### Acceso SSH

La VM expone el puerto 2222 para SSH:

```bash
ssh -p 2222 amiga@localhost   # password: amiga
```

### Compilar Amiberry (el emulador)

Amiberry no esta disponible como paquete en los repositorios de Arch/CachyOS. Lo compilamos desde el codigo fuente con optimizaciones de CachyOS para maximo rendimiento en emulacion:

- **CFLAGS x86-64-v3** (AVX2) del `makepkg.conf` de CachyOS
- **Link-Time Optimization** (LTO) via CMake
- **Control DBUS** para gestion programatica del emulador
- **Socket IPC** para futuro debug bridge (VS Code <-> Amiberry)

```bash
# Compilar el .pkg.tar.zst de amiberry dentro de Docker (~5 min)
./tools/build_amiberry.sh

# Resultado: out/amiberry-7.1.1-1-x86_64.pkg.tar.zst
```

El PKGBUILD esta en `pkg/amiberry/PKGBUILD`.

#### Amiberry en la VM de desarrollo

Compilar una vez, instalar una vez — el paquete **persiste en el disco qcow2** entre reinicios. Solo necesitas reinstalar si haces `destroy` de la VM o quieres actualizar a una version mas nueva.

```bash
# Instalar (una vez, despues de compilar — usa Docker + arch-chroot)
sudo -v && ./tools/dev_vm.sh install out/amiberry-*.pkg.tar.zst
```

#### Amiberry en la ISO

Al construir la ISO, el script **detecta automaticamente** el paquete compilado de amiberry en `out/` y lo incluye. No necesitas pasos manuales:

```bash
# 1. Compilar amiberry (si no lo has hecho)
./tools/build_amiberry.sh

# 2. Construir ISO — amiberry se incluye automaticamente
./tools/build_iso_docker.sh
```

Si no se encuentra ningun paquete de amiberry en `out/`, la ISO se construye sin el y muestra un aviso.

### Probar la ISO con KVM/libvirt

Una vez construida la ISO, pruebalá en una maquina virtual UEFI completa:

```bash
./tools/test_iso.sh                    # usa la ISO mas reciente en out/
./tools/test_iso.sh ruta/al/archivo.iso   # especificar ISO
./tools/test_iso.sh --destroy          # recrear la VM desde cero
```

Esto usa `virt-install` para crear una VM con arranque UEFI (OVMF), un disco virtio de 40 GB y pantalla SPICE. Requiere `virt-manager` (`virt-install`, `virsh`, `virt-viewer`) y `libvirtd` activo.

### Configurar KVM/libvirt + Vagrant

Para un entorno de desarrollo reproducible, puedes usar Vagrant con el provider de libvirt:

#### 1. Instalar KVM y libvirt

```bash
# Debian/Ubuntu
sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients \
    virt-manager bridge-utils

# Arch/CachyOS
sudo pacman -S qemu-full libvirt virt-manager dnsmasq iptables-nft

# Habilitar e iniciar
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt $USER
# Cerrar sesion y volver a entrar para que el grupo tome efecto
```

#### 2. Verificar que KVM funciona

```bash
virsh list --all         # deberia conectar sin errores
kvm-ok                   # (Ubuntu) o comprobar que /dev/kvm existe
```

#### 3. Instalar Vagrant con libvirt (opcional)

Vagrant automatiza el ciclo de vida de VMs si prefieres usarlo en vez de los scripts `dev_vm.sh` / `test_iso.sh`:

```bash
# Instalar Vagrant
sudo apt install vagrant           # Debian/Ubuntu
sudo pacman -S vagrant             # Arch/CachyOS

# Instalar el plugin de libvirt
vagrant plugin install vagrant-libvirt

# Usar con la ISO construida
# (Crea un Vagrantfile que arranque la ISO — ver documentacion de Vagrant)
```

### Estructura del proyecto

```
AmiCachy/
├── archiso/                    # Perfil archiso (fuente de la ISO)
│   ├── profiledef.sh           # Configuracion de build de la ISO
│   ├── pacman.conf             # Repositorios de paquetes
│   ├── packages.x86_64         # Lista de paquetes (~60 paquetes)
│   ├── airootfs/               # Overlay del filesystem (configs, scripts)
│   │   ├── etc/                # Config del sistema (locale, autologin, plymouth)
│   │   ├── home/amiga/         # Home del usuario por defecto (labwc, bash_profile)
│   │   ├── usr/bin/            # amilaunch.sh, start_dev_env.sh, installer
│   │   └── usr/share/amicachy/ # Configs UAE, tema plymouth
│   └── efiboot/loader/entries/ # Entradas systemd-boot (6 perfiles)
├── pkg/
│   └── amiberry/PKGBUILD       # Paquete Amiberry (optimizado CachyOS, LTO)
├── tools/
│   ├── build_iso.sh            # Build ISO (requiere host Arch/CachyOS)
│   ├── build_iso_docker.sh     # Build ISO via Docker (cualquier host Linux)
│   ├── build_amiberry.sh       # Compilar amiberry via Docker
│   ├── dev_vm.sh               # Gestor de VM de desarrollo (iteracion rapida)
│   ├── test_iso.sh             # Probar ISO en VM KVM/libvirt
│   ├── hardware_audit.py       # GUI de auditoria de hardware standalone
│   ├── lib/cpu_arch.sh         # Deteccion de CPU (compartido por todos los scripts)
│   └── installer/              # Wizard instalador PySide6 (7 paginas)
├── dev/                        # [gitignored] Disco de la VM de desarrollo + logs
├── out/                        # [gitignored] ISOs y paquetes compilados
├── ARCHITECTURE.md             # Especificacion tecnica
├── MASTER_PLAN.md              # Roadmap y stack tecnologico
├── README.md                   # Documentacion (ingles)
└── README.es.md                # Este archivo (espanol)
```

### Contribuir

1. **Haz fork y clona** el repositorio
2. **Instala los requisitos** (ver arriba): Docker, QEMU/KVM, OVMF
3. **Crea la VM de desarrollo** (una vez, ~10 min):
   ```bash
   sudo -v && ./tools/dev_vm.sh create
   ```
4. **Compila e instala amiberry** (una vez, ~5 min):
   ```bash
   ./tools/build_amiberry.sh
   sudo -v && ./tools/dev_vm.sh install out/amiberry-*.pkg.tar.zst
   ```
5. **Ciclo editar-probar**:
   ```bash
   # Edita archivos en archiso/airootfs/ o tools/
   sudo -v && ./tools/dev_vm.sh sync
   ./tools/dev_vm.sh boot
   # En otra terminal: ./tools/dev_vm.sh log
   ```
6. **Construye la ISO completa** cuando este listo para distribuir (amiberry se incluye automaticamente desde `out/`):
   ```bash
   ./tools/build_iso_docker.sh            # optimizada para tu CPU
   ./tools/build_iso_docker.sh --generic  # universal (cualquier x86-64)
   ```
7. **Envia un pull request**

## Licencia

AmiCachy se distribuye bajo la GNU General Public License v3.0 — ver [LICENSE](LICENSE) para el texto completo.

Copyright (C) 2026 Francisco Antonio Tapias Bravo (FreeMEM)

Los componentes de terceros conservan sus licencias originales (Amiberry, AROS, paquetes de CachyOS, temas de Plymouth, etc.). Los bundles opcionales que el Asset Manager descarga en tiempo de ejecucion (por ejemplo AROS Vision) se rigen por sus propias licencias upstream, que se muestran al usuario antes de la descarga.
