#!/bin/bash
set -euo pipefail

# Resolve paths relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
BUSYBOX_DIR="${SRC_DIR:-$ROOT_DIR/sources}/busybox"
BOARD_DIR="$ROOT_DIR/boards/stm32mp157/${BOARD_NAME:-onedots_stm32mp157}"

# Cross-compilation
export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabi-

# wpa_supplicant version to build
WPA_VERSION="2.10"
WPA_SRC_DIR="$ROOT_DIR/wpa_supplicant-${WPA_VERSION}"

# Output configuration
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output}"
ROOTFS_IMG="$OUTPUT_DIR/rootfs.ext4"
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-64}"

# Temporary install directory
INSTALL_DIR="$OUTPUT_DIR/_install"

# Color definitions
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# ==============================================================================
# Utility functions
# ==============================================================================

log() {
    local level="$1" msg="$2"
    case "$level" in
        INFO)  echo -e "${BLUE}[INFO]${NC} $msg" ;;
        OK)    echo -e "${GREEN}[ OK ]${NC} $msg" ;;
        BUILD) echo -e "${CYAN}[BUILD]${NC} $msg" ;;
    esac
    return 0
}

die() {
    echo -e "\033[0;31m[ERROR]\033[0m $1" >&2
    exit 1
}

# ==============================================================================
# Build steps
# ==============================================================================

# Step 1: configure BusyBox
configure_busybox() {
    log BUILD "[1/4] Configuring BusyBox..."

    make defconfig || die "BusyBox defconfig failed"

    # Enable static build and init
    sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
    sed -i 's/# CONFIG_INIT is not set/CONFIG_INIT=y/' .config

    # SHA1/SHA256 HW acceleration only exists on x86 (SHA-NI). defconfig enables
    # it, and BusyBox 1.37.0 then fails to cross-compile for ARM:
    # hash_md5_sha.c references sha1_process_block64_shaNI, which is only
    # declared for x86. Disabling it costs nothing on ARM.
    sed -i 's/^CONFIG_SHA1_HWACCEL=y/# CONFIG_SHA1_HWACCEL is not set/; s/^CONFIG_SHA256_HWACCEL=y/# CONFIG_SHA256_HWACCEL is not set/' .config

    # tc (traffic control) uses CBQ definitions that were removed from the
    # kernel UAPI headers in Linux 6.8, so it fails with newer toolchains.
    # The board doesn't need it.
    sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config

    # Apply configuration changes without prompting
    yes "" | make oldconfig >/dev/null 2>&1 || true

    log OK "BusyBox configured (static build, init enabled)"
}

# Step 2: compile BusyBox
compile_busybox() {
    log BUILD "[2/4] Compiling BusyBox..."
    local start_time
    start_time=$(date +%s)

    make -j"$(nproc)" || die "BusyBox compilation failed"

    local elapsed=$(( $(date +%s) - start_time ))
    log OK "BusyBox compiled (${elapsed}s)"
}

