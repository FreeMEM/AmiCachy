#!/usr/bin/env bash
# AmiCachyEnv — Dev Station startup
# Launched by labwc as the session startup script.

UAE_DIR="/usr/share/amicachy/uae"

# Wait for compositor to be ready
sleep 1

# Launch waybar (status bar)
waybar &

# Launch VS Code on workspace 1 (Wayland native)
code --ozone-platform=wayland --new-window &

# Launch Amiberry in windowed mode on workspace 2
amiberry --config "${UAE_DIR}/a1200.uae" &

# Keep the session alive — don't exit on individual process failures
wait || true
