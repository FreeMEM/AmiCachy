# 09 — AmiCachy-HLE como escritorio independiente

> **Estado:** cambio de enfoque (decisión de diseño). Fuente original de estas notas:
> [`docs/AmiCachy-HLE_Escritorio_Independiente.txt`](../AmiCachy-HLE_Escritorio_Independiente.txt).

Cubre: el giro de "parte integral de la ISO" a "entorno de escritorio empaquetable y
distribuible"; qué lógica HLE no cambia; la integración como sesión Wayland vía
`.desktop`; el **nuevo layout FHS + XDG** que reemplaza a `/opt/amicachy`; el empaquetado
multi-distro; el backend nativo de `acp` como plugin; y la estructura de repos resultante.

> **Impacto en otros documentos.** Este cambio **revisa** dos decisiones previas:
> - El árbol físico bajo `/opt/amicachy` de
>   [04-filesystem-assigns-permisos.md](04-filesystem-assigns-permisos.md) queda
>   sustituido por el layout FHS/XDG de la sección 4 de este documento.
> - El arranque vía units de systemd propias de
>   [05-arranque-y-shell.md](05-arranque-y-shell.md) convive ahora con (o cede a) el
>   arranque como **sesión Wayland** lanzada por el display manager del host (sección 3).

## 1. Cambio de enfoque

**Hasta ahora:** `amicachy-hle` se diseñó como parte integral de AmiCachy — paquete en
`pkg/`, entrada de boot propia, units de systemd específicas, todo bajo `/opt/amicachy`.

**Nuevo enfoque:** `amicachy-hle` se convierte en un **entorno de escritorio**
empaquetable y distribuible, igual que GNOME/KDE/Sway — instalable en cualquier distro
Linux, no solo en la ISO de AmiCachy.

```
amicachy-hle (repo independiente, distribuible)
    │
    ├── Funciona standalone en cualquier distro
    └── AmiCachy lo consume como "uno de sus modos de boot",
        pero ya no es exclusivo de AmiCachy
```

**Mismo patrón que DASH** — separar el componente reutilizable de la ISO:

| Repo | Rol |
|---|---|
| `FreeMEM/AmiCachy` | ISO (CachyOS + Amiberry + modos de boot) |
| `FreeMEM/dash` | lenguaje DASH, repo independiente |
| `FreeMEM/amicachy-hle` | escritorio HLE, repo independiente |

AmiCachy (la ISO) añade `amicachy-hle` como una opción más de boot, instalándolo como
paquete — exactamente igual que cualquier otra distro que quiera ofrecerlo.

## 2. Lo que NO cambia (lógica HLE agnóstica de distro)

Toda la lógica de emulación/HLE diseñada hasta ahora sigue igual; es independiente de
dónde se instale:

- `amicachy-compositor` (Smithay) — DRM/KMS/libinput son APIs del kernel, no de la distro.
- `amicachy-exec`, `amicachy-dos`, `amicachy-intuition` — lógica AmigaOS reimplementada
  en Rust.
- Musashi (CPU 68k vía FFI) y el futuro JIT vía Cranelift (ver
  [08-jit-cpu-68k.md](08-jit-cpu-68k.md)).
- Semántica de assigns, ENV, protection bits vía xattr.
- DASH como lenguaje cross-target (68k/x86/aarch64).
- `acp` para paquetes 68k (Aminet + repo propio) — vive en el home del usuario,
  completamente independiente de la distro.

**Lo único que cambia:** *dónde* viven físicamente los ficheros (rutas base) y *cómo* se
integra con el sistema de sesiones del Linux host.

## 3. Integración como sesión de escritorio (display manager)

GNOME/KDE/Sway se registran como sesiones que GDM/SDDM/LightDM pueden lanzar.
`amicachy-hle` hace lo mismo vía un fichero `.desktop` de sesión Wayland:

```ini
# /usr/share/wayland-sessions/amicachy-hle.desktop
[Desktop Entry]
Name=AmiCachy HLE
Comment=AmigaOS-inspired desktop environment
Exec=amicachy-desktop
Type=Application
DesktopNames=AmiCachy
```

Con esto, GDM/SDDM/lightdm-greeter muestran "AmiCachy HLE" en el selector de sesión junto
a GNOME, KDE, Sway, etc. El compositor Smithay (`amicachy-desktop`) arranca como una
sesión Wayland normal, lanzada por el display manager del host.

