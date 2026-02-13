#!/usr/bin/env bash
# AmiCachy — Profile dispatcher
# Reads amiprofile= from kernel cmdline and launches the appropriate session.

set -uo pipefail

# Clear the VT immediately to avoid flashing the login prompt
# between Plymouth quit and Cage startup.
clear

UAE_DIR="/usr/share/amicachy/uae"
AMIBERRY_BIN="/usr/bin/amiberry"
AMIBERRY_HOME="/usr/share/amiberry"

# --- CPU architecture check ---
# If the system has x86-64-v3 packages but the CPU lacks AVX2, binaries
# will crash with SIGILL. Detect this early and show a helpful message.
check_cpu_compat() {
    # Check if [cachyos-v3] repo is in pacman.conf (meaning v3 packages installed)
    if grep -q '^\[cachyos-v3\]' /etc/pacman.conf 2>/dev/null; then
        # System has v3 packages — verify CPU supports AVX2
        if ! grep -qw avx2 /proc/cpuinfo 2>/dev/null; then
            # v3 packages on non-v3 CPU — this will crash
            local cpu_model
            cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "unknown")

            # Use printf to write directly to the framebuffer console (tty)
            # since Wayland compositors won't start with v3 SIGILL
            clear
            echo ""
            echo "============================================================"
            echo "  AmiCachy — CPU Incompatible"
            echo "============================================================"
            echo ""
            echo "  This system was built with x86-64-v3 packages (AVX2)"
            echo "  but your CPU does not support AVX2 instructions."
            echo ""
            echo "  CPU: ${cpu_model}"
            echo ""
            echo "  The system cannot run v3-optimized binaries on this"
            echo "  hardware. They will crash with 'Illegal instruction'."
            echo ""
            echo "  Solutions:"
            echo "    1. Use a CPU with AVX2 support:"
            echo "       - Intel Haswell or newer (2013+)"
            echo "       - AMD Excavator or newer (2015+)"
            echo ""
            echo "    2. Rebuild the ISO with generic packages:"
            echo "       ./tools/build_iso_docker.sh --generic"
            echo ""
            echo "    3. Rebuild the dev VM on this machine:"
            echo "       ./tools/dev_vm.sh destroy"
            echo "       ./tools/dev_vm.sh create"
            echo "       (auto-detects CPU and uses generic packages)"
            echo ""
            echo "============================================================"
            echo ""
            echo "  Press Enter for a rescue shell, or power off the machine."
            read -r
            exec bash
        fi
    fi
}
check_cpu_compat

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

# Read keyboard layout from vconsole.conf; fall back to "us"
_keymap=$(sed -n 's/^KEYMAP=//p' /etc/vconsole.conf 2>/dev/null || echo "us")
export XKB_DEFAULT_LAYOUT="${_keymap:-us}"
export XDG_SESSION_TYPE="wayland"
export SDL_VIDEODRIVER="wayland"
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM="wayland"
export LIBSEAT_BACKEND="logind"

# Workaround: virtio-gpu hardware cursors are upside-down in wlroots compositors
# (QEMU bug #2315). Force software cursors. Safe to set on real hardware too.
export WLR_NO_HARDWARE_CURSORS=1

# sdl2-compat debug (CachyOS ships sdl2-compat over real SDL2)
export SDL2COMPAT_DEBUG_LOGGING=1

# Use real SDL2 library if available (bypasses sdl2-compat).
# sdl2-compat has known cursor bugs on Wayland: inverted cursor,
# wrong position offset, and mouse acceleration issues.
if [[ -f /usr/local/lib/libSDL2-2.0.so.0 ]]; then
    export SDL_DYNAMIC_API="/usr/local/lib/libSDL2-2.0.so.0"
fi

# --- Early Startup Control (hold F5 during boot) ---
if [[ "$PROFILE" != "installer" && "$PROFILE" != "dev_station" ]]; then
    if python3 /usr/share/amicachy/tools/earlystartup/check_hotkey.py 2>/dev/null; then
        cage -- /usr/bin/amicachy-earlystartup 2>/dev/null
    fi
fi

# --- Fallback: launch a terminal with system info ---
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

# --- Run amiberry with crash protection (prevents autologin loop) ---
run_amiberry() {
    local config="$1"
    shift
    local args=("$@" "$AMIBERRY_BIN")

    # If the UAE config exists, load it and start emulation directly.
    # use_gui=no skips the setup GUI; F12 still opens it during emulation.
    # Without a config, open the GUI for manual setup.
    if [[ -f "$config" ]]; then
        args+=(--config "$config" -s use_gui=no)
    else
        echo "Config not found: $config — launching Amiberry GUI" >&2
    fi

    # Amiberry expects its install root as the working directory
    # (data/, controllers/, whdboot/, etc. relative to cwd)
    cd "$AMIBERRY_HOME" || true

    # Capture all output for debugging (readable via SSH or dev_vm.sh log)
    local logfile="/tmp/amiberry-launch.log"

    # Run inside cage; wrap amiberry in a shell to capture its stderr
    cage -- bash -c '"${@}" 2>&1 | tee '"$logfile"'; exit ${PIPESTATUS[0]}' _ "${args[@]}"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        launch_fallback "amiberry exited with code $rc (config: $config). Log: $logfile"
    fi
}

# --- Dispatch based on profile ---
case "$PROFILE" in
    installer)
        exec cage -- /usr/bin/amicachy-installer
        ;;
    classic_68k)
        if [[ -x "$AMIBERRY_BIN" ]]; then
            run_amiberry "${UAE_DIR}/a1200.uae"
        else
            launch_fallback "amiberry not found (classic_68k)"
        fi
        ;;
    ppc_nitro)
        if [[ -x "$AMIBERRY_BIN" ]]; then
            run_amiberry "${UAE_DIR}/os41.uae" chrt -f 52
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
