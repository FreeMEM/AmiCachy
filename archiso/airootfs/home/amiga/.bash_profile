# AmiCachy — Auto-launch on TTY1
# On TTY1, launch the profile dispatcher immediately.
# Other TTYs get a normal shell for maintenance/debugging.

if [[ "$(tty)" == "/dev/tty1" ]]; then
    exec /usr/bin/amilaunch.sh
fi