> Esto convive con el arranque por systemd descrito en
> [05-arranque-y-shell.md](05-arranque-y-shell.md): en una distro genérica, el display
> manager lanza la sesión; en la ISO de AmiCachy puede seguir teniendo sentido un arranque
> directo a `amicachy-desktop` sin greeter (appliance de un solo usuario).

## 4. Layout de directorios: FHS + XDG Base Directory

**Cambio más importante:** abandonar `/opt/amicachy` (tenía sentido para una ISO
autocontenida) y adoptar las rutas estándar que **cualquier** distro Linux espera — FHS
para ficheros de sistema, XDG Base Directory para datos de usuario. Esto **reemplaza** el
árbol físico de [04-filesystem-assigns-permisos.md](04-filesystem-assigns-permisos.md).

```
/usr/bin/amicachy-desktop          ← binarios del sistema
/usr/bin/amicachy-compositor
/usr/bin/amicachy-shell
/usr/bin/acp

/usr/lib/amicachy/                 ← librerías compartidas
    ├── libamicachy-intuition.so
    ├── libamicachy-exec.so
    └── (resto de .so del runtime HLE)

/usr/share/amicachy/               ← "System:" de solo lectura
    ├── C/                         ← C:  (comandos 68k)
    ├── Libs/                      ← LIBS:
    ├── Devs/                      ← DEVS:
    ├── Fonts/                     ← FONTS:
    └── Prefs/Env-Archive/         ← DEFAULTS de fábrica
                                      (no el ENVARC: del usuario)

/usr/share/wayland-sessions/
    └── amicachy-hle.desktop       ← entrada de sesión

--- datos de usuario (XDG) ---

~/.local/share/amicachy/           ← datos persistentes del usuario
    ├── ENVARC/                    ← preferencias persistentes
    ├── Storage/Programs/          ← acp install aquí (68k y nativos)
    └── User/                      ← Work:, Documents, Pictures, Music

~/.cache/amicachy/                 ← opcional: T:/RAM: persistido entre
                                      sesiones si se desea

/run/user/$UID/amicachy/           ← RAM:, ENV: (tmpfs por usuario, vía
                                      XDG_RUNTIME_DIR; volátil, se recrea
                                      cada sesión)
```

**Equivalencia con los assigns de AmigaOS** (sin cambios para el usuario — sigue viendo
`SYS:`, `LIBS:`, `Work:`, etc.):

| Assign AmigaOS | Ruta física (nuevo layout FHS/XDG) |
|---|---|
| `SYS:` | `/usr/share/amicachy/` |
| `C:` | `/usr/share/amicachy/C/` |
| `LIBS:` | `/usr/share/amicachy/Libs/` |
| `DEVS:` | `/usr/share/amicachy/Devs/` |
| `FONTS:` | `/usr/share/amicachy/Fonts/` |
| `ENVARC:` | `~/.local/share/amicachy/ENVARC/` |
| `ENV:` | `/run/user/$UID/amicachy/Env/` |
| `RAM:` | `/run/user/$UID/amicachy/` |
| `T:` | `/run/user/$UID/amicachy/T/` |
| `Storage:Programs` | `~/.local/share/amicachy/Storage/Programs/` |
| `User:` | `~/.local/share/amicachy/User/` |
| `Work:` | configurable; por defecto `~/.local/share/amicachy/User/Documents` |

**Implementación en `AssignTable`** (reemplaza a la basada en `/opt/amicachy` del doc 04):

```rust
impl AssignTable {
    pub fn default() -> Self {
        let share   = PathBuf::from("/usr/share/amicachy");
        let data    = dirs::data_dir().unwrap().join("amicachy");    // ~/.local/share/amicachy
        let runtime = dirs::runtime_dir().unwrap().join("amicachy"); // /run/user/$UID/amicachy

        let mut t = HashMap::new();
        t.insert("SYS",    share.clone());
        t.insert("C",      share.join("C"));
        t.insert("LIBS",   share.join("Libs"));
        t.insert("DEVS",   share.join("Devs"));
        t.insert("FONTS",  share.join("Fonts"));
        t.insert("ENVARC", data.join("ENVARC"));
        t.insert("ENV",    runtime.join("Env"));
        t.insert("T",      runtime.join("T"));
        t.insert("RAM",    runtime.clone());
        t.insert("User",   data.join("User"));
        t.insert("Work",   data.join("User/Documents"));
        t
    }
    // resolve() sin cambios respecto al diseño original (doc 04)
}
```

