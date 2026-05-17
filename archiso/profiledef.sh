#!/usr/bin/env bash
# AmiCachy ISO profile definition

iso_name="amicachy"
iso_label="AMICACHY_$(date +%Y%m)"
iso_publisher="AmiCachy Project"
iso_application="AmiCachy Live/Install Media"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('uefi.systemd-boot')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
# Compression selectable from build_iso.sh via AMICACHY_SQUASHFS_COMP.
# Default 'xz' matches the canonical archiso profile (smallest ISO, slow build);
# 'zstd' is opt-in for big bundled ISOs where compression time dominates.
case "${AMICACHY_SQUASHFS_COMP:-xz}" in
    zstd) airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '19' '-b' '1M') ;;
    xz|*) airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M') ;;
esac

file_permissions=(
  ["/etc/sudoers.d/amiga"]="0:0:440"
  ["/usr/bin/amilaunch.sh"]="0:0:755"
  ["/usr/bin/amicachy-amiberry-session"]="0:0:755"
  ["/usr/bin/amicachy-copy-roms"]="0:0:755"
  ["/usr/bin/amicachy-earlystartup"]="0:0:755"
  ["/usr/bin/amicachy-fetch-asset"]="0:0:755"
  ["/usr/bin/amicachy-fix-mac-boot"]="0:0:755"
  ["/usr/bin/amicachy-grow-data"]="0:0:755"
  ["/usr/bin/amicachy-installer"]="0:0:755"
  ["/usr/bin/amicachy-link-host-assets"]="0:0:755"
  ["/usr/bin/amicachy-persistent-data"]="0:0:755"
  ["/usr/bin/amicachy-seed-assets"]="0:0:755"
  ["/usr/bin/amicachy-set-amiga-password"]="0:0:755"
  ["/usr/bin/amicachy-wifi-debug"]="0:0:755"
  ["/usr/bin/start_dev_env.sh"]="0:0:755"
  ["/home/amiga"]="1000:1000:750"
  ["/home/amiga/.bash_profile"]="1000:1000:644"
  ["/home/amiga/.config"]="1000:1000:755"
  ["/home/amiga/.config/labwc"]="1000:1000:755"
  ["/home/amiga/.config/labwc/rc.xml"]="1000:1000:644"
  ["/home/amiga/.config/labwc/environment"]="1000:1000:644"
  ["/home/amiga/.config/labwc/autostart"]="1000:1000:755"
)
