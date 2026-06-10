# 04 — Sistema de ficheros, assigns y permisos

Cubre: el sistema de directorios estilo Amiga (assigns), el árbol físico bajo
`/opt/amicachy`, variables ENV/ENVARC, protection bits y el modelo de
usuarios/permisos.

## 1. El problema

Los usuarios de Amiga son reacios a `/root`, `/var`, `/usr`, `/lib`, `/bin`, `/home`.
AmiCachy debe ocultar la jerarquía Unix bajo un sistema de **assigns** tipo AmigaOS,
autoconfigurado. El usuario nunca ve rutas Unix: ve `LIBS:muimaster.library`, `C:Dir`,
`ENVARC:Workbench/ScreenMode`.

## 2. Assigns clásicos de AmigaOS

| Assign | Destino clásico |
|---|---|
| `SYS:` | Volumen del sistema (disco de arranque) |
| `Workbench:` | Alias de `SYS:` |
| `C:` | `SYS:C/` (comandos; análogo a `/usr/bin`) |
| `S:` | `SYS:S/` (scripts de arranque; análogo a `/etc`) |
| `L:` | `SYS:L/` (handlers de filesystem) |
| `LIBS:` | `SYS:Libs/` (librerías compartidas) |
| `DEVS:` | `SYS:Devs/` (drivers de devices) |
| `ENVARC:` | `SYS:Prefs/Env-Archive/` (variables persistentes) |
| `ENV:` | `RAM:Env/` (variables en memoria, volátil) |
| `RAM:` | Ramdisk |
| `FONTS:` | `SYS:Fonts/` |
| `T:` | `RAM:T/` (temporales) |

## 3. Árbol físico propuesto para AmiCachy

```
/opt/amicachy/                  ← raíz del sistema AmiCachy
├── System/                     ← SYS:
│   ├── C/                      ← C:  (comandos 68k)
│   ├── S/                      ← S:  (scripts)
│   ├── Libs/                   ← LIBS:
│   ├── Devs/                   ← DEVS:
│   ├── Fonts/                  ← FONTS:
│   ├── L/                      ← L:
│   └── Prefs/
│       └── Env-Archive/        ← ENVARC:
├── RAM/                        ← RAM: (tmpfs montado aquí)
│   ├── T/                      ← T:
│   └── Env/                    ← ENV:
├── Storage/                    ← almacenamiento del usuario
│   ├── Programs/               ← donde instala acp
│   ├── Floppies/               ← .adf
│   └── HardDrives/             ← .hdf / directorios montados
└── User/                       ← home del usuario Amiga
    ├── Documents/
    ├── Pictures/
    └── Music/
```

El usuario nunca necesita saber que existe `/opt/amicachy`.

Los binarios nativos x86 del propio sistema (compositor, acp, herramientas) viven en
rutas internas que el usuario tampoco ve:

```
/opt/amicachy/Native/bin/   ← binarios x86 del sistema
/opt/amicachy/Native/lib/   ← libamicachy-intuition.so, etc.
```

## 4. AssignTable en amicachy-dos

Resuelve cualquier ruta AmigaOS a ruta Linux. Cualquier `Open()`/`Lock()`/`Examine()`
de `amicachy-dos` pasa por `resolve()` antes de tocar el filesystem Linux:

```rust
pub struct AssignTable {
    assigns: HashMap<String, PathBuf>,
}

impl AssignTable {
    pub fn default() -> Self {
        let root = PathBuf::from("/opt/amicachy");
        let mut t = HashMap::new();
        t.insert("SYS",     root.join("System"));
        t.insert("C",       root.join("System/C"));
        t.insert("LIBS",    root.join("System/Libs"));
        t.insert("DEVS",    root.join("System/Devs"));
        t.insert("FONTS",   root.join("System/Fonts"));
        t.insert("ENVARC",  root.join("System/Prefs/Env-Archive"));
        t.insert("ENV",     PathBuf::from("/run/amicachy/env")); // tmpfs
        t.insert("T",       PathBuf::from("/run/amicachy/tmp")); // tmpfs
        t.insert("RAM",     PathBuf::from("/run/amicachy"));
        t.insert("User",    dirs::home_dir().unwrap().join("AmiCachy"));
        t
    }

    pub fn resolve(&self, amiga_path: &str) -> Option<PathBuf> {
        // "LIBS:muimaster.library" -> "/opt/amicachy/System/Libs/muimaster.library"
        if let Some((assign, rest)) = amiga_path.split_once(':') {
            self.assigns.get(assign)
                .map(|base| base.join(rest.trim_start_matches('/')))
        } else {
            None
        }
    }
}
```

