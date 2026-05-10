#!/usr/bin/env bash
# AmiCachy — Profile dispatcher
# Reads amiprofile= from kernel cmdline and launches the appropriate session.

set -uo pipefail

# Clear the VT immediately and hide the cursor to avoid
# flashing the login prompt between Plymouth and Cage.
printf '\e[?25l' > /dev/tty1 2>/dev/null || true
printf '\033[H\033[2J\033[3J' > /dev/tty1 2>/dev/null || true

UAE_DIR="/usr/share/amicachy/uae"
SAVED_UAE="/home/amiga/Amiberry/conf/amicachy-default.uae"
SESSION_CONFIG="/tmp/amicachy-session-config"
BOOT_CONFIG="/home/amiga/Amiberry/conf/amicachy-boot-config"
AMIBERRY_BIN="/usr/bin/amiberry"
AMIBERRY_HOME="/usr/share/amiberry"
LABWC_EMULATOR_CONFIG="/etc/amicachy/labwc-emulator"

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
            printf '\033[H\033[2J\033[3J'
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

# Map vconsole KEYMAP → XKB layout.
# Most keymaps (es, de, fr, us) map directly; strip suffixes like
# la-latin1 → la, uk → gb.  Suppress errors if vconsole.conf is missing.
_raw_keymap=$(sed -n 's/^KEYMAP=//p' /etc/vconsole.conf 2>/dev/null || echo "us")
_raw_keymap="${_raw_keymap:-us}"
# Strip common vconsole suffixes to get the XKB base layout
_xkb_layout="${_raw_keymap%%-*}"  # la-latin1 → la, es-deadtilde → es
# Some well-known translations
case "$_xkb_layout" in
    uk) _xkb_layout="gb" ;;
esac
export XKB_DEFAULT_LAYOUT="$_xkb_layout"
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

# Mouse click fix for Amiberry on Wayland/Cage
export SDL_HINT_MOUSE_AUTO_CAPTURE=0

# Ensure the user has access to input devices (if not already handled)
# Usermod might fail in live env if not careful, but adding to group is safer.
usermod -aG input amiga 2>/dev/null || true

# --- Early Startup Control (hold or tap F5 during the prompt below) ---
EARLY_STARTUP_UAE=""
if [[ "$PROFILE" != "installer" && "$PROFILE" != "dev_station" && "$PROFILE" != "asset_manager" ]]; then
    # Visible cue so the user knows when to press F5. Goes to tty1 directly
    # so it shows up over Plymouth's residual splash. Window is 8 s; the
    # check_hotkey script honours $AMICACHY_HOTKEY_WINDOW.
    {
        printf '\033[?25l'                          # hide cursor
        printf '\033[2J\033[H'                      # clear + home
        printf '\033[1;33m'                         # bright yellow
        printf '\n\n  ════════════════════════════════════════════════════════\n'
        printf '    Press F5 NOW for AmiCachy Early Startup Control (8 s)\n'
        printf '  ════════════════════════════════════════════════════════\n'
        printf '\033[0m\n'
    } > /dev/tty1 2>/dev/null || true

    # Read input as root: the current login session does not gain new input-group
    # membership from usermod until the next login.
    if sudo -n env AMICACHY_HOTKEY_WINDOW=8 \
        python3 /usr/share/amicachy/tools/earlystartup/check_hotkey.py 2>/dev/null; then
        release_boot_splash
        cage -- /usr/bin/amicachy-earlystartup 2>/dev/null
        if [[ $? -eq 0 && -f "$SESSION_CONFIG" ]]; then
            _ref=$(<"$SESSION_CONFIG")
            _ref="${_ref%$'\n'}"
            if [[ -f "$_ref" ]]; then
                EARLY_STARTUP_UAE="$_ref"
            fi
        fi
    fi

    # Clear the prompt regardless of outcome so it doesn't linger if the
    # user did not press F5.
    printf '\033[2J\033[H' > /dev/tty1 2>/dev/null || true
fi

# --- Start automount daemon ---
# Runs silently in the background to automatically mount USB and internal drives.
# Drives will be mounted to /run/media/amiga/<Label>.
start_automount() {
    local log="/tmp/udiskie.log"

    if ! command -v udiskie >/dev/null 2>&1; then
        echo "udiskie not found; USB automount disabled" >> "$log"
        return 0
    fi

    if pgrep -xu "$(id -u)" udiskie >/dev/null 2>&1; then
        return 0
    fi

    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

    if command -v dbus-run-session >/dev/null 2>&1; then
        dbus-run-session -- udiskie --automount --no-tray --no-notify >> "$log" 2>&1 &
    else
        udiskie --automount --no-tray --no-notify >> "$log" 2>&1 &
    fi
}
start_automount

