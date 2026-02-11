#!/usr/bin/env bash
# AmiCachyEnv ISO profile definition

iso_name="amicachyenv"
iso_label="AMICACHY_$(date +%Y%m)"
iso_publisher="AmiCachyEnv Project"
iso_application="AmiCachyEnv Live/Install Media"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('uefi-x64.systemd-boot.esp')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')

file_permissions=(
  ["/usr/bin/amilaunch.sh"]="0:0:755"
  ["/usr/bin/start_dev_env.sh"]="0:0:755"
)
