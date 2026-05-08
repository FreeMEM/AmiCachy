# AmiCachy — Auto-launch on TTY1
# On TTY1, launch the profile dispatcher immediately.
# Other TTYs get a normal shell for maintenance/debugging.

if [[ "$(tty)" == "/dev/tty1" ]]; then
    # Silence the TTY: any keypress (F5 in particular, used to trigger
    # Early Startup Control) would otherwise echo as raw escape codes
    # like ^[[[E on screen during the brief window between Plymouth
    # quit and cage taking over the framebuffer.
    stty -echo 2>/dev/null
    printf '\033[?25l\033[2J\033[H\033[3J' 2>/dev/null  # hide cursor + clear
    exec /usr/bin/amilaunch.sh
fi
