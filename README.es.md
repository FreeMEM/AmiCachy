*[English](README.md)*

# El Alma de AmiCachy

## 1. La Mision: "El Amiga definitivo en PC"
Este proyecto no es una "distro de Linux con un emulador". El objetivo es crear un fork evolucionado de AmiBootEnv que transforme un PC moderno en una estacion de trabajo Amiga de alto rendimiento. Queremos que el usuario olvide que hay un Kernel Linux debajo; el sistema debe comportarse como un electrodomestico dedicado (estilo consola o Android).

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
./tools/build_iso_docker.sh

# Resultado: out/amicachy-YYYY.MM.DD-x86_64.iso
```

Esto descarga la imagen `cachyos/cachyos-v3:latest`, instala `archiso`, inicializa el keyring de CachyOS y ejecuta `mkarchiso`. La ISO se escribe en `out/`.

**Solo construye la ISO cuando necesites una imagen distribuible.** Para el desarrollo del dia a dia, usa el flujo de la VM de desarrollo.

### VM de desarrollo (iteracion rapida)

Reconstruir la ISO para cada cambio es lento (10+ minutos). La VM de desarrollo te da un ciclo de prueba de **segundos**:

```
  Editar archivos ──> Sync (5 seg) ──> Arrancar VM (10 seg) ──> Probar ──> Repetir
```

#### Configuracion inicial (una sola vez)

```bash
./tools/dev_vm.sh create
```

Esto crea un disco virtual qcow2 de 40 GB, lo particiona (EFI + root), ejecuta `pacstrap` via Docker con todos los paquetes de AmiCachy, aplica la configuracion de airootfs, instala systemd-boot y configura el autologin. Tarda ~10 minutos la primera vez.

#### Ciclo editar-probar

```bash
# 1. Editar cualquier archivo del proyecto
vim archiso/airootfs/usr/bin/amilaunch.sh

# 2. Sincronizar cambios al disco de la VM (segundos)
./tools/dev_vm.sh sync

# 3. Arrancar y probar
./tools/dev_vm.sh boot
```

#### Todos los comandos

| Comando | Descripcion |
|---------|-------------|
| `./tools/dev_vm.sh create` | Una vez: crear disco, pacstrap, configurar (usa Docker) |
| `./tools/dev_vm.sh sync` | Sincronizar airootfs + boot entries + installer (segundos) |
| `./tools/dev_vm.sh boot` | Lanzar la VM con QEMU/KVM + UEFI |
| `./tools/dev_vm.sh shell` | Montar el disco y abrir un subshell para inspeccion manual |
| `./tools/dev_vm.sh destroy` | Eliminar el disco de la VM y todos los artefactos |

#### Configuracion

Variables de entorno para personalizar la VM:

```bash
RAM=8192 CPUS=4 ./tools/dev_vm.sh boot       # mas recursos
DISK_SIZE=80G ./tools/dev_vm.sh create        # disco mas grande
DISPLAY_MODE=safe ./tools/dev_vm.sh boot      # sin aceleracion GL (fallback)
```

#### Acceso SSH

La VM expone el puerto 2222 para SSH:

```bash
ssh -p 2222 amiga@localhost   # password: amiga
```

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
│   └── efiboot/loader/entries/ # Entradas systemd-boot (6 perfiles)
├── tools/
│   ├── build_iso.sh            # Build ISO (requiere host Arch/CachyOS)
│   ├── build_iso_docker.sh     # Build ISO via Docker (cualquier host Linux)
│   ├── dev_vm.sh               # Gestor de VM de desarrollo (iteracion rapida)
│   ├── test_iso.sh             # Probar ISO en VM KVM/libvirt
│   ├── hardware_audit.py       # GUI de auditoria de hardware standalone
│   └── installer/              # Wizard instalador PySide6 (7 paginas)
├── ARCHITECTURE.md             # Especificacion tecnica
├── MASTER_PLAN.md              # Roadmap y stack tecnologico
├── README.md                   # Documentacion (ingles)
└── README.es.md                # Este archivo (espanol)
```

### Contribuir

1. Haz fork del repositorio
2. Configura el entorno de desarrollo: `./tools/dev_vm.sh create`
3. Haz tus cambios en `archiso/airootfs/` o `tools/`
4. Prueba: `./tools/dev_vm.sh sync && ./tools/dev_vm.sh boot`
5. Cuando estes listo, construye la ISO completa: `./tools/build_iso_docker.sh`
6. Envia un pull request
