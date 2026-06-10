# 07 — Gestor de paquetes (acp) y repositorios

Cubre: el gestor unificado `acp`, el formato `.acz`, la integración con Aminet, la
estrategia de repositorios (CachyOS vs propio) y el hosting.

## 1. acp — AmiCachy Packages

**Problema:** dos mundos de binarios distintos:

- Repositorio nativo (x86/ARM): paquetes Linux normales.
- Repositorio 68k: Aminet (~25.000 paquetes existentes) + repo propio de AmiCachy.

**Recomendación:** un único frontend `acp` que abstrae ambos mundos:

```
acp install dopus       # Directory Opus 68k desde Aminet/repo propio
acp install vscode      # VS Code nativo vía pacman
acp search tracker      # busca en ambos repos
acp update              # actualiza todo
```

### Arquitectura

```
acp (CLI en Rust)
├── backend::native   → wrapper de pacman/libalpm
├── backend::hle68k   → gestor propio de binarios 68k
│   ├── source::aminet    (API/scraping de Aminet, índice plano "INDEX")
│   └── source::amicachy  (repositorio oficial propio)
└── store             → SQLite local (qué está instalado, de dónde, versión)
```

### Formato de paquete propio 68k: `.acz` (tar.zst + manifiesto TOML)

```toml
# MANIFEST.toml
name = "dopus5"
version = "5.82"
arch = "m68k"          # o "x86_64", "aarch64"
requires_hle = true    # necesita amicachy-intuition
depends = []
entry = "DOpus5/DOpus"
```

(El formato soporta también paquetes multi-arquitectura con varias entradas
`[[binary]]`; ver [06-dash-cross-target.md](06-dash-cross-target.md) §3.)

### Integración con Aminet

Aminet tiene una estructura de directorios pública y predecible
(`aminet.net/pub/aminet/...`) con `.lha` y un fichero `INDEX` plano. `acp` puede
descargar el índice, cachear metadatos en SQLite y descargar+extraer el `.lha` al
instalar. **Limitación:** Aminet no tiene metadatos de dependencias — curar manualmente
los paquetes más populares en el repo propio.

### Orden de implementación

1. `acp search`/`install` para Aminet (80 % del software retro disponible sin repo
   propio).
2. Store local SQLite.
3. `acp install` para nativo vía pacman (wrapper simple).
4. Repo propio (cuando haya software específico para AmiCachy-HLE no disponible en
   Aminet).

**Nota:** el gestor 68k solo tiene sentido completo cuando
`amicachy-intuition`/`amicachy-exec` funcionen, pero puede desarrollarse **en paralelo**
desde el principio (es independiente del emulador).

**Interfaz:** CLI primero; valorar una GUI estilo instalador del Workbench original más
adelante.

## 2. Repositorios de paquetes: CachyOS vs propio

**Situación actual:** AmiCachy ya bebe directamente de CachyOS
(`pacman-{generic,v3,v4}.conf` apuntan a sus repos).

### Corto plazo (ahora): seguir bebiendo de CachyOS directamente

- *Ventajas:* cero mantenimiento de infraestructura; kernels optimizados siempre
  actualizados; los 3 tiers de CPU (generic/v3/v4) gestionados por CachyOS.
- *Riesgos:* cambios de nombres/reorganización de repos por parte de CachyOS pueden
  romper la ISO sin aviso; dependencia de su uptime para builds.

### Medio plazo: repo OVERLAY propio (no reemplaza a CachyOS)

```
Arch repos (base)
    ▲
CachyOS repos (kernels optimizados, v3/v4)
    ▲
AmiCachy repo (paquetes propios: amicachy-compositor, acp,
               amicachy-exec, amiberry optimizado, …)
```

Solo se mantienen los paquetes propios; el resto sigue viniendo de CachyOS/Arch.

```sh
repo-add /srv/amicachy/amicachy.db.tar.gz nuevo-paquete.pkg.tar.zst
# (servido por nginx estático)
```

```ini
# pacman.conf — AmiCachy resuelve primero, CachyOS después
[amicachy]
Server = https://packages.amicachy.org/$arch
SigLevel = Required
[cachyos-v3]
Server = https://mirror.cachyos.org/repo/x86_64_v3/$repo
```

**Primer paquete que ya justifica repo propio:** `amiberry` (ya se compila con flags
específicos). Publicarlo en repo propio en lugar de copiarlo manualmente a la ISO
permite actualizaciones sin reconstruir la ISO completa.

**Infraestructura disponible:** un LXC en OVH (Proxmox) con nginx y ~5 GB de disco es
suficiente para empezar.

## 3. Alojamiento (proyecto bajo GitHub, sin dominio propio aún)

- **Opción A — GitHub Releases:** simple, pero las URLs cambian por release; no apto
  para `pacman -Sy` (necesita URL estable). **No recomendada.**
- **Opción B — GitHub Pages en el repo principal:** rama `gh-pages` o directorio
  `docs/` sirviendo el repo como sitio estático (p. ej.
  `freemem.github.io/AmiCachy/$arch`). URL estable, gratis.
- **Opción C — Repo dedicado `FreeMEM/amicachy-packages` con GitHub Pages**, separado
  del código fuente de la ISO. **RECOMENDADA.**

```ini
# pacman.conf
[amicachy]
Server = https://freemem.github.io/amicachy-packages/$arch
```

### Workflow de GitHub Actions

Build + publish automático al hacer push a `pkg/`, reutilizando el patrón Docker
existente (`build_iso_docker.sh`):

```yaml
on:
  push:
    paths: ['pkg/**']
jobs:
  build-and-publish:
    runs-on: ubuntu-latest
    container: cachyos/cachyos-base
    steps:
      - uses: actions/checkout@v4
      - run: cd pkg/amiberry && makepkg -s
      - run: repo-add amicachy.db.tar.gz *.pkg.tar.zst
      - uses: peaceiris/actions-gh-pages@v3
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./repo
```

### Cuándo migrar a infraestructura propia

Si GitHub Pages alcanza límites de ancho de banda (100 GB/mes), si se necesitan
paquetes firmados con GPG en serio, o si el proyecto crece y necesita mirrors. En ese
punto: cambiar una URL en `pacman.conf` hacia el LXC de OVH.