### Detalle importante — path separator

AmigaOS usa `:` para separar el assign del path, y `/` tanto dentro de un volumen como
para indicar "directorio padre" (equivalente a `..` en Unix):

```
LIBS:                   → /opt/amicachy/System/Libs/
LIBS:muimaster.library  → /opt/amicachy/System/Libs/muimaster.library
/muimaster.library      → directorio padre (relativo)
```

`amicachy-dos` debe implementar esta semántica correctamente en `resolve()` **desde el
principio**, o aparecen bugs sutiles con software que usa paths relativos con `/`.

## 5. RAM: como tmpfs real

```
tmpfs /run/amicachy tmpfs mode=0755,uid=amiga,size=256M 0 0
```

Al arrancar, `amicachy-dos` crea `/run/amicachy/env/` y `/run/amicachy/tmp/` — igual
que un Amiga real al encender.

## 6. Variables de entorno AmigaOS (SetVar/GetVar)

Cada variable = un **fichero individual** en `ENV:`:

```
ENV:Workbench/ScreenMode  → contiene "1920x1080x32"
ENV:Sys/NoCapsLock        → existe el fichero = feature activa
ENVARC:                   → copia persistente de ENV:
```

En AmiCachy es literal: cada variable es un fichero en `/run/amicachy/env/`.
`GetVar`/`SetVar` leen/escriben ese fichero. Al apagar, `amicachy-desktop` sincroniza
`ENV:` → `ENVARC:` (persistencia, semántica original exacta).

## 7. Instalación de software (acp)

`acp install dopus` instala dentro del árbol AmiCachy, **nunca** toca `/usr`:

```
/opt/amicachy/System/C/DOpus            ← binario 68k
/opt/amicachy/System/Libs/dopus.library
/opt/amicachy/Storage/Programs/DOpus/   ← drawer, iconos, prefs
```

## 8. Panel de Preferencias de Assigns

Visual, sin editar ficheros:

```
AmiCachy Assigns Preferences
┌───────────────────────────────────┐
│ Work:   [/home/francisco/Amiga]   │  ← editable
│ Music:  [RAM:Music]               │
│ Extra:  [/mnt/disco_externo]      │  ← cualquier ruta Linux
└───────────────────────────────────┘
```

Internamente escribe en `ENVARC:`. El usuario nunca escribe una ruta Unix a mano.

## 9. Resumen visual usuario vs Linux

| Usuario ve | Linux ve |
|---|---|
| `SYS:Libs/` | `/opt/amicachy/System/Libs/` |
| `ENV:Workbench/ScreenMode` | `/run/amicachy/env/Workbench/ScreenMode` |
| `T:fichero-temporal` | `/run/amicachy/tmp/fichero-temporal` |
| `Work:MiProyecto/` | `/home/francisco/AmiCachy/MiProyecto/` |

El puente es `AssignTable` en `amicachy-dos`. El resto del sistema (HLE, acp, shell,
DASH) usa solo rutas AmigaOS.

## 10. Permisos, propietario, grupo

### Realidad de AmigaOS

**No existen** permisos de fichero. Sin usuarios, sin grupos, sin chmod/chown. Cualquier
proceso puede leer/escribir/borrar cualquier fichero. Lo único parecido son los
**protection bits** (puramente informativos/convencionales):

```
h  s  p  a  r  w  e  d
│  │  │  │  │  │  │  └─ deletable
│  │  │  │  │  │  └──── executable
│  │  │  │  │  └─────── writable
│  │  │  │  └────────── readable
│  │  │  └───────────── archived (flag de backup)
│  │  └──────────────── pure (reentrante, puede quedar en memoria)
│  └─────────────────── script
└────────────────────── hold (no expulsar de memoria)
```

Sin separación usuario/kernel. Sin root. Nada impide a un programa borrar el SO
completo.

### Capa 1 — Permisos Linux sobre /opt/amicachy

Todo el árbol pertenece a un usuario Linux dedicado `amiga`. `amicachy-desktop` corre
como `amiga` (usuario normal sin privilegios; no puede tocar `/usr`, `/etc`, homes de
otros, etc.):

```sh
useradd -r -m -d /opt/amicachy amiga
chown -R amiga:amiga /opt/amicachy
chmod 755 /opt/amicachy
```