expose_boot_media() {
    local bootmnt="/run/archiso/bootmnt"
    local media_dir="/run/media/amiga"
    local label=""
    local source=""

    [[ -d "$bootmnt" ]] || return 0

    source="$(findmnt -n -o SOURCE "$bootmnt" 2>/dev/null || true)"
    if [[ -n "$source" && "$source" == /dev/* ]]; then
        label="$(lsblk -no LABEL "$source" 2>/dev/null | head -1 | xargs || true)"
    fi
    if [[ -z "$label" ]]; then
        read -ra _cmdline_media < /proc/cmdline
        for param in "${_cmdline_media[@]}"; do
            case "$param" in
                archisolabel=*) label="${param#archisolabel=}" ;;
            esac
        done
    fi
    label="${label:-AMICACHYUSB}"

    mkdir -p "$media_dir"
    chown amiga:amiga "$media_dir" 2>/dev/null || true
    ln -sfn "$bootmnt" "${media_dir}/${label}"
    chown -h amiga:amiga "${media_dir}/${label}" 2>/dev/null || true
}

expose_boot_media


# Plymouth owns the boot splash while the live system starts. Make sure it
# releases DRM/TTY before Cage or Labwc tries to draw the selected profile.
release_boot_splash() {
    if command -v plymouth >/dev/null 2>&1; then
        sudo -n timeout 1 plymouth quit 2>/dev/null || true
        sudo -n pkill -TERM -x plymouthd 2>/dev/null || true
        sleep 0.2
        sudo -n pkill -KILL -x plymouthd 2>/dev/null || true
    fi
    printf '\033[H\033[2J\033[3J' > /dev/tty1 2>/dev/null || true
    printf '\e[?25l' > /dev/tty1 2>/dev/null || true
}

release_boot_splash


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

# Returns 0 if the .uae looks usable (non-empty, has at least one key=value).
# A 0-byte or garbled .uae makes Amiberry segfault inside target_fixup_options
# during cfgfile_load — and once that happens, every subsequent boot reloops.
validate_uae_config() {
    local f="$1"
    [[ -s "$f" ]] || return 1
    grep -qE '^[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*=' "$f" 2>/dev/null
}

# Quarantine a broken .uae and unlink any boot reference pointing at it.
quarantine_uae() {
    local f="$1"
    local q="${f}.broken-$(date +%s)"
    mv -f "$f" "$q" 2>/dev/null || return 1
    echo "Quarantined $f -> $q" >&2
    if [[ -f "$BOOT_CONFIG" ]]; then
        local ref
        ref=$(<"$BOOT_CONFIG"); ref="${ref%$'\n'}"
        [[ "$ref" == "$f" ]] && rm -f "$BOOT_CONFIG"
    fi
}

# --- Emulator dispatcher ---
# Picks the right emulator based on the config file extension:
#   *.uae     → Amiberry (the default for everything)
#   *.fs-uae  → FS-UAE   (used for AROS-derived bundles where Amiberry's
#                          Picasso96 driver tiles the framebuffer horizontally
#                          on cage+SDL2+Wayland — see commit history for
#                          details).
# Both extensions live side by side in /home/amiga/Amiberry/conf/, the Early
# Startup Control lists both, and dispatch happens here without conversion.
run_emulator() {
    local config="$1"
    if [[ "$config" == *.fs-uae ]]; then
        run_fsuae "$config"
    else
        run_amiberry "$config"
    fi
}

# --- Run FS-UAE inside cage ---
run_fsuae() {
    local config="$1"
    if [[ ! -s "$config" ]]; then
        launch_fallback "FS-UAE config missing or empty: $config"
        return
    fi
    local logfile="/tmp/fsuae-launch.log"
    cage -- bash -c '"${@}" 2>&1 | tee '"$logfile"'; exit ${PIPESTATUS[0]}' _ \
        /usr/bin/fs-uae "$config"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        launch_fallback "fs-uae exited with code $rc (config: $config). Log: $logfile"
    fi
}

run_installer() {
    local log="/tmp/amicachy-installer.log"

    : > "$log"
    chmod 666 "$log" 2>/dev/null || true

    cage -- /usr/bin/amicachy-installer >> "$log" 2>&1
    local rc=$?

    printf '\033[H\033[2J\033[3J' > /dev/tty1 2>/dev/null || true
    {
        echo "AmiCachy installer exited before showing the UI."
        echo "Exit code: $rc"
        echo "Log: $log"
    } > /dev/tty1 2>/dev/null || true

    exec cage -- foot -e bash -c "
        echo '═══════════════════════════════════════════'
        echo '  AmiCachy — Installer did not start'
        echo '═══════════════════════════════════════════'
        echo ''
        echo '  Exit code: ${rc}'
        echo '  Log file:  ${log}'
        echo ''
        if [[ -s '${log}' ]]; then
            echo '  Last log lines:'
            echo ''
            tail -n 80 '${log}'
        else
            echo '  The installer produced no log output.'
        fi
        echo ''
        echo '═══════════════════════════════════════════'
        exec bash
    " || exec bash
}

# --- Run amiberry with crash protection (prevents autologin loop) ---
run_amiberry() {
    local requested="$1"
    shift
    local config="$requested"

    # Pre-flight: a corrupt/empty .uae would segfault Amiberry on load and,
    # because amilaunch is the autologin entry point, trap us in a crash loop.
    if [[ -f "$config" ]] && ! validate_uae_config "$config"; then
        echo "WARN: $config is empty or malformed." >&2
        quarantine_uae "$config"
        config="${UAE_DIR}/a1200.uae"
    fi

    local session_cmd="/usr/bin/amicachy-amiberry-session"
    local rt_flag=""
    if [[ "${1:-}" == "rt" ]]; then
        rt_flag="--rt"
    fi
    local logfile="/tmp/amiberry-launch.log"

    # labwc gives us libinput touchpad controls (tap-to-click/clickfinger),
    # while Amiberry still owns the full-screen application surface.
    labwc -C "$LABWC_EMULATOR_CONFIG" -S "$session_cmd $rt_flag '$config'"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        # Post-mortem: a crash mid-save can truncate the requested .uae to 0 bytes.
        # Quarantine so the next boot doesn't reload the broken file and loop.
        if [[ -f "$requested" ]] && ! validate_uae_config "$requested"; then
            echo "WARN: $requested corrupted after crash." >&2
            quarantine_uae "$requested"
        fi
        launch_fallback "amiberry exited with code $rc (config: $config). Log: $logfile"
    fi
}

# --- Dispatch based on profile ---
case "$PROFILE" in
    installer)
        run_installer
        ;;
    classic_68k)
        if [[ -x "$AMIBERRY_BIN" ]]; then
            if [[ -n "$EARLY_STARTUP_UAE" ]]; then
                run_emulator "$EARLY_STARTUP_UAE"
            elif [[ -f "$BOOT_CONFIG" ]]; then
                _bref=$(<"$BOOT_CONFIG")
                _bref="${_bref%$'\n'}"
                if [[ -f "$_bref" ]]; then
                    run_emulator "$_bref"
                else
                    run_emulator "${UAE_DIR}/a1200.uae"
                fi
            elif [[ -f "$SAVED_UAE" ]]; then
                # Legacy fallback
                run_emulator "$SAVED_UAE"
            else
                run_emulator "${UAE_DIR}/a1200.uae"
            fi
        else
            launch_fallback "amiberry not found (classic_68k)"
        fi
        ;;
    ppc_nitro)
        if [[ -x "$AMIBERRY_BIN" ]]; then
            run_amiberry "${UAE_DIR}/os41.uae" rt
        else
            launch_fallback "amiberry not found (ppc_nitro)"
        fi
        ;;
    dev_station)
        exec labwc -s /usr/bin/start_dev_env.sh
        ;;
    asset_manager)
        # Run the Asset Library GUI as a single fullscreen Cage app.
        # Cage exits when the GUI closes; that drops back to the login,
        # which auto-launches amilaunch again — so the user can pick another
        # boot entry from systemd-boot at the next reboot.
        exec cage -- /usr/bin/amicachy-fetch-asset gui
        ;;
    *)
        echo "ERROR: Unknown profile '${PROFILE}'." >&2
        echo "Valid profiles: installer, classic_68k, ppc_nitro, dev_station, asset_manager" >&2
        exit 1
        ;;
esac
