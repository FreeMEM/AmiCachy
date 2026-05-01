"""Core install pipeline — download, verify, extract, register a UAE config.

Frontends (CLI, Qt) call install_asset() with a progress callback.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from typing import Callable

from . import catalog as _catalog
from . import presets, state
from .catalog import Asset


CHUNK = 64 * 1024


class InstallError(Exception):
    pass


# Stage names emitted via progress_cb(stage, current, total).
# total may be 0 for indeterminate progress.
STAGE_DOWNLOAD = "download"
STAGE_VERIFY = "verify"
STAGE_EXTRACT = "extract"
STAGE_REGISTER = "register"


def _expand(p: str) -> Path:
    return Path(os.path.expanduser(os.path.expandvars(p)))


def _cache_dir() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    d = Path(base) / "amicachy" / "downloads"
    d.mkdir(parents=True, exist_ok=True)
    return d


# ---------------------------------------------------------------------------
# Download with HTTP-Range resume
# ---------------------------------------------------------------------------


def download(
    url: str,
    dest: Path,
    progress_cb: Callable[[str, int, int], None] | None = None,
    resume: bool = True,
) -> Path:
    """Download URL to dest. If `resume`, append using HTTP Range when possible.

    Emits ('download', bytes_so_far, total_bytes) progress events.
    """
    headers = {"User-Agent": "AmiCachy fetch_asset/1.0"}
    existing = dest.stat().st_size if (resume and dest.exists()) else 0
    if existing:
        headers["Range"] = f"bytes={existing}-"

    req = urllib.request.Request(url, headers=headers)
    try:
        r = urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as e:
        # 416 Requested Range Not Satisfiable → file already complete; let the
        # caller verify the checksum to decide whether to keep or redownload.
        if e.code == 416:
            return dest
        raise InstallError(f"HTTP {e.code} fetching {url}: {e.reason}") from e
    except urllib.error.URLError as e:
        raise InstallError(f"network error fetching {url}: {e.reason}") from e

    with r:
        # Some servers ignore Range and return 200 with full body.
        if existing and r.status == 200:
            existing = 0
            dest.unlink(missing_ok=True)
            headers.pop("Range", None)

        total = int(r.headers.get("Content-Length", 0))
        if existing:
            total += existing

        mode = "ab" if existing else "wb"
        downloaded = existing
        with open(dest, mode) as f:
            while True:
                chunk = r.read(CHUNK)
                if not chunk:
                    break
                f.write(chunk)
                downloaded += len(chunk)
                if progress_cb is not None:
                    progress_cb(STAGE_DOWNLOAD, downloaded, total)
    return dest


# ---------------------------------------------------------------------------
# Checksum verification
# ---------------------------------------------------------------------------


def verify_sha256(
    path: Path,
    expected: str,
    progress_cb: Callable[[str, int, int], None] | None = None,
) -> bool:
    h = hashlib.sha256()
    total = path.stat().st_size
    done = 0
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
            done += len(chunk)
            if progress_cb is not None:
                progress_cb(STAGE_VERIFY, done, total)
    return h.hexdigest() == expected.lower()


# ---------------------------------------------------------------------------
# Archive extraction
# ---------------------------------------------------------------------------


def _safe_extract_zip(archive: Path, target: Path) -> None:
    """Reject zip-slip paths (members escaping target) before extracting."""
    target = target.resolve()
    with zipfile.ZipFile(archive) as z:
        for m in z.infolist():
            dest = (target / m.filename).resolve()
            if not str(dest).startswith(str(target)):
                raise InstallError(f"unsafe zip member: {m.filename!r}")


def extract(
    archive: Path,
    target: Path,
    fmt: str,
    progress_cb: Callable[[str, int, int], None] | None = None,
) -> None:
    target.mkdir(parents=True, exist_ok=True)
    if fmt == "zip":
        _safe_extract_zip(archive, target)
        with zipfile.ZipFile(archive) as z:
            members = z.infolist()
            n = len(members)
            for i, m in enumerate(members, 1):
                z.extract(m, target)
                if progress_cb is not None and (i % 16 == 0 or i == n):
                    progress_cb(STAGE_EXTRACT, i, n)
    else:
        raise InstallError(f"unsupported archive format: {fmt}")


# ---------------------------------------------------------------------------
# UAE config generation
# ---------------------------------------------------------------------------


def find_largest_hdf(directory: Path) -> Path | None:
    candidates = list(directory.rglob("*.hdf")) + list(directory.rglob("*.HDF"))
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_size)


# AmigaOS / Workbench install root looks like this. We need at least these
# directories to be present to consider a folder an Amiga filesystem root.
_AMIGA_FS_MARKERS = {"C", "S", "Libs", "Devs"}


def find_amiga_fs_root(directory: Path) -> Path | None:
    """Locate a child directory that looks like an Amiga FS root.

    Many Amiga bundles (AROS Vision, ClassicWB, Estrayk RTG, …) ship a
    deployed filesystem rather than a hardfile image. The root tells
    itself apart by always containing at least C/, S/, Libs/, Devs/.

    Searches `directory` and up to ~3 levels of descendants; returns the
    first match (BFS-ish: shallower wins). None if not found.
    """
    queue: list[tuple[Path, int]] = [(directory, 0)]
    max_depth = 3
    while queue:
        cand, depth = queue.pop(0)
        try:
            children = {e.name for e in cand.iterdir() if e.is_dir()}
        except OSError:
            continue
        if _AMIGA_FS_MARKERS <= children:
            return cand
        if depth < max_depth:
            for c in sorted(cand.iterdir()):
                if c.is_dir():
                    queue.append((c, depth + 1))
    return None


def _substitute(value, ctx: dict[str, str]):
    """Replace ${KEY} placeholders in string values from `ctx`."""
    if not isinstance(value, str):
        return value
    out = value
    for key, val in ctx.items():
        out = out.replace(f"${{{key}}}", val)
    return out


_UAE_BOILERPLATE = (
    "gfx_width=720",
    "gfx_height=568",
    "gfx_fullscreen_amiga=true",
    "amiberry.gfx_auto_crop=true",
    "sound_output=exact",
    "sound_channels=stereo",
    "sound_frequency=44100",
    "joyport0=mouse",
    "joyport1=joy1",
)


def _render_template_lines(template: dict, ctx: dict[str, str]) -> list[str]:
    """Serialize a uae_template dict into 'key=value' lines, with placeholder
    substitution and bool→true/false coercion."""
    lines = ["; AmiCachy — auto-generated by fetch_asset"]
    for key, value in template.items():
        if isinstance(value, bool):
            value = "true" if value else "false"
        else:
            value = _substitute(value, ctx)
        lines.append(f"{key}={value}")
    return lines


def render_uae_template_hdf(
    template: dict,
    hdf_path: Path,
    extract_root: Path,
) -> str:
    """Generate a .uae anchoring DH0 to a hardfile (.hdf).

    The hardfile2 / uaehf0 line format mirrors what Amiberry itself writes
    when it saves a config from the GUI (surfaces=0, sectors=0, reserved=0,
    blocksize=512, bootpri=0, filesys=empty, uaeN). Anything else gets
    rejected by cfgfile_load.
    """
    ctx = {
        "EXTRACT_ROOT": str(extract_root),
        "HDF": str(hdf_path),
    }
    lines = _render_template_lines(template, ctx)
    hf = f"rw,DH0:{hdf_path},0,0,0,512,0,,uae0"
    lines.append(f"hardfile2={hf}")
    lines.append(f"uaehf0=hdf,{hf}")
    lines.extend(_UAE_BOILERPLATE)
    return "\n".join(lines) + "\n"


def render_uae_template_fs(
    template: dict,
    fs_root: Path,
    extract_root: Path,
    volume_name: str = "System",
) -> str:
    """Generate a .uae anchoring DH0 to a directory mount (filesystem2=).

    Used by bundles distributed as a deployed Amiga filesystem (Workbench
    laid out on disk) instead of a hardfile image. AROS Vision is the
    poster child for this mode.
    """
    ctx = {
        "EXTRACT_ROOT": str(extract_root),
        "FS_ROOT": str(fs_root),
        "VOLUME": volume_name,
    }
    lines = _render_template_lines(template, ctx)
    spec = f"rw,DH0:{volume_name}:{fs_root},0"
    lines.append(f"filesystem2={spec}")
    lines.append(f"uaehf0=dir,{spec}")
    lines.extend(_UAE_BOILERPLATE)
    return "\n".join(lines) + "\n"


# Kept for backward compatibility with tests / callers that imported the
# old name; new code should pick the explicit *_hdf or *_fs variant.
def render_uae_template(template: dict, hdf_path: Path) -> str:
    return render_uae_template_hdf(template, hdf_path, hdf_path.parent)


def register_uae(asset: Asset, extracted_root: Path) -> Path | None:
    """Generate ~/Amiberry/conf/amicachy-<id>.uae for an installed asset.

    Branches on install.layout:
      - 'hdf-bundle'         (default): find the largest .hdf and write
        a hardfile2= entry.
      - 'filesystem-bundle': find an Amiga FS root (C/S/Libs/Devs) and
        write a filesystem2= entry mounting that directory.
      - anything else (or auto_detect_hdf=False with no layout): no .uae.
    """
    spec = asset.install
    layout = spec.get("layout")
    if layout is None:
        # Backward compat: old catalog entries used auto_detect_hdf=true.
        layout = "hdf-bundle" if spec.get("auto_detect_hdf") else None
    if layout is None:
        return None

    template = spec.get("uae_template", {})

    if layout == "hdf-bundle":
        hdf = find_largest_hdf(extracted_root)
        if hdf is None:
            return None
        text = render_uae_template_hdf(template, hdf, extracted_root)
    elif layout == "filesystem-bundle":
        fs_root = find_amiga_fs_root(extracted_root)
        if fs_root is None:
            return None
        volume = spec.get("volume_name", "System")
        text = render_uae_template_fs(template, fs_root, extracted_root, volume)
    else:
        return None

    out = Path.home() / "Amiberry" / "conf" / f"amicachy-{asset.id}.uae"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    return out


# ---------------------------------------------------------------------------
# Top-level pipeline
# ---------------------------------------------------------------------------


def install_asset(
    asset: Asset,
    progress_cb: Callable[[str, int, int], None] | None = None,
    keep_archive: bool = False,
) -> Path:
    """Download, verify, extract and register `asset`. Returns the install dir.

    Requires that the user has previously called state.mark_accepted(asset.id).
    """
    if not state.is_accepted(asset.id):
        raise InstallError(
            f"License for '{asset.id}' has not been accepted. "
            f"Call state.mark_accepted() first."
        )

    archive = _cache_dir() / f"{asset.id}.{asset.format}"
    download(asset.url, archive, progress_cb=progress_cb)

    if not verify_sha256(archive, asset.sha256, progress_cb=progress_cb):
        archive.unlink(missing_ok=True)
        raise InstallError(
            f"sha256 mismatch — expected {asset.sha256}. "
            f"The archive was deleted; re-run install to retry."
        )

    extract_to = _expand(asset.install["extract_to"])
    extract(archive, extract_to, asset.format, progress_cb=progress_cb)

    if progress_cb is not None:
        progress_cb(STAGE_REGISTER, 0, 1)
    register_uae(asset, extract_to)
    if progress_cb is not None:
        progress_cb(STAGE_REGISTER, 1, 1)

    state.mark_installed(asset.id, str(extract_to), sha256=asset.sha256)

    if not keep_archive:
        archive.unlink(missing_ok=True)

    return extract_to


def uninstall_asset(asset_id: str) -> None:
    record = state.installed_record(asset_id)
    if record is None:
        return
    path = Path(record["path"])
    if path.exists():
        shutil.rmtree(path, ignore_errors=True)
    uae = Path.home() / "Amiberry" / "conf" / f"amicachy-{asset_id}.uae"
    uae.unlink(missing_ok=True)
    state.mark_uninstalled(asset_id)
    # Drop user-catalog entry too — for catalog assets this is a no-op,
    # for manually-added ones it makes them disappear from the GUI list.
    _catalog.remove_user_asset(asset_id)


# ---------------------------------------------------------------------------
# Manual install (Custom URL)
# ---------------------------------------------------------------------------


_SLUG_RE = re.compile(r"[^a-z0-9]+")


def _slugify(text: str, fallback: str = "asset") -> str:
    """Make a stable, filesystem-safe id from arbitrary user input."""
    s = _SLUG_RE.sub("-", (text or "").strip().lower()).strip("-")
    return (s or fallback)[:48]


def _filename_from_url(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    return Path(parsed.path).name or "download"


def install_from_url(
    url: str,
    name: str,
    base_profile_id: str,
    expected_sha256: str = "",
    progress_cb: Callable[[str, int, int], None] | None = None,
    keep_archive: bool = False,
) -> Asset:
    """Manual install from an arbitrary URL.

    Builds an Asset on the fly, runs the standard pipeline, persists the
    Asset to the user catalog so it shows up in the GUI list afterwards.

    The caller MUST have collected the user's responsibility-acceptance
    BEFORE calling this — there's no upstream license to display.

    `expected_sha256` is optional. If provided, the archive is verified
    against it. If omitted, the sha256 is computed and stored in the
    user catalog so subsequent reinstalls can detect upstream changes.

    Currently supports format=zip only. Local files / .hdf raw / .rom
    will be added in the next phases.
    """
    if not url:
        raise InstallError("URL is required.")
    if not url.lower().startswith(("http://", "https://")):
        raise InstallError("URL must use http:// or https://")

    fname = _filename_from_url(url)
    if not fname.lower().endswith(".zip"):
        raise InstallError(
            "Only .zip archives are supported for URL installs in this version. "
            "Local file support (.hdf, .rom) is coming next."
        )

    display_name = name.strip() or fname
    asset_id = f"manual-{_slugify(name or fname)}"

    template = presets.get_preset(base_profile_id)
    install_spec = {
        "extract_to": f"~/Amiberry/harddrives/{asset_id}",
        "auto_detect_hdf": template is not None,
        "uae_template": template or {},
    }

    asset = Asset(
        id=asset_id,
        name=display_name,
        category="manual",
        summary=f"Manually added by user from {url}",
        homepage=url,
        license_url="",
        license_summary=(
            "User-provided asset. AmiCachy does not host or vouch for its "
            "contents. The user has accepted full responsibility for legality "
            "and licensing."
        ),
        url=url,
        sha256=expected_sha256,
        size_bytes=0,
        format="zip",
        install=install_spec,
        version="",
        source="user",
    )

    # The caller already obtained consent; record it explicitly so the
    # rest of install_asset's contract (mark_accepted is required) is met.
    state.mark_accepted(asset.id)

    archive = _cache_dir() / f"{asset.id}.{asset.format}"
    download(asset.url, archive, progress_cb=progress_cb)

    actual = _hash_file(archive, progress_cb=progress_cb)
    if expected_sha256 and actual.lower() != expected_sha256.lower():
        archive.unlink(missing_ok=True)
        raise InstallError(
            f"sha256 mismatch — expected {expected_sha256}, got {actual}"
        )
    asset.sha256 = actual
    asset.size_bytes = archive.stat().st_size

    extract_to = _expand(asset.install["extract_to"])
    extract(archive, extract_to, asset.format, progress_cb=progress_cb)

    if progress_cb is not None:
        progress_cb(STAGE_REGISTER, 0, 1)
    register_uae(asset, extract_to)
    if progress_cb is not None:
        progress_cb(STAGE_REGISTER, 1, 1)

    _catalog.save_user_asset(asset)
    state.mark_installed(asset.id, str(extract_to), sha256=asset.sha256)

    if not keep_archive:
        archive.unlink(missing_ok=True)

    return asset


def _hash_file(
    path: Path,
    progress_cb: Callable[[str, int, int], None] | None = None,
) -> str:
    """Compute sha256 of `path`, emitting verify-stage progress events."""
    h = hashlib.sha256()
    total = path.stat().st_size
    done = 0
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
            done += len(chunk)
            if progress_cb is not None:
                progress_cb(STAGE_VERIFY, done, total)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Manual install (Local file)
# ---------------------------------------------------------------------------


_HDF_MAGICS = (
    b"RDSK",       # Rigid Disk Block — full disk images
    b"DOS\x00",    # OFS
    b"DOS\x01",    # FFS
    b"DOS\x02",    # OFS-INTL
    b"DOS\x03",    # FFS-INTL
    b"DOS\x04",    # OFS-DC
    b"DOS\x05",    # FFS-DC
)


def _looks_like_hdf(path: Path) -> bool:
    """Best-effort sanity check on a presumed Amiga hardfile.

    HDFs come in two shapes: full disk images that start with an RDSK at
    sector 0, and partition-only images that start with the DH0 boot
    block ('DOS\\xNN'). Anything else is suspicious.
    """
    try:
        with open(path, "rb") as f:
            header = f.read(8)
    except OSError:
        return False
    return any(header.startswith(m) for m in _HDF_MAGICS)


def _detect_local_format(path: Path) -> str:
    """Return 'zip' or 'hdf' from filename. Anything else raises."""
    suffix = path.suffix.lower()
    if suffix == ".zip":
        return "zip"
    if suffix == ".hdf":
        return "hdf"
    raise InstallError(
        f"Unsupported file extension '{suffix}'. "
        f"Phase 2 supports only .zip and .hdf — .rom and .adf land in phase 3."
    )


def _copy_with_progress(
    src: Path,
    dst: Path,
    progress_cb: Callable[[str, int, int], None] | None = None,
) -> None:
    """Stream-copy preserving progress events. Avoids loading the whole
    file in memory (HDFs can be multi-GB)."""
    total = src.stat().st_size
    done = 0
    with open(src, "rb") as fin, open(dst, "wb") as fout:
        while True:
            chunk = fin.read(CHUNK)
            if not chunk:
                break
            fout.write(chunk)
            done += len(chunk)
            if progress_cb is not None:
                progress_cb(STAGE_EXTRACT, done, total)


def install_from_file(
    path: str | Path,
    name: str,
    base_profile_id: str,
    progress_cb: Callable[[str, int, int], None] | None = None,
) -> Asset:
    """Manual install from a local file path (zip or hdf raw).

    Mirrors install_from_url() but the source is on the filesystem
    (typically a USB pendrive automounted under /run/media/$USER, or
    a file in the user's home).

    Caller MUST have collected the user's responsibility-acceptance
    BEFORE calling this — no upstream license to display.
    """
    src = Path(path).expanduser().resolve()
    if not src.is_file():
        raise InstallError(f"File not found: {src}")

    fmt = _detect_local_format(src)

    if fmt == "hdf" and not _looks_like_hdf(src):
        raise InstallError(
            f"{src.name} doesn't look like an Amiga hardfile "
            f"(no RDSK or DOS\\xNN magic at offset 0)."
        )

    display_name = name.strip() or src.stem
    asset_id = f"manual-{_slugify(display_name)}"

    template = presets.get_preset(base_profile_id)
    extract_to = _expand(f"~/Amiberry/harddrives/{asset_id}")

    asset = Asset(
        id=asset_id,
        name=display_name,
        category="manual",
        summary=f"Manually added by user from {src}",
        homepage=f"file://{src}",
        license_url="",
        license_summary=(
            "User-provided asset. AmiCachy does not host or vouch for its "
            "contents. The user has accepted full responsibility for legality "
            "and licensing."
        ),
        url=f"file://{src}",
        sha256="",
        size_bytes=src.stat().st_size,
        format=fmt,
        install={
            "extract_to": str(extract_to),
            "auto_detect_hdf": template is not None,
            "uae_template": template or {},
        },
        version="",
        source="user",
    )

    state.mark_accepted(asset.id)

    extract_to.mkdir(parents=True, exist_ok=True)

    if fmt == "zip":
        # Reuse the same safe-extract pipeline as the catalog flow.
        # We hash from the source file, not a copy in cache, so a 4 GB
        # HDF inside a zip doesn't get duplicated to disk.
        asset.sha256 = _hash_file(src, progress_cb=progress_cb)
        extract(src, extract_to, "zip", progress_cb=progress_cb)
    else:  # fmt == "hdf"
        # Raw HDF: copy into the asset dir so uninstall can rmtree
        # cleanly without touching the user's source media.
        dst = extract_to / src.name
        _copy_with_progress(src, dst, progress_cb=progress_cb)
        # Hash the destination — covers cases where the source was on
        # a flaky USB and the copy diverged.
        asset.sha256 = _hash_file(dst, progress_cb=progress_cb)

    if progress_cb is not None:
        progress_cb(STAGE_REGISTER, 0, 1)
    register_uae(asset, extract_to)
    if progress_cb is not None:
        progress_cb(STAGE_REGISTER, 1, 1)

    _catalog.save_user_asset(asset)
    state.mark_installed(asset.id, str(extract_to), sha256=asset.sha256)

    return asset


def list_removable_mounts() -> list[Path]:
    """Discover paths likely to be USB pendrives automounted by udisks2.

    Returns a list of directory paths the user can browse for assets.
    Order: most likely useful first. Empty if no candidates exist.
    """
    user = os.environ.get("USER") or "amiga"
    candidates: list[Path] = []
    for base in (Path("/run/media") / user, Path("/media") / user, Path("/run/media")):
        if base.is_dir():
            try:
                for entry in sorted(base.iterdir()):
                    if entry.is_dir():
                        candidates.append(entry)
            except OSError:
                continue
    # Deduplicate while preserving order.
    seen: set[Path] = set()
    out: list[Path] = []
    for p in candidates:
        rp = p.resolve()
        if rp in seen:
            continue
        seen.add(rp)
        out.append(p)
    return out
