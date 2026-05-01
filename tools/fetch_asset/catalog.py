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


def load_catalog(path: str | Path | None = None) -> list[Asset]:
    """Read and parse the catalog. Returns [] if file is missing.

    If `path` is None, AMICACHY_CATALOG env var is honoured for dev
    overrides; otherwise falls back to /usr/share/amicachy/asset-catalog.json.
    """
    p = _resolve_path(path)
    if not p.is_file():
        return []
    with open(p) as f:
        data = json.load(f)
    out: list[Asset] = []
    for entry in data.get("assets", []):
        out.append(Asset(
            id=entry["id"],
            name=entry["name"],
            category=entry.get("category", ""),
            summary=entry.get("summary", ""),
            homepage=entry.get("homepage", ""),
            license_url=entry.get("license_url", ""),
            license_summary=entry.get("license_summary", ""),
            url=entry["url"],
            sha256=entry["sha256"],
            size_bytes=int(entry.get("size_bytes", 0)),
            format=entry.get("format", "zip"),
            install=entry.get("install", {}),
            version=entry.get("version", ""),
        ))
    return out


def get_asset(catalog: list[Asset], asset_id: str) -> Asset | None:
    for a in catalog:
        if a.id == asset_id:
            return a
    return None
