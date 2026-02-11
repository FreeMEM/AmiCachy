#!/usr/bin/env bash
# AmiCachyEnv — Profile dispatcher
# Reads amiprofile= from kernel cmdline and launches the appropriate session.

set -euo pipefail

UAE_DIR="/usr/share/amicachy/uae"

# --- Parse profile from kernel command line ---
PROFILE=""
read -ra _cmdline < /proc/cmdline
for param in "${_cmdline[@]}"; do
    case "$param" in
        amiprofile=*) PROFILE="${param#amiprofile=}" ;;
    esac
done

if [[ -z "$PROFILE" ]]; then
    echo "ERROR: No amiprofile= found in kernel cmdline." >&2
    echo "Falling back to classic_68k..." >&2
    PROFILE="classic_68k"
fi

# --- Wayland environment setup ---
XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
mkdir -p "$XDG_RUNTIME_DIR"

export XKB_DEFAULT_LAYOUT="us"
export XDG_SESSION_TYPE="wayland"
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM="wayland"

# --- Dispatch based on profile ---
case "$PROFILE" in
    installer)
        exec cage -- /usr/bin/amicachy-installer
        ;;
    classic_68k)
        exec cage -- amiberry --config "${UAE_DIR}/a1200.uae"
        ;;
    ppc_nitro)
        exec cage -- chrt -f 52 amiberry --config "${UAE_DIR}/os41.uae"
        ;;
    dev_station)
        exec labwc -s /usr/bin/start_dev_env.sh
        ;;
    *)
        echo "ERROR: Unknown profile '${PROFILE}'." >&2
        echo "Valid profiles: installer, classic_68k, ppc_nitro, dev_station" >&2
        exit 1
        ;;
esac
