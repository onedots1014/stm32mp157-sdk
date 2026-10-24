#!/bin/bash
set -euo pipefail

# Resolve paths relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
UBOOT_DIR="${SRC_DIR:-$ROOT_DIR/sources}/u-boot"

# Cross-compilation
export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabi-

# Build configuration (overridable via env vars)
UBOOT_DEFCONFIG="${UBOOT_DEFCONFIG:-stm32mp15_trusted_defconfig}"
DEVICE_TREE="${DEVICE_TREE:-stm32mp157c-onedots-512d-v1}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

# Output configuration
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output/uboot}"
CLEAN_BUILD="${CLEAN_BUILD:-false}"
VERBOSE="${VERBOSE:-false}"

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
U-Boot Build Script for STM32MP157

Usage: $0 [options]

Options:
    -h, --help          Show this help
    -c, --clean         Clean before build
    -v, --verbose       Verbose output
    -j N                Parallel jobs (default: $(nproc))
    -o DIR              Output directory (default: $ROOT_DIR/output/uboot)
    -d CFG              U-Boot defconfig (default: $UBOOT_DEFCONFIG)
    -t DT               Device tree name (default: $DEVICE_TREE)

Examples:
    $0                  Default build
    $0 -c -j4           Clean build with 4 jobs
EOF
}

# ==============================================================================
# Argument parsing
# ==============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)    show_help; exit 0 ;;
            -c|--clean)   CLEAN_BUILD=true ;;
            -v|--verbose) VERBOSE=true ;;
            -j)           BUILD_JOBS="$2"; shift ;;
            -o)           OUTPUT_DIR="$2"; shift ;;
            -d)           UBOOT_DEFCONFIG="$2"; shift ;;
            -t)           DEVICE_TREE="$2"; shift ;;
            *)            die "Unknown option: $1" ;;
        esac
        shift
    done
}

# ==============================================================================
# Environment check
# ==============================================================================

check_environment() {
    log INFO "Checking build environment..."

    command -v "${CROSS_COMPILE}gcc" &>/dev/null \
        || die "Cross-compiler not found: ${CROSS_COMPILE}gcc"
    command -v make &>/dev/null \
        || die "make not found"

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

# Step 1: configure U-Boot
configure_uboot() {
    log BUILD "[1/3] Configuring U-Boot: $UBOOT_DEFCONFIG"

    [[ -f "configs/$UBOOT_DEFCONFIG" ]] \
        || die "defconfig not found: configs/$UBOOT_DEFCONFIG"

    make "$UBOOT_DEFCONFIG" || die "U-Boot configuration failed"
    log OK "U-Boot configured"
}

# Step 2: compile U-Boot
compile_uboot() {
    log BUILD "[2/3] Compiling U-Boot (device tree: $DEVICE_TREE)..."
    local start_time
    start_time=$(date +%s)

    make "DEVICE_TREE=$DEVICE_TREE" all -j"$BUILD_JOBS" \
        || die "U-Boot compilation failed"

    local elapsed=$(( $(date +%s) - start_time ))
    log OK "U-Boot compiled (${elapsed}s)"
}

# Step 3: collect build artifacts
collect_artifacts() {
    log BUILD "[3/3] Collecting artifacts to $OUTPUT_DIR"

    mkdir -p "$OUTPUT_DIR"

    # Binary files to collect
    local files=(
        u-boot.bin
        u-boot-dtb.bin
        u-boot-nodtb.bin
        u-boot.dtb
        u-boot.stm32
    )

    # Copy existing files
    local copied=0
    for f in "${files[@]}"; do
        if [[ -f "$f" ]]; then
            cp "$f" "$OUTPUT_DIR/" && copied=$((copied + 1))
        else
            log WARN "File not found, skipping: $f"
        fi
    done

    log OK "Collected $copied artifact(s)"

    # Show main file sizes
    if [[ -f "$OUTPUT_DIR/u-boot.stm32" ]]; then
        log INFO "  u-boot.stm32: $(du -h "$OUTPUT_DIR/u-boot.stm32" | cut -f1)"
    fi
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    parse_args "$@"
    cd "$UBOOT_DIR"

    log INFO "U-Boot build for STM32MP157"
    log INFO "  defconfig:    $UBOOT_DEFCONFIG"
    log INFO "  device tree:  $DEVICE_TREE"
    log INFO "  output:       $OUTPUT_DIR"
    log INFO "  jobs:         $BUILD_JOBS"

    check_environment
    clean_build
    configure_uboot
    compile_uboot
    collect_artifacts

    log OK "U-Boot build completed"
}

trap 'die "Build failed"' ERR
main "$@"
