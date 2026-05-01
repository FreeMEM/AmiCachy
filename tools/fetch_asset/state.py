"""Persistent state — accepted licenses and installed-asset records.

Lives at ~/.config/amicachy/assets.json so it survives across sessions
without depending on the catalog file location."""

from __future__ import annotations

import datetime as _dt
import json
import os
from pathlib import Path
from typing import Any


def _state_path() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "amicachy" / "assets.json"


def _load() -> dict[str, Any]:
    p = _state_path()
    if not p.is_file():
        return {"accepted_licenses": [], "installed": {}}
    try:
        with open(p) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"accepted_licenses": [], "installed": {}}
    data.setdefault("accepted_licenses", [])
    data.setdefault("installed", {})
    return data


def _save(data: dict[str, Any]) -> None:
    p = _state_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    tmp.replace(p)


def is_accepted(asset_id: str) -> bool:
    return asset_id in _load()["accepted_licenses"]


def mark_accepted(asset_id: str) -> None:
    data = _load()
    if asset_id not in data["accepted_licenses"]:
        data["accepted_licenses"].append(asset_id)
        _save(data)


def is_installed(asset_id: str) -> bool:
    return asset_id in _load()["installed"]


def installed_record(asset_id: str) -> dict[str, Any] | None:
    return _load()["installed"].get(asset_id)


def mark_installed(asset_id: str, path: str, sha256: str = "") -> None:
    data = _load()
    data["installed"][asset_id] = {
        "path": path,
        "sha256": sha256,
        "installed_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
    }
    _save(data)


def mark_uninstalled(asset_id: str) -> None:
    data = _load()
    data["installed"].pop(asset_id, None)
    _save(data)
