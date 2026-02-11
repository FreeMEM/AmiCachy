# PROJECT_CONTEXT.md: Filosofía y Visión de AmiCachy

## 1. El Concepto: "Amiga como Electrodoméstico"
AmiCachy no es una distribución Linux con un emulador instalado; es un sistema diseñado para transformar un PC en una "Máquina Amiga" dedicada. Siguiendo el modelo de abstracción de Android, el usuario nunca debe ver la terminal de Linux, ni el escritorio, ni procesos de carga. Desde el encendido hasta el Workbench, la experiencia debe ser 100% Amiga.

## 2. El Factor CachyOS (Rendimiento Extremo)
Hemos elegido CachyOS (basado en Arch) por tres razones críticas:
- **Optimización de Microarquitectura:** CachyOS compila sus repositorios para x86-64-v3 y v4. Esto permite que la emulación de PowerPC y el JIT de 68k usen instrucciones modernas (AVX-512) que no están aprovechadas en kernels genéricos como los de Debian.
- **Latencia de Audio y Video:** Usamos el scheduler BORE. En Amiga, la fluidez es sagrada. Necesitamos que el input lag de los joysticks y la latencia de sonido sean imperceptibles, algo que solo un kernel optimizado para escritorio/gaming puede dar.
- **Sin Mitigaciones:** Para maximizar la emulación PPC (AmigaOS 4.1), el sistema debe permitir desactivar las mitigaciones de seguridad del procesador (Spectre/Meltdown), priorizando la velocidad bruta sobre la seguridad de red.

## 3. El Desafío PowerPC (PPC)
El objetivo es que un PC moderno, mediante Amiberry 7.1 y QEMU-PPC, "debería" superar en rendimiento a hardware nativo costoso como el AmigaOne X5000. Para ello, necesitamos una detección de hardware precisa que asigne prioridades de tiempo real al proceso de emulación.

## 4. Entorno de Desarrollo Híbrido
El proyecto incluye un perfil especial de arranque para programadores. Estoy desarrollando un lenguaje que transpila a C nativo de Amiga y una extensión de VS Code para diseñar interfaces MUI. 
Este perfil debe permitir que convivan herramientas modernas (VS Code) y la ejecución retro (Amiberry) en un entorno Wayland ligero (Labwc), comunicándose de forma transparente.

## 5. Experiencia "Invisible"
- **Boot:** Silent boot con Plymouth (logo Amiga).
- **Gráficos:** Uso nativo de Wayland/KMS para eliminar el tearing sin usar V-Sync pesado.
- **Detección:** El sistema debe identificar la GPU (Intel/AMD/Nvidia) para cargar el mejor driver automáticamente en la ISO Live y tras la instalación.
