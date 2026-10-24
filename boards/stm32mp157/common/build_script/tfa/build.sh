#!/bin/bash
set -euo pipefail

# Resolve paths relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
TFA_DIR="${SRC_DIR:-$ROOT_DIR/sources}/tf-a"

# Build configuration
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

# TF-A build parameters
readonly COMMON_MAKE_ARGS=(
    CROSS_COMPILE=arm-linux-gnueabi-
    DEBUG=1
    LOG_LEVEL=40
    PLAT=stm32mp1
    ARCH=aarch32
    ARM_ARCH_MAJOR=7
    STM32MP_SDMMC=1
    STM32MP_EMMC=1
    STM32MP_SPI_NOR=0
    STM32MP_RAW_NAND=0
    STM32MP_SPI_NAND=0
    TRUSTED_BOARD_BOOT=0
)

readonly SERIAL_MAKE_ARGS=(
    STM32MP_UART_PROGRAMMER=1
    STM32MP_USB_PROGRAMMER=1
    STM32MP_SDMMC=0
    STM32MP_EMMC=0
)

# Build configurations: name:AARCH32_SP
readonly CONFIGS=(
    "trusted:sp_min"
    "optee:optee"
    "serialboot:sp_min"
)

# Device tree to build for (overridable via ATF_DEVICE_TREE env var)
readonly DEVICE_TREE="${ATF_DEVICE_TREE:-onedots_stm32mp157c-512d-v1}"

# Debug wrapper tool
STM32WRAPPER4DBG="$SCRIPT_DIR/stm32wrapper4dbg"

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

# ==============================================================================
# Build functions
# ==============================================================================

# Build host tools (stm32image + fiptool)
build_host_tools() {
    log BUILD "Building host tools..."
    make --no-print-directory -C "$TFA_DIR/tools/stm32image" 2>/dev/null \
        | grep -v "Nothing to be done" || true
    make --no-print-directory -C "$TFA_DIR/tools/fiptool" 2>/dev/null \
        | grep -v "Nothing to be done" || true
    log OK "Host tools ready (stm32image + fiptool)"
}

# Generate FIP image (requires trusted config built + U-Boot available)
build_fip() {
    local fiptool="$TFA_DIR/tools/fiptool/fiptool"
    local trusted_dir="$TFA_DIR/build/trusted"
    local uboot_dir="${SRC_DIR:-$ROOT_DIR/sources}/u-boot"
    local output_dir="${OUTPUT_DIR:-$ROOT_DIR/output}"

    if [[ ! -x "$fiptool" ]]; then
        log BUILD "Building fiptool..."
        make --no-print-directory -C "$TFA_DIR/tools/fiptool"
    fi

    # Check required inputs (build dir or OUTPUT_DIR/atf after top-level moves it)
    if [[ ! -d "$trusted_dir" && -d "${OUTPUT_DIR:-}/atf/trusted" ]]; then
        trusted_dir="${OUTPUT_DIR}/atf/trusted"
    fi
    local bl32="$trusted_dir/bl32.bin"
    local bl32_dtb="$trusted_dir/fdts/${DEVICE_TREE}-bl32.dtb"
    local fw_config="$trusted_dir/fdts/${DEVICE_TREE}-fw-config.dtb"
    local uboot_bin="$uboot_dir/u-boot-nodtb.bin"
    local uboot_dtb="$uboot_dir/u-boot.dtb"

    for f in "$bl32" "$bl32_dtb" "$fw_config"; do
        if [[ ! -f "$f" ]]; then
            log INFO "FIP: missing $f, skipping FIP generation (build ATF trusted first)"
            return 0
        fi
    done

    for f in "$uboot_bin" "$uboot_dtb"; do
        if [[ ! -f "$f" ]]; then
            log INFO "FIP: missing $f, skipping FIP generation (build U-Boot first)"
            return 0
        fi
    done

    log BUILD "Generating FIP image..."
    "$fiptool" create \
        --fw-config "$fw_config" \
        --hw-config "$uboot_dtb" \
        --tos-fw-config "$bl32_dtb" \
        --tos-fw "$bl32" \
        --nt-fw "$uboot_bin" \
        "$output_dir/fip.bin"

    log OK "FIP image created: $output_dir/fip.bin"
    "$fiptool" info "$output_dir/fip.bin" 2>&1 | while read -r line; do
        log INFO "  $line"
    done
}

# Build TF-A for a specific config
build_config() {
    local config="$1"
    local sp="$2"
    local build_dir="$TFA_DIR/build/$config"

    log BUILD "Building TF-A config: $config (AARCH32_SP=$sp)"

    mkdir -p "$build_dir"

    # Build make arguments
    local make_args=("${COMMON_MAKE_ARGS[@]}")
    make_args+=(
        "DTB_FILE_NAME=${DEVICE_TREE}.dtb"
        "BUILD_PLAT=$build_dir"
        "AARCH32_SP=$sp"
    )

    # Add serial boot args if needed
    if [[ "$config" == "serialboot" ]]; then
        make_args+=("${SERIAL_MAKE_ARGS[@]}")
    fi

    # Build
    make -C "$TFA_DIR" "${make_args[@]}" -j"$BUILD_JOBS" \
        || { log ERROR "Build failed for $config"; return 1; }

    # Copy and rename binary
    cp -f "$build_dir/tf-a-${DEVICE_TREE}.stm32" \
          "$build_dir/tf-a-${DEVICE_TREE}-${config}.stm32"

    # Generate debug wrapper
    if [[ -x "$STM32WRAPPER4DBG" ]]; then
        "$STM32WRAPPER4DBG" \
            -s "$build_dir/tf-a-${DEVICE_TREE}.stm32" \
            -d "$build_dir/debug-tf-a-${DEVICE_TREE}-${config}.stm32" 2>/dev/null || true
    fi

    # Copy ELF debug files
    [[ -f "$build_dir/bl2/bl2.elf" ]] && \
        cp -f "$build_dir/bl2/bl2.elf" "$build_dir/tf-a-bl2-${config}.elf"
    [[ -f "$build_dir/bl32/bl32.elf" ]] && \
        cp -f "$build_dir/bl32/bl32.elf" "$build_dir/tf-a-bl32-${config}.elf"

    log OK "Built $config"
}

# Build all configurations
build_all() {
    cd "$TFA_DIR"

    log INFO "Building ARM Trusted Firmware for STM32MP157"
    log INFO "  device tree: $DEVICE_TREE"
    log INFO "  jobs:        $BUILD_JOBS"

    build_host_tools

    local total=${#CONFIGS[@]}
    local idx=1
    for entry in "${CONFIGS[@]}"; do
        IFS=':' read -r config sp <<< "$entry"
        log INFO "[$idx/$total] $config..."
        build_config "$config" "$sp"
        ((idx++))
    done

    log OK "All TF-A configurations built successfully"
}

# Clean all build outputs
clean_all() {
    cd "$TFA_DIR"
    log INFO "Cleaning TF-A build outputs..."
    for entry in "${CONFIGS[@]}"; do
        IFS=':' read -r config _ <<< "$entry"
        rm -rf "build/$config"
    done
    log OK "Clean completed"
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    case "${1:-all}" in
        all)   build_all ;;
        fip)   build_fip ;;
        clean) clean_all ;;
        *)     echo "Usage: $0 [all|fip|clean]"; exit 1 ;;
    esac
}

main "$@"
