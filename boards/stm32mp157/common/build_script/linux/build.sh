#!/bin/bash
set -euo pipefail

# Resolve paths relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
LINUX_DIR="${SRC_DIR:-$ROOT_DIR/sources}/linux"
BOARD_DIR="$ROOT_DIR/boards/stm32mp157"

# Cross-compilation
export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabi-

# Build configuration (overridable via env vars)
KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG:-onedots_stm32mp157c_defconfig}"
LOADADDR="${LOADADDR:-0xC2000040}"
DEVICE_TREE="${DEVICE_TREE:-stm32mp157c-onedots-512d-v1}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
BOARD_NAME="${BOARD_NAME:-onedots_stm32mp157}"

# Output configuration
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output}"
BOOTFS_IMG="$OUTPUT_DIR/bootfs.ext4"
BOOTFS_SIZE_MB="${BOOTFS_SIZE_MB:-32}"
SKIP_BOOTFS="${SKIP_BOOTFS:-false}"
CLEAN_BUILD="${CLEAN_BUILD:-false}"
VERBOSE="${VERBOSE:-false}"

# Kernel build artifact paths (relative to $LINUX_DIR)
DTB_DIR="arch/arm/boot/dts"
UIMAGE="arch/arm/boot/uImage"

# Color definitions
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
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
        ERROR) echo -e "${RED}[ERROR]${NC} $msg" >&2 ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} $msg" ;;
        BUILD) echo -e "${CYAN}[BUILD]${NC} $msg" ;;
    esac
    return 0
}

die() {
    log ERROR "$1"
    exit 1
}

show_help() {
    cat <<EOF
Linux Kernel Build Script for STM32MP157

Usage: $0 [options]

Options:
    -h, --help              Show this help
    -c, --clean             Clean before build
    -v, --verbose           Verbose output
    -j N                    Parallel jobs (default: $(nproc))
    -o DIR                  Output directory (default: $ROOT_DIR/output)
    -d CFG                  Kernel defconfig (default: $KERNEL_DEFCONFIG)
    -t DT                   Device tree name (default: $DEVICE_TREE)
    -b BOARD                Board name (default: $BOARD_NAME)
    --skip-bootfs           Skip bootfs image creation
    --bootfs-size N         Bootfs size in MB (default: $BOOTFS_SIZE_MB)
    --loadaddr ADDR         Kernel load address (default: $LOADADDR)

Examples:
    $0                      Default build
    $0 -c -j4               Clean build with 4 jobs
    $0 --skip-bootfs        Kernel only, skip bootfs
EOF
}

# ==============================================================================
# Argument parsing
# ==============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)       show_help; exit 0 ;;
            -c|--clean)      CLEAN_BUILD=true ;;
            -v|--verbose)    VERBOSE=true ;;
            -j)              BUILD_JOBS="$2"; shift ;;
            -o)              OUTPUT_DIR="$2"; shift ;;
            -d)              KERNEL_DEFCONFIG="$2"; shift ;;
            -t)              DEVICE_TREE="$2"; shift ;;
            -b)              BOARD_NAME="$2"; shift ;;
            --skip-bootfs)   SKIP_BOOTFS=true ;;
            --bootfs-size)   BOOTFS_SIZE_MB="$2"; shift ;;
            --loadaddr)      LOADADDR="$2"; shift ;;
            *)               die "Unknown option: $1" ;;
        esac
        shift
    done

    # Recompute derived paths after argument parsing
    BOOTFS_IMG="$OUTPUT_DIR/bootfs.ext4"
}

# ==============================================================================
# Environment check
# ==============================================================================

check_environment() {
    log INFO "Checking build environment..."

    command -v "${CROSS_COMPILE}gcc" &>/dev/null \
        || die "Cross-compiler not found: ${CROSS_COMPILE}gcc"

    local tools=(make dd mkfs.vfat mcopy mmd)
    for tool in "${tools[@]}"; do
        command -v "$tool" &>/dev/null || die "Missing tool: $tool"
    done

    if [[ "$SKIP_BOOTFS" != "true" ]]; then
        export MTOOLS_SKIP_CHECK=1
    fi

    log OK "Environment check passed"
}

# ==============================================================================
# Build steps
# ==============================================================================

# Step 0 (optional): clean previous build
clean_build() {
    if [[ "$CLEAN_BUILD" == "true" ]]; then
        log BUILD "Cleaning previous build..."
        make distclean || true
        log OK "Clean completed"
    fi
}

# Step 1: configure kernel
configure_kernel() {
    log BUILD "[1/4] Configuring kernel: $KERNEL_DEFCONFIG"

    [[ -f "arch/arm/configs/$KERNEL_DEFCONFIG" ]] \
        || die "defconfig not found: arch/arm/configs/$KERNEL_DEFCONFIG"

    make "$KERNEL_DEFCONFIG" || die "Kernel configuration failed"
    make olddefconfig || die "Kernel olddefconfig failed"
    log OK "Kernel configured"
}

