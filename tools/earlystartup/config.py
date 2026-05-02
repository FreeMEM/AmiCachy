"""Early Startup Control — config discovery and UAE generation."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

ROM_DIRS = ["/home/amiga/Amiberry/roms", "/usr/share/amiberry/roms"]
HDF_DIRS = ["/home/amiga/Amiberry/harddrives"]
BASE_UAE = "/usr/share/amicachy/uae/a1200.uae"
SESSION_UAE = "/tmp/amicachy-session.uae"
SAVED_UAE = "/home/amiga/Amiberry/conf/amicachy-default.uae"

USER_CONF_DIR = "/home/amiga/Amiberry/conf"
SESSION_CONFIG = "/tmp/amicachy-session-config"
BOOT_CONFIG = "/home/amiga/Amiberry/conf/amicachy-boot-config"

AROS_ROM = "/usr/share/amiberry/roms/aros-rom.bin"
AROS_EXT = "/usr/share/amiberry/roms/aros-ext.bin"

# (label, chipmem_size value for UAE)
CHIP_RAM_OPTIONS = [("512 KB", 1), ("1 MB", 2), ("2 MB", 4)]
# (label, fastmem_size value for UAE)
FAST_RAM_OPTIONS = [("None", 0), ("2 MB", 2), ("4 MB", 4), ("8 MB", 8)]

# Internal filenames that should not appear in the profile selector
_INTERNAL_FILES = {"amicachy-default.uae", "amicachy-boot-config"}


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------


@dataclass
class RomEntry:
    """A Kickstart ROM discovered on disk."""

    label: str  # e.g. "AROS 3.1.4 (built-in)"
    path: str  # absolute path to .rom
    ext_path: str | None = None  # extended ROM (AROS only)


# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------

_AROS_BASENAMES = {"aros-rom.bin", "aros-ext.bin"}


def _rom_label(filename: str) -> str:
    """Generate a human-readable label from a ROM filename."""
    name = Path(filename).stem  # strip extension
    # Replace common separators with spaces
    name = name.replace("_", " ").replace("-", " ")
    # Title-case
    return name.title()


def scan_roms() -> list[RomEntry]:
    """Scan ROM_DIRS for *.rom files. AROS is always first."""
    entries: list[RomEntry] = []

    # AROS is always the first entry if its files exist
    if os.path.isfile(AROS_ROM):
        entries.append(
            RomEntry(
                label="AROS (built-in)",
                path=AROS_ROM,
                ext_path=AROS_EXT if os.path.isfile(AROS_EXT) else None,
            )
        )

    seen: set[str] = set()
    for rom_dir in ROM_DIRS:
        if not os.path.isdir(rom_dir):
            continue
        for fname in sorted(os.listdir(rom_dir)):
            if not fname.lower().endswith(".rom"):
                continue
            if fname.lower() in _AROS_BASENAMES:
                continue
            full = os.path.join(rom_dir, fname)
            real = os.path.realpath(full)
            if real in seen:
                continue
            seen.add(real)
            entries.append(RomEntry(label=_rom_label(fname), path=full))

    return entries


def scan_hdfs() -> list[str]:
    """Scan HDF_DIRS for *.hdf files. Returns absolute paths sorted."""
    paths: list[str] = []
    seen: set[str] = set()

    for hdf_dir in HDF_DIRS:
        if not os.path.isdir(hdf_dir):
            continue
        for fname in sorted(os.listdir(hdf_dir)):
            if not fname.lower().endswith(".hdf"):
                continue
            full = os.path.join(hdf_dir, fname)
            real = os.path.realpath(full)
            if real in seen:
                continue
            seen.add(real)
            paths.append(full)

    return paths


def scan_user_configs() -> list[str]:
    """List .uae and .fs-uae files in USER_CONF_DIR, excluding internal files.

    Returns absolute paths sorted by filename. Both Amiberry (.uae) and
    FS-UAE (.fs-uae) profiles live in the same directory; amilaunch.sh
    dispatches to the right emulator at boot time based on the file
    extension. The user can pick either kind from the same dropdown.
    """
    configs: list[str] = []
    if not os.path.isdir(USER_CONF_DIR):
        return configs
    for fname in sorted(os.listdir(USER_CONF_DIR)):
        lower = fname.lower()
        if not (lower.endswith(".uae") or lower.endswith(".fs-uae")):
            continue
        if fname in _INTERNAL_FILES:
            continue
        configs.append(os.path.join(USER_CONF_DIR, fname))
    return configs


def emulator_for(path: str) -> str:
    """Return 'fs-uae' or 'amiberry' depending on the config file extension."""
    return "fs-uae" if path.lower().endswith(".fs-uae") else "amiberry"


# ---------------------------------------------------------------------------
# Boot config references (path-based)
# ---------------------------------------------------------------------------


def read_boot_ref() -> str | None:
    """Read persistent boot config reference. Returns path or None."""
    if not os.path.isfile(BOOT_CONFIG):
        return None
    try:
        path = Path(BOOT_CONFIG).read_text().strip()
        if path and os.path.isfile(path):
            return path
    except OSError:
        pass
    return None


def get_initial_uae_path() -> str:
    """Return the best existing config: boot ref, saved custom, or default."""
    ref = read_boot_ref()
    if ref:
        return ref
    if os.path.isfile(SAVED_UAE):
        return SAVED_UAE
    return BASE_UAE


def write_session_ref(config_path: str) -> None:
    """Write config path reference for this session."""
    with open(SESSION_CONFIG, "w") as f:
        f.write(config_path + "\n")


def write_boot_ref(config_path: str) -> str | None:
    """Write persistent boot config reference. Returns error or None."""
    try:
        os.makedirs(os.path.dirname(BOOT_CONFIG), exist_ok=True)
        with open(BOOT_CONFIG, "w") as f:
            f.write(config_path + "\n")
    except OSError as exc:
        return str(exc)
    return None


# ---------------------------------------------------------------------------
# UAE read / write
# ---------------------------------------------------------------------------

_UAE_KEYS = {
    "kickstart_rom_file",
    "kickstart_ext_rom_file",
    "chipmem_size",
    "fastmem_size",
}


def read_uae_values(path: str) -> dict:
    """Read selected values from a UAE config file.

    Returns dict with keys: kickstart_rom_file, kickstart_ext_rom_file,
    chipmem_size (int), fastmem_size (int), hardfiles (list[str]).
    """
    result: dict = {
        "kickstart_rom_file": "",
        "kickstart_ext_rom_file": "",
        "chipmem_size": 4,
        "fastmem_size": 8,
        "hardfiles": [],
    }

    if not os.path.isfile(path):
        return result

    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith(";") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()

            if key in _UAE_KEYS:
                if key in ("chipmem_size", "fastmem_size"):
                    try:
                        result[key] = int(value)
                    except ValueError:
                        pass
                else:
                    result[key] = value
            elif key == "hardfile2":
                result["hardfiles"].append(value)

    return result


def parse_hardfile_paths(hardfiles: list[str]) -> list[str]:
    """Extract absolute HDF paths from hardfile2 values.

    Format: ``rw,DH0:/path/to/file.hdf,32,1,2,512,...``
    """
    paths: list[str] = []
    for entry in hardfiles:
        parts = entry.split(",", 2)
        if len(parts) >= 2:
            # parts[1] is "DHn:/path/to/file.hdf"
            _, _, path = parts[1].partition(":")
            if path:
                paths.append(path)
    return paths


def _build_hardfile_line(path: str, index: int) -> str:
    """Build a hardfile2= value for a given HDF path and device index."""
    devname = f"DH{index}"
    bootpri = 0 if index == 0 else -(index)
    return f"rw,{devname}:{path},32,1,2,512,BOOTPRI={bootpri},,uae"


def _write_uae(
    target: str,
    rom: RomEntry,
    hdfs: list[str],
    chipmem: int,
    fastmem: int,
    config_description: str | None = None,
) -> None:
    """Read BASE_UAE, apply overrides, write to *target*."""
    lines: list[str] = []
    if os.path.isfile(BASE_UAE):
        with open(BASE_UAE) as f:
            lines = f.readlines()

    # Keys we'll override — remove existing lines for them
    override_keys = {
        "kickstart_rom_file",
        "kickstart_ext_rom_file",
        "chipmem_size",
        "fastmem_size",
        "hardfile2",
    }
    if config_description is not None:
        override_keys.add("config_description")

    filtered: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(";") or "=" not in stripped:
            filtered.append(line)
            continue
        key = stripped.partition("=")[0].strip()
        if key not in override_keys:
            filtered.append(line)

    # Build override lines
    overrides: list[str] = [
        "\n; --- Early Startup Control overrides ---\n",
        f"kickstart_rom_file={rom.path}\n",
    ]
    if rom.ext_path:
        overrides.append(f"kickstart_ext_rom_file={rom.ext_path}\n")
    overrides.append(f"chipmem_size={chipmem}\n")
    overrides.append(f"fastmem_size={fastmem}\n")

    for i, hdf_path in enumerate(hdfs):
        overrides.append(f"hardfile2={_build_hardfile_line(hdf_path, i)}\n")

    if config_description is not None:
        overrides.append(f"config_description={config_description}\n")

    # Ensure parent directory exists
    os.makedirs(os.path.dirname(target), exist_ok=True)

    with open(target, "w") as f:
        f.writelines(filtered)
        f.writelines(overrides)


def write_session_uae(
    rom: RomEntry,
    hdfs: list[str],
    chipmem: int,
    fastmem: int,
) -> None:
    """Write ephemeral session config to SESSION_UAE and set session ref."""
    _write_uae(SESSION_UAE, rom, hdfs, chipmem, fastmem)
    write_session_ref(SESSION_UAE)


def write_saved_uae(
    rom: RomEntry,
    hdfs: list[str],
    chipmem: int,
    fastmem: int,
) -> str | None:
    """Write persistent custom config + session. Returns error or None."""
    # Session first — /tmp always has space
    _write_uae(SESSION_UAE, rom, hdfs, chipmem, fastmem)
    write_session_ref(SESSION_UAE)
    try:
        _write_uae(SAVED_UAE, rom, hdfs, chipmem, fastmem,
                    config_description="AmiCachy Default")
        return write_boot_ref(SAVED_UAE)
    except OSError as exc:
        return str(exc)
