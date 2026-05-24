"""CLI frontend — list / show / install / remove."""

from __future__ import annotations

import argparse
import sys
import textwrap
import time

from . import catalog as cat_mod
from . import installer, presets, state


def _fmt_size(n: int) -> str:
    f = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if f < 1024 or unit == "TB":
            return f"{f:.1f} {unit}"
        f /= 1024
    return f"{f:.1f} TB"


def _wrap(text: str, indent: str = "  ", width: int = 76) -> str:
    return "\n".join(
        textwrap.fill(p, width=width, initial_indent=indent, subsequent_indent=indent)
        for p in text.splitlines() if p.strip()
    )


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------


def cmd_list(_args) -> int:
    catalog = cat_mod.load_catalog()
    if not catalog:
        print("No assets in catalog.")
        return 0
    print(f"{'ID':<24}  {'STATUS':<10}  {'SIZE':>10}  NAME")
    print("-" * 78)
    for a in catalog:
        status = "installed" if state.is_installed(a.id) else "available"
        print(f"{a.id:<24}  {status:<10}  {_fmt_size(a.size_bytes):>10}  {a.name}")
    return 0


def cmd_show(args) -> int:
    catalog = cat_mod.load_catalog()
    a = cat_mod.get_asset(catalog, args.id)
    if a is None:
        print(f"unknown asset: {args.id}", file=sys.stderr)
        return 1
    rec = state.installed_record(a.id)
    print(f"ID:          {a.id}")
    print(f"Name:        {a.name}")
    if a.version:
        print(f"Version:     {a.version}")
    print(f"Category:    {a.category}")
    print(f"Size:        {_fmt_size(a.size_bytes)}")
    print(f"Source:      {a.url}")
    print(f"Homepage:    {a.homepage}")
    print(f"License:     {a.license_url}")
    print(f"Installed:   {'yes — ' + rec['path'] if rec else 'no'}")
    print()
    print("Description:")
    print(_wrap(a.summary))
    print()
    print("License notice:")
    print(_wrap(a.license_summary))
    return 0


class _CLIProgress:
    """Render multi-stage progress on a single tty line."""

    def __init__(self) -> None:
        self.stage = ""
        self.last_print = 0.0

    def __call__(self, stage: str, current: int, total: int) -> None:
        if stage != self.stage:
            if self.stage:
                sys.stdout.write("\n")
            self.stage = stage
            sys.stdout.write(f"  [{stage}]\n")

        # Throttle to ~10 fps to avoid serial-console flooding.
        now = time.monotonic()
        if total > 0 and current < total and (now - self.last_print) < 0.1:
            return
        self.last_print = now

        if total <= 0:
            sys.stdout.write(f"\r    working… ({_fmt_size(current)})")
        else:
            pct = int(100 * current / total)
            bar_w = 32
            filled = pct * bar_w // 100
            bar = "#" * filled + "-" * (bar_w - filled)
            sys.stdout.write(
                f"\r    [{bar}] {pct:3d}%  "
                f"{_fmt_size(current)}/{_fmt_size(total)}"
            )
        sys.stdout.flush()


def cmd_install(args) -> int:
    catalog = cat_mod.load_catalog()
    a = cat_mod.get_asset(catalog, args.id)
    if a is None:
        print(f"unknown asset: {args.id}", file=sys.stderr)
        return 1

    if state.is_installed(a.id) and not args.force:
        print(f"{a.id} is already installed. Use --force to reinstall.")
        return 0

    if not state.is_accepted(a.id):
        if args.accept:
            state.mark_accepted(a.id)
        else:
            print()
            print(f"== {a.name} — license ==")
            print()
            print(_wrap(a.license_summary))
            print()
            print(f"  Full terms: {a.license_url}")
            print(f"  Source:     {a.url}")
            print(f"  Size:       {_fmt_size(a.size_bytes)}")
            print()
            try:
                answer = input("Accept and proceed? [y/N] ").strip().lower()
            except EOFError:
                answer = ""
            if answer not in ("y", "yes"):
                print("Aborted.")
                return 1
            state.mark_accepted(a.id)

    progress = _CLIProgress()
    print()
    print(f"Installing {a.name}…")
    try:
        path = installer.install_asset(a, progress_cb=progress, keep_archive=args.keep_archive)
    except installer.InstallError as e:
        print(f"\n\nERROR: {e}", file=sys.stderr)
        return 1
    from pathlib import Path

    print()
    print()
    print(f"Installed to {path}")
    uae = Path.home() / "Amiberry" / "conf" / f"amicachy-{a.id}.uae"
    if uae.is_file():
        print(f"Registered UAE config: {uae}")
        print("Available in Early Startup Control as a Configuration Profile.")
    return 0


