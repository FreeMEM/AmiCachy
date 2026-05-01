"""Base UAE profile presets for manually-added assets.

Each preset is a dict that feeds installer.render_uae_template(). The user
picks one when adding an asset by URL or from a local file, since for
those we don't have a curated uae_template like the system catalog does.
"""

from __future__ import annotations

# Order shown in the combo. Keep "skip" last so the user only reaches it
# after seeing the canonical machines.
BASE_PROFILES: list[tuple[str, str, dict | None]] = [
    (
        "a500",
        "Amiga 500 (1 MB chip, OCS, 68000)",
        {
            "config_description": "AmiCachy — Manual asset (A500)",
            "chipset": "ocs",
            "chipset_compatible": "Generic",
            "chipmem_size": 1,        # 512 KB chip RAM
            "bogomem_size": 4,        # 512 KB slow RAM (trapdoor expansion)
            "fastmem_size": 0,
            "cpu_type": "68000",
            "cpu_speed": "real",
            "cpu_compatible": True,
            "kickstart_rom_file": "/usr/share/amiberry/roms/aros-rom.bin",
            "kickstart_ext_rom_file": "/usr/share/amiberry/roms/aros-ext.bin",
        },
    ),
    (
        "a1200-ocs",
        "Amiga 1200 OCS (2 MB chip, 8 MB fast, 68020)",
        {
            "config_description": "AmiCachy — Manual asset (A1200 OCS)",
            "chipset": "ocs",
            "chipmem_size": 4,        # 2 MB chip
            "fastmem_size": 8,        # 8 MB Z2 fast
            "bogomem_size": 0,
            "cpu_type": "68020",
            "cpu_speed": "real",
            "cpu_compatible": True,
            "kickstart_rom_file": "/usr/share/amiberry/roms/aros-rom.bin",
            "kickstart_ext_rom_file": "/usr/share/amiberry/roms/aros-ext.bin",
        },
    ),
    (
        "a1200-aga",
        "Amiga 1200 AGA (2 MB chip, 8 MB fast, 68030)",
        {
            "config_description": "AmiCachy — Manual asset (A1200 AGA)",
            "chipset": "aga",
            "chipset_compatible": "Generic",
            "chipmem_size": 4,
            "fastmem_size": 8,
            "bogomem_size": 0,
            "cpu_type": "68030",
            "cpu_speed": "real",
            "cpu_compatible": True,
            "kickstart_rom_file": "/usr/share/amiberry/roms/aros-rom.bin",
            "kickstart_ext_rom_file": "/usr/share/amiberry/roms/aros-ext.bin",
        },
    ),
    (
        "a1200-060",
        "Amiga 1200 / 060 + RTG (8 MB chip, Z3 256 MB)",
        {
            "config_description": "AmiCachy — Manual asset (A1200/060 + RTG)",
            "chipset": "aga",
            "chipmem_size": 8,
            "fastmem_size": 0,
            "z3mem_size": 256,
            "z3mem_start": "0x10000000",
            "bogomem_size": 0,
            "gfxcard_type": "ZorroIII",
            "gfxcard_size": 64,
            "cpu_type": "68040",
            "cpu_model": "68060",
            "fpu_model": "68060",
            "cpu_compatible": False,
            "cpu_24bit_addressing": False,
            "cpu_speed": "max",
            "cachesize": 16384,
            "kickstart_rom_file": "/usr/share/amiberry/roms/aros-rom.bin",
            "kickstart_ext_rom_file": "/usr/share/amiberry/roms/aros-ext.bin",
        },
    ),
    (
        "skip",
        "Skip — I'll configure it later",
        None,
    ),
]


def get_preset(preset_id: str) -> dict | None:
    """Return the uae_template dict for `preset_id`, or None for 'skip'/unknown."""
    for pid, _label, template in BASE_PROFILES:
        if pid == preset_id:
            return template
    return None
