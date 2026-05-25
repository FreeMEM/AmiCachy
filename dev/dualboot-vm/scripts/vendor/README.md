# Vendored third-party tools

## Mido.sh

`Mido.sh` downloads official Windows ISOs from Microsoft's public frontend.

- **Upstream:** https://github.com/ElliotKillick/Mido (MIT, see `Mido.LICENSE`)
- **Pinned commit:** see `Mido.upstream-commit`
- **Local patch applied:** PR #26 ("fix Windows 11/10 ISO download 404 error")
  — switches the consumer download path to Microsoft's newer
  `software-download-connector` JSON API. Without it, `win11x64` and
  `win10x64` return HTTP 404. Not yet merged upstream as of the pin.

### Caveat

Microsoft frequently blocks automated ISO downloads by source IP
("Sentinel marked this request as rejected"), so Mido may fail even
patched. `build-baseline-windows.sh` falls back to any `*win*11*.iso`
manually placed in `dev/dualboot-vm/.cache/` (symlinks are followed),
which is the reliable path.

To refresh from upstream: re-fetch `Mido.sh` at a newer commit, re-apply
PR #26 (or use it if merged), update `Mido.upstream-commit`.
