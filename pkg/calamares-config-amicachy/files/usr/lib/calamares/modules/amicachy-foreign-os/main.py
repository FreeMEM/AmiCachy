#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# === This file is part of AmiCachy — Calamares migration (F4) ===
#
#   SPDX-License-Identifier: GPL-3.0-or-later
#
# amicachy-foreign-os: add systemd-boot chainload entries for any OS already
# installed on the disk (dual-boot, F4). Runs AFTER `bootloader` and
# `amicachy-postinstall`, with the (possibly reused) ESP still mounted, so it
# only *adds* Type-1 entries — it never rewrites loader.conf, so the default
# stays classic_68k (set by amicachy-postinstall, inventory §9 risk #1).
#
# Why a custom module: systemd-boot auto-detects Windows' bootmgfw.efi, but it
# does NOT auto-detect a foreign GRUB (Debian/Ubuntu/Fedora/…). For T3 (other
# Linux) we must write an explicit `efi /EFI/<vendor>/grubx64.efi` entry; we do
# the same for Windows for a clean title and stable ordering below the AmiCachy
# profiles (entry prefixes 90+, profiles use 01-04).
#
# In T1 (empty disk) the ESP holds only EFI/systemd + EFI/BOOT, so this finds
# nothing and writes nothing — safe and idempotent.

import os

import libcalamares

import gettext

_ = gettext.translation(
    "calamares-python",
    localedir=libcalamares.utils.gettext_path(),
    languages=libcalamares.utils.gettext_languages(),
    fallback=True,
).gettext

# Defaults, overridable from etc/calamares/modules/amicachy-foreign-os.conf.
DEFAULT_EXCLUDE = ["systemd", "boot", "microsoft", "amicachy", "linux", "tools"]
DEFAULT_LOADERS = [
    "shimx64.efi", "grubx64.efi",
    "shimaa64.efi", "grubaa64.efi",
    "bootx64.efi",
]
WINDOWS_EFI = "/EFI/Microsoft/Boot/bootmgfw.efi"


def pretty_name():
    return _("Add boot entries for existing operating systems")


def _esp_mount(root):
    """Path to the mounted ESP inside the target. Our partition config mounts
    it at /boot (efiSystemPartition), reused as-is in dual-boot. Detect by the
    presence of an EFI/ directory; fall back to <root>/boot."""
    for mp in ("boot", "boot/efi", "efi"):
        path = os.path.join(root, mp)
        if os.path.isdir(os.path.join(path, "EFI")):
            return path
    return os.path.join(root, "boot")


def _pick_loader(vendordir, preference):
    """Most-preferred EFI binary present in vendordir, matched case-insensitively
    (the ESP is FAT). Returns the on-disk filename or None."""
    present = {}
    for name in os.listdir(vendordir):
        if os.path.isfile(os.path.join(vendordir, name)):
            present[name.lower()] = name
    for pref in preference:
        real = present.get(pref.lower())
        if real:
            return real
    return None


def _find_loaders(esp, cfg):
    """List of (key, title, efi_path) for every foreign OS found on the ESP."""
    efi = os.path.join(esp, "EFI")
    if not os.path.isdir(efi):
        return []

    exclude = set(x.lower() for x in cfg.get("exclude_dirs", DEFAULT_EXCLUDE))
    loaders = cfg.get("loader_preference", DEFAULT_LOADERS)
    titles = cfg.get("vendor_titles", {}) or {}
    win_title = cfg.get("windows_title", "Windows Boot Manager")

    found = []

    # Windows — special-cased, fixed path. FAT is case-insensitive so this
    # isfile() matches regardless of the on-disk casing.
    if os.path.isfile(os.path.join(esp, WINDOWS_EFI.lstrip("/"))):
        found.append(("windows", win_title, WINDOWS_EFI))

    # Other vendors — mostly a foreign GRUB, which sd-boot does NOT autodetect.
    for name in sorted(os.listdir(efi)):
        if name.lower() in exclude:
            continue
        vendordir = os.path.join(efi, name)
        if not os.path.isdir(vendordir):
            continue
        loader = _pick_loader(vendordir, loaders)
        if not loader:
            continue
        title = titles.get(name.lower(), name.capitalize())
        found.append((name.lower(), title, "/EFI/{}/{}".format(name, loader)))

    return found


def _write_entries(esp, found, cfg):
    """Write a Type-1 systemd-boot entry per foreign OS. Numbered from
    entry_start (90) so they sort below the AmiCachy profiles."""
    entries_dir = os.path.join(esp, "loader", "entries")
    os.makedirs(entries_dir, exist_ok=True)

    num = int(cfg.get("entry_start", 90))
    written = []
    for key, title, efi_path in found:
        fname = "{:02d}-{}.conf".format(num, key)
        with open(os.path.join(entries_dir, fname), "w") as handle:
            handle.write("title   {title}\nefi     {efi}\n".format(title=title, efi=efi_path))
        written.append(fname)
        num += 1
    return written


def run():
    """Detect foreign operating systems on the ESP and add chainload entries."""
    root = libcalamares.globalstorage.value("rootMountPoint")
    if not root:
        return (
            _("AmiCachy dual-boot setup failed"),
            _("rootMountPoint is not set in global storage."),
        )

    cfg = libcalamares.job.configuration
    esp = _esp_mount(root)
    if not os.path.isdir(os.path.join(esp, "EFI")):
        libcalamares.utils.warning(
            "amicachy-foreign-os: no ESP/EFI directory at {}; skipping".format(esp)
        )
        return None

    found = _find_loaders(esp, cfg)
    if not found:
        libcalamares.utils.debug(
            "amicachy-foreign-os: no foreign OS found on the ESP (single-boot)"
        )
        return None

    written = _write_entries(esp, found, cfg)
    libcalamares.utils.debug(
        "amicachy-foreign-os: wrote {n} chainload entries: {names}".format(
            n=len(written), names=", ".join(written)
        )
    )
    return None