# Step 2: compile kernel image, device tree, and modules
compile_kernel() {
    log BUILD "[2/4] Compiling kernel, device tree, and modules..."
    local start_time
    start_time=$(date +%s)

    # Build uImage
    log INFO "Compiling uImage (LOADADDR=$LOADADDR)..."
    make uImage "LOADADDR=$LOADADDR" -j"$BUILD_JOBS" \
        || die "uImage compilation failed"

    # Build device tree
    log INFO "Compiling device tree: ${DEVICE_TREE}.dtb..."
    make "${DEVICE_TREE}.dtb" -j"$BUILD_JOBS" \
        || die "Device tree compilation failed"

    # Build modules
    log INFO "Compiling kernel modules..."
    make modules -j"$BUILD_JOBS" \
        || die "Kernel modules compilation failed"

    # Install modules to output staging directory
    local modules_dir="$OUTPUT_DIR/modules_install"
    rm -rf "$modules_dir"
    make INSTALL_MOD_PATH="$modules_dir" modules_install \
        || die "Kernel modules install failed"
    # Remove build/source symlinks (they point to host paths, not needed in rootfs)
    find "$modules_dir" -name "build" -o -name "source" | xargs rm -f 2>/dev/null || true
    log OK "Modules installed to $modules_dir"

    # Verify artifacts
    [[ -f "$UIMAGE" ]]                    || die "uImage not found after build"
    [[ -f "$DTB_DIR/${DEVICE_TREE}.dtb" ]] || die "DTB not found after build"

    local elapsed=$(( $(date +%s) - start_time ))
    log OK "Kernel compiled (${elapsed}s)"
    log INFO "  uImage: $(du -h "$UIMAGE" | cut -f1)"
    log INFO "  DTB:    $(du -h "$DTB_DIR/${DEVICE_TREE}.dtb" | cut -f1)"
}

# Step 3: prepare bootfs content in a temp directory
prepare_bootfs() {
    if [[ "$SKIP_BOOTFS" == "true" ]]; then
        log INFO "[3/4] Skipping bootfs preparation (--skip-bootfs)"
        return 0
    fi

    log BUILD "[3/4] Preparing bootfs content..."

    local tmpdir="$OUTPUT_DIR/temp_bootfs"
    local board_boot="$BOARD_DIR/$BOARD_NAME/boot"

    mkdir -p "$tmpdir"
    rm -rf "${tmpdir:?}"/*

    # Copy kernel artifacts
    cp "$UIMAGE" "$tmpdir/"
    cp "$DTB_DIR/${DEVICE_TREE}.dtb" "$tmpdir/"

    # Copy board boot files (extlinux, splash, etc.)
    if [[ -d "$board_boot" ]]; then
        cp -r "$board_boot"/* "$tmpdir/"
        log INFO "Copied board boot files from $board_boot"
    else
        log WARN "Board boot directory not found: $board_boot"
    fi

    if [[ "$VERBOSE" == "true" ]]; then
        log INFO "bootfs content:"
        ls -la "$tmpdir"
    fi

    log OK "bootfs content ready"
}

# Step 4: create bootfs.ext4 image (vfat inside)
create_bootfs() {
    if [[ "$SKIP_BOOTFS" == "true" ]]; then
        log INFO "[4/4] Skipping bootfs image (--skip-bootfs)"
        return 0
    fi

    log BUILD "[4/4] Creating bootfs image (${BOOTFS_SIZE_MB}MB vfat)..."

    local tmpdir="$OUTPUT_DIR/temp_bootfs"

    rm -f "$BOOTFS_IMG"
    dd if=/dev/zero of="$BOOTFS_IMG" bs=1M count="$BOOTFS_SIZE_MB" 2>/dev/null
    mkfs.vfat "$BOOTFS_IMG" >/dev/null 2>&1

    # Copy files into the FAT image using mtools
    for item in "$tmpdir"/*; do
        [[ -e "$item" ]] || continue
        if [[ -d "$item" ]]; then
            mmd -i "$BOOTFS_IMG" "::/$(basename "$item")" 2>/dev/null || true
            mcopy -i "$BOOTFS_IMG" -s "$item"/* "::/$(basename "$item")/" 2>/dev/null || true
        else
            mcopy -i "$BOOTFS_IMG" "$item" ::/ 2>/dev/null || true
        fi
    done

    rm -rf "$tmpdir"

    log OK "bootfs image created: $BOOTFS_IMG ($(du -h "$BOOTFS_IMG" | cut -f1))"

    if [[ "$VERBOSE" == "true" ]]; then
        log INFO "bootfs image content:"
        mdir -i "$BOOTFS_IMG" ::/ 2>/dev/null || true
    fi
}

# ==============================================================================
# Main
# ==============================================================================

cleanup_on_error() {
    log ERROR "Build failed"
    rm -rf "$OUTPUT_DIR/temp_bootfs" 2>/dev/null || true
    exit 1
}

main() {
    parse_args "$@"
    cd "$LINUX_DIR"

    log INFO "Linux kernel build for STM32MP157"
    log INFO "  defconfig:    $KERNEL_DEFCONFIG"
    log INFO "  device tree:  $DEVICE_TREE"
    log INFO "  board:        $BOARD_NAME"
    log INFO "  output:       $OUTPUT_DIR"
    log INFO "  jobs:         $BUILD_JOBS"
    log INFO "  load address: $LOADADDR"

    check_environment
    clean_build
    configure_kernel
    compile_kernel
    prepare_bootfs
    create_bootfs

    log OK "Linux kernel build completed"
}

trap cleanup_on_error ERR
main "$@"
