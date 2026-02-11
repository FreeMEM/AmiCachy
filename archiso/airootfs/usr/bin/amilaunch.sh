#!/usr/bin/env bash
# AmiCachy — Profile dispatcher
# Reads amiprofile= from kernel cmdline and launches the appropriate session.

set -euo pipefail

UAE_DIR="/usr/share/amicachy/uae"
AMIBERRY_BIN="/usr/bin/amiberry"

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

# --- Fallback: launch a terminal with system info if amiberry is missing ---
launch_fallback() {
    local reason="$1"
    echo "FALLBACK: ${reason}" >&2
    exec cage -- foot -e bash -c "
        echo '═══════════════════════════════════════════'
        echo '  AmiCachy — Fallback Shell'
        echo '═══════════════════════════════════════════'
        echo ''
        echo '  Profile:  ${PROFILE}'
        echo '  Reason:   ${reason}'
        echo ''
        echo '  amiberry is not installed yet.'
        echo '  The system booted correctly — this shell'
        echo '  lets you verify the environment.'
        echo ''
        echo '  Useful commands:'
        echo '    uname -a          # kernel info'
        echo '    cat /proc/cmdline # boot parameters'
        echo '    systemctl status  # service overview'
        echo '    ip addr           # network'
        echo ''
        echo '═══════════════════════════════════════════'
        exec bash
    "
}

# --- Dispatch based on profile ---
case "$PROFILE" in
    installer)
        exec cage -- /usr/bin/amicachy-installer
        ;;
    classic_68k)
        if [[ -x "$AMIBERRY_BIN" ]]; then
            exec cage -- "$AMIBERRY_BIN" --config "${UAE_DIR}/a1200.uae"
        else
            launch_fallback "amiberry not found (classic_68k)"
        fi
        ;;
    ppc_nitro)
        if [[ -x "$AMIBERRY_BIN" ]]; then
            exec cage -- chrt -f 52 "$AMIBERRY_BIN" --config "${UAE_DIR}/os41.uae"
        else
            launch_fallback "amiberry not found (ppc_nitro)"
        fi
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
