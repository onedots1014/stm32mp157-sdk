#!/bin/bash
# Build script for STM32MP157 M4 firmware using STM32CubeIDE headless build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/CM4"
# Treat "clean" as a subcommand, not a build config
BUILD_CONFIG="Debug"
[[ "${1:-}" == "Debug" || "${1:-}" == "Release" ]] && BUILD_CONFIG="$1"
WORKSPACE="/tmp/stm32_m4_ws_$$"

# STM32CubeIDE path
CUBEIDE_DIR="${CUBEIDE_DIR:-/opt/st/stm32cubeide_2.1.0}"
HEADLESS_BUILD="$CUBEIDE_DIR/headless-build.sh"

# Color definitions
BLUE='\033[0;34m'; GREEN='\033[0;32m'; RED='\033[0;31m'
CYAN='\033[0;36m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_build()   { echo -e "${CYAN}[BUILD]${NC} $1"; }

# Verify STM32CubeIDE installation
if [[ ! -x "$HEADLESS_BUILD" ]]; then
    log_error "STM32CubeIDE not found at: $CUBEIDE_DIR"
    log_error "Set CUBEIDE_DIR to your STM32CubeIDE installation path"
    exit 1
fi

clean_build() {
    log_build "Cleaning M4 firmware (config: $BUILD_CONFIG)..."

    "$HEADLESS_BUILD" \
        -data "$WORKSPACE" \
        -import "$PROJECT_DIR" \
        -cleanBuild "stm32_m4_CM4/$BUILD_CONFIG" \
        2>&1 | grep -E "Clean-only|Finished clean|rm -rf|Removing|\.o$" || true

    rm -rf "$WORKSPACE"
    log_success "Clean completed"
}

do_build() {
    log_build "Building M4 firmware (config: $BUILD_CONFIG)..."

    local build_log="/tmp/stm32_m4_build_$$.log"

    "$HEADLESS_BUILD" \
        -data "$WORKSPACE" \
        -import "$PROJECT_DIR" \
        -build "stm32_m4_CM4/$BUILD_CONFIG" \
        2>&1 | tee "$build_log" | grep -E "^(arm-none|Finished|   text|[[:space:]]+[0-9])|error:|warning:|undefined reference|overflow|ld:" || true

    rm -rf "$WORKSPACE"

    local elf="$PROJECT_DIR/$BUILD_CONFIG/stm32_m4_CM4.elf"
    if [[ -f "$elf" ]]; then
        rm -f "$build_log"
        log_success "M4 firmware built: $elf"
    else
        log_error "Build failed: $elf not found"
        log_error "--- Full error output ---"
        grep -E "error:|undefined reference|overflow|ld:|ASSERT|collect2" "$build_log" | head -30 || true
        rm -f "$build_log"
        exit 1
    fi
}

case "${1:-}" in
    clean)  clean_build ;;
    help|-h|--help)
        echo "Usage: $(basename "$0") [Debug|Release|clean|help]"
        echo "  Debug    Build Debug configuration (default)"
        echo "  Release  Build Release configuration"
        echo "  clean    Remove build outputs"
        ;;
    *)      do_build ;;
esac