def cmd_add_url(args) -> int:
    """Manual install from a URL pasted at the command line.

    Always requires the user to acknowledge responsibility for the
    asset's licensing — either interactively or via --accept-responsibility.
    """
    if not args.accept_responsibility:
        print()
        print("== Manual asset install ==")
        print()
        print(_wrap(
            "AmiCachy does not host, validate or vouch for arbitrary URLs. "
            "You confirm that you have the right to download and use this "
            "content under whatever terms apply to it."
        ))
        print()
        try:
            answer = input(
                "Do you accept full responsibility for this asset? [y/N] "
            ).strip().lower()
        except EOFError:
            answer = ""
        if answer not in ("y", "yes"):
            print("Aborted.")
            return 1

    progress = _CLIProgress()
    print()
    print(f"Installing from {args.url}…")
    try:
        asset = installer.install_from_url(
            url=args.url,
            name=args.name or "",
            base_profile_id=args.profile,
            expected_sha256=args.sha256 or "",
            progress_cb=progress,
        )
    except installer.InstallError as e:
        print(f"\n\nERROR: {e}", file=sys.stderr)
        return 1

    print()
    print()
    print(f"Installed as '{asset.id}' ({asset.name}).")
    rec = state.installed_record(asset.id)
    if rec:
        print(f"Location:  {rec['path']}")
    uae = (
        __import__("pathlib").Path.home() / "Amiberry" / "conf"
        / f"amicachy-{asset.id}.uae"
    )
    if uae.is_file():
        print(f"UAE conf:  {uae}")
    print(f"sha256:    {asset.sha256}")
    return 0


def cmd_add_file(args) -> int:
    """Manual install from a local file path (.zip, .hdf raw, or Kickstart .rom/.key/.bin)."""
    if not args.accept_responsibility:
        print()
        print("== Manual asset install ==")
        print()
        print(_wrap(
            "AmiCachy does not validate or vouch for arbitrary files. "
            "You confirm that you have the right to use this content under "
            "whatever terms apply to it."
        ))
        print()
        try:
            answer = input(
                "Do you accept full responsibility for this asset? [y/N] "
            ).strip().lower()
        except EOFError:
            answer = ""
        if answer not in ("y", "yes"):
            print("Aborted.")
            return 1

    progress = _CLIProgress()
    print()
    print(f"Installing from {args.path}…")
    try:
        asset = installer.install_from_file(
            path=args.path,
            name=args.name or "",
            base_profile_id=args.profile,
            progress_cb=progress,
        )
    except installer.InstallError as e:
        print(f"\n\nERROR: {e}", file=sys.stderr)
        return 1

    print()
    print()
    print(f"Installed as '{asset.id}' ({asset.name}).")
    rec = state.installed_record(asset.id)
    if rec:
        print(f"Location:  {rec['path']}")
    from pathlib import Path as _P
    uae = _P.home() / "Amiberry" / "conf" / f"amicachy-{asset.id}.uae"
    if uae.is_file():
        print(f"UAE conf:  {uae}")
    print(f"sha256:    {asset.sha256}")
    return 0