El aislamiento Linux queda resuelto sin nada especial en el HLE.

### Capa 2 — Protection bits dentro del HLE

Cuando un binario llama `SetProtection("SYS:C/Dir", FIBF_DELETE)`:

- **Opción A — Mapear a permisos Linux reales** (`FIBF_READ`→`S_IRUSR`,
  `FIBF_WRITE`→`S_IWUSR`, `FIBF_EXECUTE`→`S_IXUSR`, `FIBF_DELETE`→`S_IWUSR` en el
  directorio). Funciona pero es aproximado.
- **Opción B — Extended attributes (xattr), RECOMENDADA:**

  ```rust
  xattr::set(path, "user.amicachy.protection", &bits.to_be_bytes())?;
  ```

  El fichero mantiene permisos Linux normales; los protection bits AmigaOS son metadata
  adicional vía xattr leída/escrita por `amicachy-dos`. Desacopla completamente ambos
  sistemas, semántica exacta.

### Capa 3 — Modelo multiusuario

- **Modelo A — Un único usuario `amiga`** (más fiel al original: sin multiusuario
  dentro del HLE, como AmigaOS real). **Recomendado para el arranque:** AmiCachy como
  *appliance* de un solo usuario; un PC = un usuario, sin complicaciones.
- **Modelo B — Mapear usuarios Linux a "usuarios" AmiCachy:** cada usuario Linux tiene
  su `~/AmiCachy/` propio; `System/` compartido en solo lectura; solo `amicachy-admin`
  instala en System:

  ```
  /opt/amicachy/System/    drwxr-xr-x  amicachy-admin:amicachy-admin
  /opt/amicachy/Storage/   drwxr-xr-x  (instalación compartida de paquetes)
  ~/AmiCachy/              drwx------  (ficheros personales por usuario)
      ├── ENV/
      ├── ENVARC/
      └── Work/
  ```

### Árbol de permisos recomendado (Modelo A)

```
/opt/amicachy/                drwxr-xr-x  amiga:amiga
├── System/                   drwxr-xr-x  amiga:amiga (lectura para todos)
│   ├── C/                    drwxr-xr-x  amiga:amiga
│   ├── Libs/                 drwxr-xr-x  amiga:amiga
│   └── Prefs/Env-Archive/    drwx------  amiga:amiga (privado)
├── Storage/Programs/         drwxrwxr-x  amiga:amiga (acp instala aquí)
├── RAM/ → tmpfs              drwxrwxrwt  amiga:amiga (sticky, como /tmp)
└── User/                     drwx------  amiga:amiga (privado)
```

`acp install` **no requiere sudo** — todo va a `/opt/amicachy/Storage/Programs/`,
propiedad de `amiga`. Igual que en AmigaOS real: descargas, ejecutas, sin permisos
especiales.

### Único caso que necesita privilegios

Actualizar el sistema base (kernel CachyOS, `amicachy-compositor`, `amicachy-exec`).
Gestionado por acp de forma transparente:

```
acp update          # paquetes de usuario, sin sudo
acp upgrade-system  # sistema base, pide contraseña
```

El usuario nunca ve sudo/terminal — ve un diálogo estilo AmigaOS:

```
┌───────────────────────────────────────┐
│  Sistema AmiCachy                     │
│                                       │
│  Actualizar el sistema requiere       │
│  confirmación de administrador.       │
│                                       │
│  Contraseña: [____________]           │
│                                       │
│  [Continuar]        [Cancelar]        │
└───────────────────────────────────────┘
```

Por debajo: `pkexec` o `sudo -S`.

### Tabla resumen

| Concepto | AmigaOS | AmiCachy-HLE |
|---|---|---|
| Permisos de fichero | No existen | Permisos Linux sobre `/opt/amicachy`, invisibles |
| Protection bits | 8 bits informativos | Almacenados en xattr, semántica exacta |
| Multiusuario | No existe | Un solo usuario `amiga`, como el original |
| Instalar software | Copiar ficheros | `acp install`, sin sudo, a `/opt/amicachy/Storage/` |
| Operaciones de sistema | No existe distinción | `acp upgrade-system` con diálogo visual, sin terminal |

**Filosofía:** Linux gestiona la seguridad real por debajo; AmiCachy presenta la
simplicidad de AmigaOS por arriba. El usuario solo ve permisos Unix si abre una terminal
Linux explícitamente.
