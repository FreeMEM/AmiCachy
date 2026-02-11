El Alma de AmiCachyEnv
1. La Misión: "El Amiga definitivo en PC"
Este proyecto no es una "distro de Linux con un emulador". El objetivo es crear un fork evolucionado de AmiBootEnv que transforme un PC moderno en una estación de trabajo Amiga de alto rendimiento. Queremos que el usuario olvide que hay un Kernel Linux debajo; el sistema debe comportarse como un electrodoméstico dedicado (estilo consola o Android).

2. ¿Por qué CachyOS y no Debian/Arch estándar?
La mayoría de los proyectos usan Debian por estabilidad, pero nosotros priorizamos la latencia y la potencia bruta.

Kernels Optimizado: CachyOS compila sus kernels para niveles específicos de CPU (x86-64-v3 y v4). Esto nos permite aprovechar instrucciones modernas (AVX-512) que aceleran drásticamente la emulación pesada.

Latencia Cero: Usamos el scheduler BORE. En emulación, el retraso entre pulsar un botón y ver la reacción en pantalla (input lag) es el enemigo. CachyOS nos da la base más rápida del ecosistema Linux actual.

Sin Mitigaciones: Para usuarios que quieren exprimir el PowerPC, desactivaremos las mitigaciones de seguridad del kernel (Spectre/Meltdown). En un sistema retro-gaming/dev, ganar ese 10-15% de velocidad es más importante que la seguridad de un servidor.

3. El Desafío del PowerPC (AmigaOS 4.1)
El hardware nativo de Amiga PPC (como la AmigaOne X5000) es caro y difícil de conseguir. Queremos que este sistema, mediante Amiberry 7.1 y QEMU-PPC, supere (o al menos iguale) ese rendimiento.

Para lograrlo, el sistema debe ser capaz de autoconfigurarse. Si detecta un procesador potente, debe asignar prioridades de tiempo real al proceso de emulación.

4. Estética y Experiencia de Usuario (Anti-Linux)
El sistema debe estar "oculto".

Silent Boot: Nada de letras blancas scrolleando. Queremos un arranque limpio con el logo de Amiga.

Wayland/Cage: No usaremos escritorios como GNOME o KDE. Usaremos Cage, un compositor que lanza una sola aplicación a pantalla completa. Si el usuario elige "Amiga 1200", el PC arranca y, sin ver un solo menú de Linux, aparece el Workbench.

### Cage: Wayland en su forma más pura

Cage no es una aplicación que corre "dentro" de un escritorio; **es** el servidor gráfico (compositor) en sí mismo. Sustituye a lo que en el mundo antiguo de Linux era X11 o en el moderno es GNOME/KDE.

**Eliminamos el intermediario.** En una distro normal la cadena gráfica es:

```
Kernel → Servidor Gráfico → Escritorio (panel, fondo, menús) → Amiberry
```

Con Cage, la cadena se reduce a:

```
Kernel → Cage → Amiberry
```

**Control total del frame.** Al ser un compositor de Wayland nativo, Cage le da a Amiberry el control total de la pantalla. Esto es lo que permite que Amiberry v7.1 use KMS (Kernel Mode Setting): la imagen va prácticamente directa de la emulación a la tarjeta gráfica.

**Resultado:** nos quitamos de encima el 99% de los problemas de stuttering (tirones) y ese lag que hace que jugar al Pinball Dreams sea injugable.

GPU: La detección de la tarjeta gráfica debe ser automática para usar drivers KMS/Wayland nativos, eliminando el tearing y mejorando la fluidez del scroll en los juegos.

5. El Perfil del Desarrollador (Hybrid Dev)
No solo queremos jugar, queremos crear.

Estoy desarrollando un lenguaje que transpila a C para Amiga y una extensión de VS Code para diseñar GUIs con MUI.

Necesito un modo de arranque donde convivan VS Code (moderno) y Amiberry (retro) de forma transparente, compartiendo archivos en tiempo real. Es una "estación de desarrollo híbrida".

6. Multi-Boot: Un PC, muchos Amigas
El sistema debe permitir al usuario elegir su "máquina" al encender el PC:

Un Amiga 500 para puristas.

Un Amiga 1200 con RTG para potencia gráfica 68k.

Un AmigaOS 4.1 para la experiencia PowerPC.

Un Entorno de Desarrollo para programar.

Cada opción debe ser un entorno optimizado y estanco, pero compartiendo la misma biblioteca de archivos y ROMs.
