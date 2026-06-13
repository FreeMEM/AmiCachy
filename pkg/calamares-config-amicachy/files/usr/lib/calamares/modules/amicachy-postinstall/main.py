#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# === This file is part of AmiCachy — Calamares migration (F3) ===
#
#   SPDX-License-Identifier: GPL-3.0-or-later
#
# amicachy-postinstall: AmiCachy-specific post-install job.
#
# F3 implements only the 'profiles' sub-job: it writes the systemd-boot
# loader.conf and the per-profile entries with the amiprofile= kernel
# cmdline, which is the contractual API amilaunch.sh dispatches on
# (inventory §6). The remaining sub-jobs (roms, addons, mac_fallback) and
# reading a real profile selection from the QML pages land in F6.
#
# Runs AFTER the standard `bootloader` module so it overwrites the generic
# loader.conf/entries that module writes (inventory §9 risk #1 — ordering).

import os

import libcalamares

import gettext

_ = gettext.translation(
    "calamares-python",
    localedir=libcalamares.utils.gettext_path(),
    languages=libcalamares.utils.gettext_languages(),
    fallback=True,
).gettext


def pretty_name():
    return _("Configure AmiCachy boot profiles")


def _write_file(path, content):
    """Write content to path, creating parent dirs (like backend._write_file)."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(content)


def _selected_profiles(cfg):
    """Profiles to install: the QML selector's result if present (F6),
    otherwise just the configured default (F3 behaviour)."""
    default_profile = cfg.get("default_profile", "classic_68k")
    selected = libcalamares.globalstorage.value("amicachy_profiles")
    if not selected:
        selected = [default_profile]

    always = cfg.get("always_install", [])
    profiles = cfg.get("profiles", {})

    ordered = []
    for pid in list(selected) + list(always):
        if pid in profiles and pid not in ordered:
            ordered.append(pid)
    return ordered, default_profile


def _write_boot_entries(root, cfg):
    profiles = cfg.get("profiles", {})
    cmdline_base = cfg.get("cmdline_base", "")
    timeout = cfg.get("loader_timeout", 5)

    to_install, default_profile = _selected_profiles(cfg)
    if not to_install:
        return _("No boot profiles to install"), _(
            "The amicachy-postinstall profile list resolved to empty."
        )

    if default_profile not in profiles:
        default_profile = to_install[0]
    default_entry = profiles[default_profile]["filename"]

    loader_dir = os.path.join(root, "boot/loader")
    entries_dir = os.path.join(loader_dir, "entries")

    # loader.conf — mirrors resources.py LOADER_CONF_TEMPLATE.
    _write_file(
        os.path.join(loader_dir, "loader.conf"),
        "default {entry}\n"
        "timeout {timeout}\n"
        "editor  no\n"
        "console-mode max\n".format(entry=default_entry, timeout=timeout),
    )

    # Per-profile entries. amiprofile=<id> is the contract; the per-profile
    # extra (mitigations=off nowatchdog) only goes on classic_68k/ppc_nitro.
    for pid in to_install:
        profile = profiles[pid]
        options = "{base} amiprofile={pid}".format(base=cmdline_base, pid=pid)
        extra = profile.get("extra_cmdline", "")
        if extra:
            options = "{options} {extra}".format(options=options, extra=extra)
        _write_file(
            os.path.join(entries_dir, profile["filename"]),
            "title   {title}\n"
            "linux   /vmlinuz-linux-cachyos\n"
            "initrd  /initramfs-linux-cachyos.img\n"
            "options {options}\n".format(title=profile["title"], options=options),
        )

    libcalamares.utils.debug(
        "amicachy-postinstall: wrote {n} boot entries (default={d})".format(
            n=len(to_install), d=default_profile
        )
    )
    return None


def run():
    """AmiCachy post-install configuration."""
    root = libcalamares.globalstorage.value("rootMountPoint")
    if not root:
        return (
            _("AmiCachy post-install failed"),
            _("rootMountPoint is not set in global storage."),
        )

    cfg = libcalamares.job.configuration
    return _write_boot_entries(root, cfg)
