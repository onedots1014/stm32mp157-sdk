#!/bin/bash
# Cross-compile alsa-lib + alsa-utils + i2c-tools for STM32MP157 (arm-linux-gnueabi)
# Output goes into the board's rootfs-overlay directory.
# Run once on the host before building the rootfs.
#
# Usage:
#   cd stm32mp157-sdk   (repository root)
#   bash boards/stm32mp157/onedots_stm32mp157/scripts/setup-audio.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="$SCRIPT_DIR/../rootfs-overlay"
BUILD_DIR="/tmp/audio-cross-build"
CROSS="arm-linux-gnueabi"
SYSROOT="/usr/${CROSS}"

ALSA_LIB_VER="1.2.9"
ALSA_UTILS_VER="1.2.9"
I2C_TOOLS_VER="4.3"

ALSA_LIB_URL="https://www.alsa-project.org/files/pub/lib/alsa-lib-${ALSA_LIB_VER}.tar.bz2"
ALSA_UTILS_URL="https://www.alsa-project.org/files/pub/utils/alsa-utils-${ALSA_UTILS_VER}.tar.bz2"
I2C_TOOLS_URL="https://kernel.org/pub/software/utils/i2c-tools/i2c-tools-${I2C_TOOLS_VER}.tar.xz"

echo "[1/6] Checking cross-compiler..."
if ! command -v ${CROSS}-gcc &>/dev/null; then
    echo "ERROR: ${CROSS}-gcc not found. Install with:"
    echo "  sudo apt install gcc-arm-linux-gnueabi"
    exit 1
fi
echo "  OK: $(${CROSS}-gcc --version | head -1)"

echo "[2/6] Creating build directory..."
mkdir -p "$BUILD_DIR"
mkdir -p "$OVERLAY_DIR"/{usr/bin,usr/lib,lib,etc/alsa}

echo "[3/6] Building alsa-lib..."
cd "$BUILD_DIR"
if [[ ! -f "alsa-lib-${ALSA_LIB_VER}.tar.bz2" ]]; then
    wget -q "$ALSA_LIB_URL"
fi
tar xf "alsa-lib-${ALSA_LIB_VER}.tar.bz2"
cd "alsa-lib-${ALSA_LIB_VER}"
./configure \
    --host="${CROSS}" \
    --prefix=/usr \
    --with-sysroot="${SYSROOT}" \
    --disable-python \
    --disable-topology \
    --with-alsa-devdir=/dev/snd \
    CFLAGS="-O2" \
    > /dev/null
make -j"$(nproc)" > /dev/null
make install DESTDIR="$OVERLAY_DIR" > /dev/null
echo "  OK: alsa-lib built"

echo "[4/6] Building alsa-utils..."
cd "$BUILD_DIR"
if [[ ! -f "alsa-utils-${ALSA_UTILS_VER}.tar.bz2" ]]; then
    wget -q "$ALSA_UTILS_URL"
fi
tar xf "alsa-utils-${ALSA_UTILS_VER}.tar.bz2"
cd "alsa-utils-${ALSA_UTILS_VER}"
./configure \
    --host="${CROSS}" \
    --prefix=/usr \
    --with-sysroot="${SYSROOT}" \
    --disable-alsamixer \
    --disable-xmlto \
    --disable-nls \
    --with-alsa-inc-prefix="${OVERLAY_DIR}/usr/include" \
    --with-alsa-prefix="${OVERLAY_DIR}/usr/lib" \
    CFLAGS="-O2" \
    LDFLAGS="-L${OVERLAY_DIR}/usr/lib" \
    > /dev/null
make -j"$(nproc)" > /dev/null
make install DESTDIR="$OVERLAY_DIR" > /dev/null
echo "  OK: alsa-utils built"

echo "[5/6] Building i2c-tools..."
cd "$BUILD_DIR"
if [[ ! -f "i2c-tools-${I2C_TOOLS_VER}.tar.xz" ]]; then
    wget -q "$I2C_TOOLS_URL"
fi
tar xf "i2c-tools-${I2C_TOOLS_VER}.tar.xz"
cd "i2c-tools-${I2C_TOOLS_VER}"
make -j"$(nproc)" \
    CC="${CROSS}-gcc" \
    AR="${CROSS}-ar" \
    STRIP="${CROSS}-strip" \
    prefix=/usr \
    > /dev/null
make install DESTDIR="$OVERLAY_DIR" prefix=/usr > /dev/null
echo "  OK: i2c-tools built"

echo "[6/6] Copying glibc shared libraries from toolchain sysroot..."
LIBS=(
    "libm.so.6"
    "libc.so.6"
    "libpthread.so.0"
    "ld-linux.so.3"
    "libasound.so.2"
)
# Copy from toolchain sysroot lib directory
for lib in "${LIBS[@]}"; do
    src_path=$(find "${SYSROOT}/lib" -name "${lib}" 2>/dev/null | head -1)
    if [[ -n "$src_path" ]]; then
        cp -L "$src_path" "$OVERLAY_DIR/lib/"
        echo "  Copied: $lib"
    fi
done
# Copy dynamic linker
ld_src=$(find "${SYSROOT}/lib" -name "ld-linux*.so*" 2>/dev/null | head -1)
if [[ -n "$ld_src" ]]; then
    cp -L "$ld_src" "$OVERLAY_DIR/lib/"
fi

# Strip binaries to reduce size
${CROSS}-strip "$OVERLAY_DIR"/usr/bin/aplay \
               "$OVERLAY_DIR"/usr/bin/arecord \
               "$OVERLAY_DIR"/usr/bin/amixer \
               "$OVERLAY_DIR"/usr/bin/i2cdetect \
               "$OVERLAY_DIR"/usr/bin/i2cget \
               "$OVERLAY_DIR"/usr/bin/i2cset 2>/dev/null || true

echo ""
echo "Done. Overlay contents:"
find "$OVERLAY_DIR" -type f | sort
echo ""
echo "Now rebuild the rootfs:"
echo "  ./build.sh busybox -b onedots_stm32mp157"
