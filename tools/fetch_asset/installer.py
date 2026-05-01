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


def render_uae_template(template: dict, hdf_path: Path) -> str:
    """Render a UAE config from the template dict, anchoring DH0 to the HDF.

    The hardfile2 / uaehf0 line format mirrors what Amiberry itself writes
    when it saves a config from the GUI (surfaces=0,sectors=0,reserved=0,
    blocksize=512,bootpri=0,filesys=empty,uaeN). Anything else gets
    rejected by cfgfile_load.
    """
    lines = ["; AmiCachy — auto-generated by fetch_asset"]
    for key, value in template.items():
        if isinstance(value, bool):
            value = "true" if value else "false"
        lines.append(f"{key}={value}")
    hf = f"rw,DH0:{hdf_path},0,0,0,512,0,,uae0"
    lines.append(f"hardfile2={hf}")
    lines.append(f"uaehf0=hdf,{hf}")
    lines.append("gfx_width=720")
    lines.append("gfx_height=568")
    lines.append("gfx_fullscreen_amiga=true")
    lines.append("amiberry.gfx_auto_crop=true")
    lines.append("sound_output=exact")
    lines.append("sound_channels=stereo")
    lines.append("sound_frequency=44100")
    lines.append("joyport0=mouse")
    lines.append("joyport1=joy1")
    return "\n".join(lines) + "\n"


def register_uae(asset: Asset, extracted_root: Path) -> Path | None:
    """If the install spec says auto_detect_hdf, generate ~/Amiberry/conf/<id>.uae."""
    spec = asset.install
    if not spec.get("auto_detect_hdf"):
        return None
    hdf = find_largest_hdf(extracted_root)
    if hdf is None:
        return None
    template = spec.get("uae_template", {})
    text = render_uae_template(template, hdf)
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
