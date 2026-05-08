#!/usr/bin/env bash
# Fix missing or invalid terminal type in an installed AmiCachy system.

set -euo pipefail

log() {
    printf ':: %s\n' "$*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Run as root: sudo bash $0" >&2
    exit 1
fi

copy_terminfo() {
    local entry="$1"
    local src=""

    for candidate in \
        "$SCRIPT_DIR/terminfo/$entry" \
        "/usr/share/terminfo/$entry" \
        "/lib/terminfo/$entry"; do
        if [[ -f "$candidate" ]]; then
            src="$candidate"
            break
        fi
    done

    if [[ -n "$src" ]]; then
        install -D -m 0644 "$src" "/usr/share/terminfo/$entry"
        return 0
    fi

    return 1
}

log "Installing terminfo entries..."
for entry in \
    x/xterm \
    x/xterm-256color \
    l/linux \
    v/vt100 \
    v/vt102 \
    d/dumb \
    s/screen \
    s/screen-256color \
    t/tmux \
    t/tmux-256color; do
    copy_terminfo "$entry" || true
done

mkdir -p /etc/profile.d
cat > /etc/profile.d/amicachy-terminal.sh <<'EOF'
# AmiCachy terminal fallback for minimal installs.
case "${TERM:-}" in
    ""|"xterm-256 color"|"xterm-256_colour"|"unknown")
        export TERM=xterm-256color
        ;;
esac
EOF

for user_home in /home/*; do
    [[ -d "$user_home" ]] || continue
    user_name="$(basename "$user_home")"
    bashrc="$user_home/.bashrc"
    touch "$bashrc"
    if ! grep -q 'AmiCachy terminal fallback' "$bashrc"; then
        cat >> "$bashrc" <<'EOF'

# AmiCachy terminal fallback.
case "${TERM:-}" in
    ""|"xterm-256 color"|"xterm-256_colour"|"unknown")
        export TERM=xterm-256color
        ;;
esac
EOF
    fi
    chown "$user_name:$user_name" "$bashrc" 2>/dev/null || true
done

export TERM=xterm-256color
log "Terminal fallback installed. Open a new terminal or run: export TERM=xterm-256color"
