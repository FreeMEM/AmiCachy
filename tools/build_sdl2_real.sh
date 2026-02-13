#!/usr/bin/env bash
# AmiCachy — Build the real SDL2 library (not sdl2-compat)
#
# CachyOS/Arch replaced the real SDL2 with sdl2-compat (SDL2 API over SDL3).
# This compat layer causes SIGSEGV in amiberry due to heap corruption.
# We build the real SDL2 from source and use SDL_DYNAMIC_API to bypass it.
#
# Output: out/libSDL2-real/libSDL2-2.0.so.0
# Usage: SDL_DYNAMIC_API=/usr/local/lib/libSDL2-2.0.so.0 amiberry
#        (amilaunch.sh does this automatically if the library exists)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib/cpu_arch.sh
source "${SCRIPT_DIR}/lib/cpu_arch.sh"

SDL2_VERSION="2.30.10"

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is not installed." >&2
    exit 1
fi

echo "========================================"
echo "  AmiCachy — Build real SDL2 ${SDL2_VERSION}"
echo "  CPU: ${CPU_ARCH_LEVEL}"
echo "  Docker: ${DOCKER_IMAGE}"
echo "========================================"
echo ""

docker run --rm \
    -v "$PROJECT_DIR:/work" \
    "$DOCKER_IMAGE" \
    bash -c "
        set -euo pipefail

        echo ':: Installing build dependencies...'
        pacman -Sy --noconfirm --needed \
            cmake ninja gcc git \
            wayland wayland-protocols libxkbcommon \
            mesa libpulse alsa-lib pipewire \
            libdrm libdecor \
            &>/dev/null

        echo ':: Cloning SDL2 ${SDL2_VERSION}...'
        cd /tmp
        git clone --depth 1 --branch release-${SDL2_VERSION} \
            https://github.com/libsdl-org/SDL.git SDL2 2>/dev/null

        echo ':: Building SDL2...'
        cd SDL2
        cmake -B build -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=/usr/local \
            -DSDL_WAYLAND=ON \
            -DSDL_WAYLAND_LIBDECOR=ON \
            -DSDL_X11=OFF \
            -DSDL_KMSDRM=ON \
            -DSDL_PULSEAUDIO=ON \
            -DSDL_PIPEWIRE=OFF \
            -DSDL_ALSA=ON \
            -DSDL_SHARED=ON \
            -DSDL_STATIC=OFF

        cmake --build build -j\$(nproc)

        echo ':: Copying library...'
        mkdir -p /work/out/libSDL2-real
        cp -v build/libSDL2-2.0.so.0.* /work/out/libSDL2-real/
        cd /work/out/libSDL2-real
        ln -sf libSDL2-2.0.so.0.* libSDL2-2.0.so.0
        ln -sf libSDL2-2.0.so.0 libSDL2.so

        echo ''
        echo ':: SDL2 real library built successfully:'
        ls -la /work/out/libSDL2-real/
    "

echo ""
echo ":: Output: out/libSDL2-real/"
echo ""
echo ":: To test in the dev VM:"
echo "   sudo -v && ./tools/dev_vm.sh sync && ./tools/dev_vm.sh boot"
echo "   (sync auto-installs the library; amilaunch.sh detects it)"
