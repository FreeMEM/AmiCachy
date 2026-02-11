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
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')

file_permissions=(
  ["/etc/sudoers.d/amiga"]="0:0:440"
  ["/usr/bin/amilaunch.sh"]="0:0:755"
  ["/usr/bin/amicachy-installer"]="0:0:755"
  ["/usr/bin/start_dev_env.sh"]="0:0:755"
  ["/home/amiga"]="1000:1000:750"
  ["/home/amiga/.bash_profile"]="1000:1000:644"
  ["/home/amiga/.config"]="1000:1000:755"
  ["/home/amiga/.config/labwc"]="1000:1000:755"
  ["/home/amiga/.config/labwc/rc.xml"]="1000:1000:644"
  ["/home/amiga/.config/labwc/environment"]="1000:1000:644"
  ["/home/amiga/.config/labwc/autostart"]="1000:1000:755"
)
