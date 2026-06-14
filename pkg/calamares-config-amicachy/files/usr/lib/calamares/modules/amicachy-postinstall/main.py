#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# === This file is part of AmiCachy — Calamares migration (F3) ===
#
#   SPDX-License-Identifier: GPL-3.0-or-later
#
# amicachy-postinstall: AmiCachy-specific post-install job.
#
# F3 sub-jobs:
#   - profiles:  write systemd-boot loader.conf + per-profile entries with the
#                amiprofile= kernel cmdline (the contract amilaunch.sh dispatches
#                on, inventory §6). Runs AFTER the standard `bootloader` module
#                so it overwrites that module's generic entries (§9 risk #1).
#   - home:      copy /etc/skel into /home/amiga. Calamares' users module skips
#                skel when the home already exists — and it does here because the
#                AMIGADATA partition is mounted at /home/amiga/Amiga, creating
#                /home/amiga before user creation. Without this, ~/.bash_profile
#                is missing and amilaunch never starts on tty1.
#   - locale:    run locale-gen for the locales Calamares uncommented. Without
#                pacstrap there is no pacman hook to do it, so the chosen locale
#                (e.g. es_ES.UTF-8) would be absent and shells warn on every login.
#
# The remaining sub-jobs (roms, addons, mac_fallback) and reading a real profile
# selection from the QML pages land in F6.

import os
import shutil

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


def _populate_amiga_home(root):
    """Copy /etc/skel into /home/amiga (Calamares' useradd skips skel because
    the AMIGADATA mount pre-creates the home), then fix ownership. This is what
    makes ~/.bash_profile exist so amilaunch starts on tty1."""
    skel = os.path.join(root, "etc/skel")
    home = os.path.join(root, "home/amiga")
    if not os.path.isdir(skel) or not os.path.isdir(home):
        libcalamares.utils.warning(
            "amicachy-postinstall: skel or amiga home missing; skipping home setup"
        )
        return
    for name in os.listdir(skel):
        src = os.path.join(skel, name)
        dst = os.path.join(home, name)
        if os.path.exists(dst):
            continue  # never clobber e.g. the AMIGADATA mount dir
        if os.path.isdir(src):
            shutil.copytree(src, dst, symlinks=True)
        else:
            shutil.copy2(src, dst)
    libcalamares.utils.target_env_call(["chown", "-R", "amiga:amiga", "/home/amiga"])
    libcalamares.utils.debug("amicachy-postinstall: populated /home/amiga from /etc/skel")


def _generate_locales():
    """Run locale-gen for whatever Calamares uncommented in /etc/locale.gen.
    Without pacstrap nothing else does it, so the chosen locale would be absent."""
    rc = libcalamares.utils.target_env_call(["locale-gen"])
    libcalamares.utils.debug("amicachy-postinstall: locale-gen returned {}".format(rc))


def run():
    """AmiCachy post-install configuration."""
    root = libcalamares.globalstorage.value("rootMountPoint")
    if not root:
        return (
            _("AmiCachy post-install failed"),
            _("rootMountPoint is not set in global storage."),
        )

    cfg = libcalamares.job.configuration
    error = _write_boot_entries(root, cfg)
    if error:
        return error

    _populate_amiga_home(root)
    _generate_locales()
    return None