def cmd_remove(args) -> int:
    catalog = cat_mod.load_catalog()
    a = cat_mod.get_asset(catalog, args.id)
    if a is None:
        print(f"unknown asset: {args.id}", file=sys.stderr)
        return 1
    if not state.is_installed(a.id):
        print(f"{a.id} is not installed.")
        return 0
    if not args.yes:
        try:
            answer = input(f"Remove {a.name} and its files? [y/N] ").strip().lower()
        except EOFError:
            answer = ""
        if answer not in ("y", "yes"):
            print("Aborted.")
            return 1
    installer.uninstall_asset(a.id)
    print(f"Removed {a.id}.")
    return 0


def cmd_gui(_args) -> int:
    try:
        from . import gui
    except ImportError as e:
        print(f"GUI unavailable: {e}", file=sys.stderr)
        return 1
    return gui.main()


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="amicachy-fetch-asset",
        description="Download and install optional AmiCachy bundles.",
    )
    p.add_argument(
        "--gui",
        action="store_true",
        help="Launch the Qt frontend (overrides any subcommand).",
    )
    sub = p.add_subparsers(dest="cmd", metavar="COMMAND")

    sub.add_parser("list", help="List available assets.")

    p_show = sub.add_parser("show", help="Print details for one asset.")
    p_show.add_argument("id")

    p_inst = sub.add_parser("install", help="Download and install an asset.")
    p_inst.add_argument("id")
    p_inst.add_argument(
        "--accept",
        action="store_true",
        help="Skip the interactive license prompt (you accept implicitly).",
    )
    p_inst.add_argument(
        "--force",
        action="store_true",
        help="Reinstall even if already installed.",
    )
    p_inst.add_argument(
        "--keep-archive",
        action="store_true",
        help="Do not delete the downloaded archive after extraction.",
    )

    p_rem = sub.add_parser("remove", help="Uninstall a previously installed asset.")
    p_rem.add_argument("id")
    p_rem.add_argument("-y", "--yes", action="store_true", help="No confirmation.")

    p_file = sub.add_parser(
        "add-file",
        help="Install a custom .zip, .hdf, or Kickstart ROM (.rom/.key/.bin) from a local file path.",
    )
    p_file.add_argument("path", help="Local path (e.g. /run/media/amiga/USB/kick31.rom).")
    p_file.add_argument(
        "--name",
        default="",
        help="Display name (defaults to the filename without extension).",
    )
    p_file.add_argument(
        "--profile",
        default="a1200-aga",
        choices=[pid for pid, _label, _tpl in presets.BASE_PROFILES],
        help="Base UAE profile to seed the generated config.",
    )
    p_file.add_argument(
        "--accept-responsibility",
        action="store_true",
        help="Skip the interactive responsibility prompt.",
    )

    p_url = sub.add_parser(
        "add-url",
        help="Install a custom .zip from an arbitrary URL.",
    )
    p_url.add_argument("url", help="https:// URL of the .zip archive.")
    p_url.add_argument(
        "--name",
        default="",
        help="Display name (defaults to the URL filename).",
    )
    p_url.add_argument(
        "--profile",
        default="a1200-aga",
        choices=[pid for pid, _label, _tpl in presets.BASE_PROFILES],
        help="Base UAE profile to seed the generated config.",
    )
    p_url.add_argument(
        "--sha256",
        default="",
        help="Optional sha256 to verify the download against.",
    )
    p_url.add_argument(
        "--accept-responsibility",
        action="store_true",
        help="Skip the interactive responsibility prompt.",
    )

    sub.add_parser("gui", help="Launch the Qt frontend.")

    return p


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    if args.gui:
        return cmd_gui(args)

    handlers = {
        "list": cmd_list,
        "show": cmd_show,
        "install": cmd_install,
        "remove": cmd_remove,
        "add-url": cmd_add_url,
        "add-file": cmd_add_file,
        "gui": cmd_gui,
    }
    handler = handlers.get(args.cmd)
    if handler is None:
        parser.print_help()
        return 1
    return handler(args)