**Experiencia de usuario: idéntica.** Sigue viendo `SYS:`, `LIBS:`, `Work:`, `ENVARC:`,
etc. exactamente igual; solo cambia a dónde apuntan físicamente esas rutas, ahora
siguiendo el estándar de cualquier distro Linux.

> **Nota crítica para el desarrollo.** Decidir este layout **antes** de implementar
> `amicachy-dos`. Cambiar las rutas base después de tener la `AssignTable` y el resto del
> sistema construidos sobre `/opt/amicachy` sería un refactor doloroso y propenso a
> errores en todos los sitios que asuman esa ruta.

## 5. Empaquetado multi-distro

Para "instalable como GNOME/KDE en cualquier Linux" hay que empaquetar para los gestores
habituales, no solo pacman/Arch:

```
amicachy-hle/
└── packaging/
    ├── arch/PKGBUILD            ← patrón ya usado en AmiCachy
    ├── debian/                  ← .deb (Ubuntu, Debian, derivados)
    ├── fedora/amicachy-hle.spec ← .rpm
    └── flatpak/                 ← opcional, ver nota
```

**Nota sobre Flatpak.** Para un *entorno de escritorio* (el compositor en sí) Flatpak no
es lo más natural — necesita acceso directo a DRM/KMS/seat, que el sandboxing de Flatpak
complica. Donde **sí** tiene sentido a futuro: distribuir las *aplicaciones* que corren
**dentro** de AmiCachy-HLE (instalables vía `acp`), no el propio compositor/sesión.

## 6. `acp` y el backend nativo multi-distro

El backend de paquetes 68k (Aminet + repo propio) **no cambia nada**: vive en
`~/.local/share/amicachy/Storage/Programs/`, completamente independiente de la distro.

El backend **nativo** (instalar apps x86/ARM del propio ecosistema AmiCachy/DASH) sí debe
adaptarse: en el diseño original asumía pacman. Para multi-distro pasa a ser un backend
detectable/plugin:

```rust
enum NativeBackend {
    Pacman,   // Arch/CachyOS
    Apt,      // Debian/Ubuntu
    Dnf,      // Fedora
    None,     // no instala nativo, solo gestiona paquetes 68k
}
```

`acp` detecta el gestor de paquetes del host al arrancar y usa el backend correspondiente.
Si no reconoce ninguno (o el usuario lo prefiere), opera solo en modo 68k/Aminet, que
siempre funciona igual independientemente de la distro.

## 7. Estructura de repos resultante

| Repo | Contenido |
|---|---|
| `FreeMEM/AmiCachy` | ISO (CachyOS + Amiberry + modos de boot). Consume `amicachy-hle` como dependencia/paquete, igual que cualquier otra distro. |
| `FreeMEM/dash` | lenguaje DASH (ya existe, mismo patrón). |
| `FreeMEM/amicachy-hle` | **nuevo** repo independiente. |

Contenido de `FreeMEM/amicachy-hle`:

- `amicachy-compositor` (Smithay)
- `amicachy-exec` / `amicachy-dos` / `amicachy-intuition` / `amicachy-mui`
- `amicachy-shell`, `amicachy-desktop`
- `musashi-sys` / `musashi-rs`
- `acp`
- `packaging/` (arch, debian, fedora)
- `.desktop` de sesión Wayland
- `docs/` (la documentación de arquitectura ya integrada en AmiCachy se movería/enlazaría
  aquí)

## 8. Próximos pasos

1. Crear el repo `FreeMEM/amicachy-hle` (workspace de Cargo).
2. Fijar el layout FHS/XDG de la sección 4 como base de `AssignTable` **antes** de
   implementar `amicachy-dos`.
3. Añadir el `.desktop` de sesión Wayland (sección 3) desde el primer paquete, aunque el
   compositor aún sea un placeholder (fondo azul + texto, como en el plan original).
4. Empezar `packaging/` con Arch (reusa el patrón de AmiCachy); añadir Debian/Fedora
   cuando el compositor sea mínimamente usable.
5. AmiCachy (la ISO) pasa a consumir `amicachy-hle` como paquete externo para su modo de
   boot HLE, igual que ya hace con `amiberry`.