# Step 3: install BusyBox to temporary directory
install_busybox() {
    log BUILD "[3/4] Installing BusyBox to $INSTALL_DIR..."

    rm -rf "$INSTALL_DIR"
    make CONFIG_PREFIX="$INSTALL_DIR" install || die "BusyBox install failed"

    # Create standard rootfs directories
    mkdir -p "$INSTALL_DIR"/{bin,sbin,etc,proc,sys,dev,tmp,lib}
    mkdir -p "$INSTALL_DIR/sys/kernel/debug"

    # Copy M4 firmware
    mkdir -p "$INSTALL_DIR/lib/firmware"
    if [[ -d "$BOARD_DIR/M4" ]]; then
        cp "$BOARD_DIR/M4"/* "$INSTALL_DIR/lib/firmware/" 2>/dev/null || true
        chmod 644 "$INSTALL_DIR/lib/firmware"/* 2>/dev/null || true
        log INFO "Copied M4 firmware to /lib/firmware"
    fi

    # Copy custom applications
    mkdir -p "$INSTALL_DIR/usr/bin"
    if [[ -d "$ROOT_DIR/app/bin" ]]; then
        cp "$ROOT_DIR/app/bin"/* "$INSTALL_DIR/usr/bin/" 2>/dev/null || true
        chmod 755 "$INSTALL_DIR/usr/bin"/* 2>/dev/null || true
        log INFO "Copied custom applications to /usr/bin"
    fi
    if [[ -f "$ROOT_DIR/app/kws_listener.py" ]]; then
        cp "$ROOT_DIR/app/kws_listener.py" "$INSTALL_DIR/usr/bin/"
        chmod 755 "$INSTALL_DIR/usr/bin/kws_listener.py"
        log INFO "Copied kws_listener.py to /usr/bin"
    fi

    # Copy kernel modules
    local modules_src="$OUTPUT_DIR/modules_install/lib/modules"
    if [[ -d "$modules_src" ]]; then
        mkdir -p "$INSTALL_DIR/lib/modules"
        cp -a "$modules_src"/. "$INSTALL_DIR/lib/modules/"
        log INFO "Copied kernel modules to /lib/modules"
    else
        log INFO "No kernel modules found at $modules_src (run 'build.sh kernel' first)"
    fi

    # Create inittab
    cat > "$INSTALL_DIR/etc/inittab" <<'EOF'
::sysinit:/bin/busybox mount -t proc proc /proc
::sysinit:/bin/busybox mount -t sysfs sys /sys
::sysinit:/bin/busybox mount -t debugfs none /sys/kernel/debug
::sysinit:/etc/init.d/rcS
ttySTM0::respawn:/bin/sh
::ctrlaltdel:/bin/reboot
::shutdown:/bin/umount -a -r
EOF

    # Create rcS entry point for init.d scripts
    mkdir -p "$INSTALL_DIR/etc/init.d"
    cat > "$INSTALL_DIR/etc/init.d/rcS" <<'EOF'
#!/bin/sh
for script in /etc/init.d/S[0-9][0-9]*; do
    [ -x "$script" ] && "$script" start
done
EOF
    chmod +x "$INSTALL_DIR/etc/init.d/rcS"

    log OK "BusyBox installed"
}

# Step 3.5a-pre: cross-compile kws_listener.c → app/bin/kws_listener
build_kws_listener() {
    local src="$ROOT_DIR/app/kws_listener.c"
    local bin="$ROOT_DIR/app/bin/kws_listener"

    [[ -f "$src" ]] || { log INFO "kws_listener.c not found, skipping"; return 0; }

    log BUILD "[pre] Compiling kws_listener (static ARM)..."
    mkdir -p "$ROOT_DIR/app/bin"
    ${CROSS_COMPILE}gcc -O2 -static -o "$bin" "$src" \
        || die "kws_listener compilation failed"
    chmod 755 "$bin"
    log OK "kws_listener compiled → $bin"
}

# Step 3.5a: cross-compile wpa_supplicant (WEXT driver + internal crypto, no libnl/OpenSSL)
build_wpa_supplicant() {
    local wpa_dir="$WPA_SRC_DIR/wpa_supplicant"

    if [[ ! -f "$wpa_dir/wpa_supplicant" ]]; then
        if [[ ! -d "$WPA_SRC_DIR" ]]; then
            local tarball="wpa_supplicant-${WPA_VERSION}.tar.gz"
            if [[ ! -f "$ROOT_DIR/${tarball}" ]]; then
                log BUILD "Downloading wpa_supplicant ${WPA_VERSION}..."
                wget -q -O "$ROOT_DIR/${tarball}" \
                    "https://w1.fi/releases/${tarball}" \
                    || die "Download failed. Place ${tarball} in $ROOT_DIR manually."
            fi
            tar -xzf "$ROOT_DIR/${tarball}" -C "$ROOT_DIR"
        fi

        log BUILD "Compiling wpa_supplicant ${WPA_VERSION} (WEXT, internal crypto)..."
        cat > "$wpa_dir/.config" <<'WPACFG'
CONFIG_DRIVER_WEXT=y
CONFIG_WIRELESS_EXTENSION=y
CONFIG_WPA=y
CONFIG_RSN_PREAUTH=y
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
CONFIG_INTERNAL_LIBTOMMATH_FAST=y
CONFIG_NO_PKCS11=y
CONFIG_NO_RANDOM_POOL=y
CONFIG_CTRL_IFACE=y
CONFIG_CTRL_IFACE_UNIX=y
CONFIG_IEEE8021X_EAPOL=n
WPACFG
        make -C "$wpa_dir" CC="${CROSS_COMPILE}gcc" \
            BINDIR=/usr/sbin LIBDIR=/usr/lib \
            -j"$(nproc)" wpa_supplicant wpa_passphrase \
            || die "wpa_supplicant build failed"
        log OK "wpa_supplicant compiled"
    fi

    install -D -m 755 "$wpa_dir/wpa_supplicant" "$INSTALL_DIR/usr/sbin/wpa_supplicant"
    install -D -m 755 "$wpa_dir/wpa_passphrase" "$INSTALL_DIR/usr/sbin/wpa_passphrase"
    log OK "wpa_supplicant installed to rootfs"
}

# Step 3.5b: apply board-specific rootfs overlay
apply_overlay() {
    local overlay_dir="$BOARD_DIR/rootfs-overlay"
    if [[ -d "$overlay_dir" ]]; then
        log BUILD "[3.5/4] Applying rootfs overlay from $overlay_dir..."
        cp -a "$overlay_dir"/. "$INSTALL_DIR/"
        log OK "Overlay applied"
    fi
}

# Step 4: create rootfs.ext4 image
create_rootfs_image() {
    log BUILD "[4/4] Creating rootfs.ext4 (${IMAGE_SIZE_MB}MB)..."

    mkdir -p "$OUTPUT_DIR"
    rm -f "$ROOTFS_IMG"

    # Create ext4 image without root using genext2fs
    genext2fs -d "$INSTALL_DIR" -b $((IMAGE_SIZE_MB * 1024)) "$ROOTFS_IMG" \
        || die "genext2fs failed"

    # Clean up temporary directory
    rm -rf "$INSTALL_DIR"

    log OK "rootfs.ext4 created: $ROOTFS_IMG ($(du -h "$ROOTFS_IMG" | cut -f1))"
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    cd "$BUSYBOX_DIR"

    local subcommand="${1:-busybox}"

    case "$subcommand" in
        busybox)
            log INFO "Building BusyBox for STM32MP157"
            configure_busybox
            compile_busybox
            log OK "BusyBox build completed"
            ;;
        rootfs)
            log INFO "Creating rootfs for STM32MP157"
            log INFO "  output:     $OUTPUT_DIR"
            log INFO "  image size: ${IMAGE_SIZE_MB}MB"
            build_kws_listener
            install_busybox
            build_wpa_supplicant
            apply_overlay
            create_rootfs_image
            log OK "rootfs build completed"
            ;;
        *)
            die "Unknown subcommand: $subcommand (expected: busybox|rootfs)"
            ;;
    esac
}

trap 'die "Build failed"' ERR
main "$@"
