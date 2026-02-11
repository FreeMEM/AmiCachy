#!/usr/bin/env bash
# AmiCachy — CPU architecture level detection for CachyOS builds.
#
# Source this file from build scripts to auto-detect:
#   CPU_ARCH_LEVEL  — "x86-64-v4", "x86-64-v3", or "x86-64"
#   DOCKER_IMAGE    — CachyOS Docker image matching the host CPU
#
# The user can override DOCKER_IMAGE via environment variable.
# If the CPU lacks AVX2 (x86-64-v3), a warning is printed and the
# generic CachyOS image/repos are used automatically.

_detect_cpu_arch() {
    local flags
    flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2 || echo "")

    if echo "$flags" | grep -qw avx512f; then
        CPU_ARCH_LEVEL="x86-64-v4"
    elif echo "$flags" | grep -qw avx2; then
        CPU_ARCH_LEVEL="x86-64-v3"
    else
        CPU_ARCH_LEVEL="x86-64"
    fi

    # Auto-select Docker image (user env var takes priority)
    if [[ -z "${DOCKER_IMAGE:-}" ]]; then
        case "$CPU_ARCH_LEVEL" in
            x86-64-v4|x86-64-v3)
                DOCKER_IMAGE="cachyos/cachyos-v3:latest"
                ;;
            *)
                DOCKER_IMAGE="cachyos/cachyos:latest"
                echo "NOTICE: CPU is ${CPU_ARCH_LEVEL} (no AVX2)." >&2
                echo "        Using generic CachyOS image. Emulation ~10-20% slower." >&2
                echo "        For x86-64-v3: Intel Haswell+ (2013) / AMD Excavator+ (2015)" >&2
                echo "" >&2
                ;;
        esac
    fi

    export CPU_ARCH_LEVEL DOCKER_IMAGE
}

# Generate a pacman.conf appropriate for the detected CPU level.
# On v3+ CPUs: returns the original path unchanged.
# On generic CPUs: creates a filtered copy without [cachyos-v3] repo.
#
# Usage: CONF=$(get_pacman_conf /path/to/pacman.conf)
get_pacman_conf() {
    local original="${1:?Usage: get_pacman_conf /path/to/pacman.conf}"

    if [[ "$CPU_ARCH_LEVEL" == "x86-64-v3" || "$CPU_ARCH_LEVEL" == "x86-64-v4" ]]; then
        echo "$original"
    else
        local filtered="/tmp/amicachy-pacman-generic.conf"
        # Remove the entire [cachyos-v3] section (header + Include + SigLevel + blank line)
        sed '/^\[cachyos-v3\]/,/^$/d' "$original" > "$filtered"
        echo "$filtered"
    fi
}

# Run detection immediately when sourced
_detect_cpu_arch
