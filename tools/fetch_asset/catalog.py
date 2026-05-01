"""Catalog loader — reads the JSON asset catalog into Asset dataclasses."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_CATALOG = "/usr/share/amicachy/asset-catalog.json"


def _resolve_path(path: str | Path | None) -> Path:
    """If path is None, honour AMICACHY_CATALOG env var, else fall back to
    the system-wide install location."""
    if path is not None:
        return Path(path)
    env = os.environ.get("AMICACHY_CATALOG")
    if env:
        return Path(env)
    return Path(DEFAULT_CATALOG)


@dataclass
class Asset:
    id: str
    name: str
    category: str
    summary: str
    homepage: str
    license_url: str
    license_summary: str
    url: str
    sha256: str
    size_bytes: int
    format: str
    install: dict = field(default_factory=dict)
    version: str = ""
    # 'catalog' for the curated system catalog, 'user' for entries the
    # user added manually via URL or local file.
    source: str = "catalog"


def _user_catalog_path() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "amicachy" / "user-catalog.json"


def _parse_entry(entry: dict, source: str) -> Asset:
    return Asset(
        id=entry["id"],
        name=entry["name"],
        category=entry.get("category", ""),
        summary=entry.get("summary", ""),
        homepage=entry.get("homepage", ""),
        license_url=entry.get("license_url", ""),
        license_summary=entry.get("license_summary", ""),
        url=entry["url"],
        sha256=entry.get("sha256", ""),
        size_bytes=int(entry.get("size_bytes", 0)),
        format=entry.get("format", "zip"),
        install=entry.get("install", {}),
        version=entry.get("version", ""),
        source=source,
    )


def load_catalog(path: str | Path | None = None) -> list[Asset]:
    """Read and parse the catalog. Returns [] if file is missing.

    Combines the curated system catalog (read-only, shipped with AmiCachy)
    with the user catalog (~/.config/amicachy/user-catalog.json) so the
    GUI sees both kinds of asset transparently.

    If `path` is None, AMICACHY_CATALOG env var is honoured for dev
    overrides; otherwise falls back to /usr/share/amicachy/asset-catalog.json.
    """
    out: list[Asset] = []

    p = _resolve_path(path)
    if p.is_file():
        with open(p) as f:
            data = json.load(f)
        for entry in data.get("assets", []):
            out.append(_parse_entry(entry, source="catalog"))

    out.extend(load_user_catalog())
    return out


def load_user_catalog() -> list[Asset]:
    """Read user-added assets from ~/.config/amicachy/user-catalog.json."""
    p = _user_catalog_path()
    if not p.is_file():
        return []
    try:
        with open(p) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        return []
    out: list[Asset] = []
    for entry in data.get("assets", []):
        try:
            out.append(_parse_entry(entry, source="user"))
        except KeyError:
            # Malformed entry — skip it rather than crash the whole UI.
            continue
    return out


def save_user_asset(asset: Asset) -> None:
    """Persist (or overwrite by id) a user-added Asset.

    Atomic write: serialize to a sibling .tmp, then rename. Survives a
    power cut without leaving a half-written JSON behind.
    """
    p = _user_catalog_path()
    p.parent.mkdir(parents=True, exist_ok=True)

    if p.is_file():
        try:
            with open(p) as f:
                data = json.load(f)
        except json.JSONDecodeError:
            data = {"schema_version": 1, "assets": []}
    else:
        data = {"schema_version": 1, "assets": []}

    data.setdefault("assets", [])
    data["assets"] = [a for a in data["assets"] if a.get("id") != asset.id]
    data["assets"].append({
        "id": asset.id,
        "name": asset.name,
        "category": asset.category,
        "summary": asset.summary,
        "homepage": asset.homepage,
        "license_url": asset.license_url,
        "license_summary": asset.license_summary,
        "url": asset.url,
        "sha256": asset.sha256,
        "size_bytes": asset.size_bytes,
        "format": asset.format,
        "install": asset.install,
        "version": asset.version,
    })

    tmp = p.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    tmp.replace(p)


def remove_user_asset(asset_id: str) -> None:
    """Drop the entry from the user catalog if it exists. Idempotent."""
    p = _user_catalog_path()
    if not p.is_file():
        return
    try:
        with open(p) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        return
    before = len(data.get("assets", []))
    data["assets"] = [a for a in data.get("assets", []) if a.get("id") != asset_id]
    if len(data["assets"]) == before:
        return
    tmp = p.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    tmp.replace(p)


def get_asset(catalog: list[Asset], asset_id: str) -> Asset | None:
    for a in catalog:
        if a.id == asset_id:
            return a
    return None
