#!/bin/bash
set -euo pipefail

# Script metadata
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VERSION="0.2.0"

# Color definitions
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Directory configuration
readonly ROOT_DIR="$SCRIPT_DIR"
readonly BOARDS_BASE_DIR="$ROOT_DIR/boards/stm32mp157"

# Board configuration (loaded from .config or -b option)
BOARD_NAME=""
BOARD_DIR=""
readonly CONFIG_FILE="$ROOT_DIR/.config"

# Build configuration (overridable via options or env vars)
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
FORCE_REBUILD="${FORCE_REBUILD:-false}"
PARALLEL_BUILD="${PARALLEL_BUILD:-false}"
# OUTPUT_DIR is set in main() after board.conf loading to include board name

# Module definitions
readonly MODULES=(atf uboot kernel busybox)

declare -A MODULE_NAMES=(
    [atf]="ARM Trusted Firmware"
    [uboot]="U-Boot"
    [kernel]="Linux Kernel"
    [busybox]="BusyBox"
)

# Build-script directory names under boards/stm32mp157/common/build_script/
declare -A MODULE_DIRS=(
    [atf]="tfa"
    [uboot]="u-boot"
    [kernel]="linux"
    [busybox]="busybox"
)

# Source trees, populated by scripts/fetch-sources.sh
readonly SRC_DIR="${SRC_DIR:-$ROOT_DIR/sources}"
export SRC_DIR
declare -A SOURCE_DIRS=(
    [atf]="tf-a"
    [uboot]="u-boot"
    [kernel]="linux"
    [busybox]="busybox"
)

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
        BUILD) echo -e "${PURPLE}[BUILD]${NC} $msg" ;;
        DEBUG) [[ "$VERBOSE" == "true" ]] && echo -e "${CYAN}[DEBUG]${NC} $msg" || true ;;
    esac
}

die() {
    log ERROR "$1"
    exit 1
}

# Format elapsed time in human-readable form
format_elapsed() {
    local elapsed=$(( $(date +%s) - $1 ))
    local h=$((elapsed / 3600)) m=$(((elapsed % 3600) / 60)) s=$((elapsed % 60))
    if ((h > 0)); then
        echo "${h}h${m}m${s}s"
    elif ((m > 0)); then
        echo "${m}m${s}s"
    else
        echo "${s}s"
    fi
}

# Get shared build script path for a module
module_script() {
    echo "$BOARDS_BASE_DIR/common/build_script/${MODULE_DIRS[$1]}/build.sh"
}

# List available boards (boards with board.conf)
list_boards() {
    local boards=()
    if [[ -d "$BOARDS_BASE_DIR" ]]; then
        for dir in "$BOARDS_BASE_DIR"/*; do
            if [[ -d "$dir" ]] && [[ -f "$dir/board.conf" ]]; then
                boards+=("$(basename "$dir")")
            fi
        done
    fi
    printf '%s\n' "${boards[@]}"
}

# Set board from -b option (overrides .config)
set_board() {
    local board="$1"
    local dir="$BOARDS_BASE_DIR/$board"

    [[ -d "$dir" ]] || die "Board not found: $board (directory: $dir)"
    [[ -f "$dir/board.conf" ]] || die "Board config not found: $dir/board.conf"

    BOARD_NAME="$board"
}

# Load board from .config file
load_board_config() {
    if [[ -n "$BOARD_NAME" ]]; then
        # Already set via -b option
        BOARD_DIR="$BOARDS_BASE_DIR/$BOARD_NAME"
        return 0
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        # Only one board available: use it without requiring 'config'
        local boards=()
        mapfile -t boards < <(list_boards)
        if [[ ${#boards[@]} -eq 1 ]]; then
            BOARD_NAME="${boards[0]}"
            BOARD_DIR="$BOARDS_BASE_DIR/$BOARD_NAME"
            log INFO "No board configured; using the only available board: $BOARD_NAME"
            return 0
        fi
        die "No board configured. Run '$SCRIPT_NAME config' or pass -b <board> (available: ${boards[*]:-none})."
    fi

    source "$CONFIG_FILE"

    if [[ -z "${BOARD_NAME:-}" ]]; then
        die "Invalid .config: BOARD_NAME not set. Run '$SCRIPT_NAME config' again."
    fi

    BOARD_DIR="$BOARDS_BASE_DIR/$BOARD_NAME"

    if [[ ! -f "$BOARD_DIR/board.conf" ]]; then
        die "Board '$BOARD_NAME' not found. Run '$SCRIPT_NAME config' to reconfigure."
    fi
}

# Interactive board selection and save to .config
do_config() {
    local boards=()
    mapfile -t boards < <(list_boards)

    if [[ ${#boards[@]} -eq 0 ]]; then
        die "No boards found in $BOARDS_BASE_DIR"
    fi

    echo "Available boards:"
    local i=1
    for board in "${boards[@]}"; do
        echo "  $i) $board"
        ((i++))
    done
    echo ""

    local selection
    read -rp "Select board [1-${#boards[@]}]: " selection

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > ${#boards[@]})); then
        die "Invalid selection: $selection"
    fi

    local selected="${boards[$((selection - 1))]}"

    # Validate board
    if [[ ! -f "$BOARDS_BASE_DIR/$selected/board.conf" ]]; then
        die "Board config not found: $BOARDS_BASE_DIR/$selected/board.conf"
    fi

    # Save to .config
    cat > "$CONFIG_FILE" <<EOF
# Auto-generated by $SCRIPT_NAME config
BOARD_NAME="$selected"
EOF

    log OK "Board configured: $selected"
    log INFO "Config saved to: $CONFIG_FILE"
}

# ==============================================================================
# Environment check
# ==============================================================================

check_environment() {
    log INFO "Checking build environment..."

    command -v make &>/dev/null || die "Missing tool: make"
    command -v arm-linux-gnueabi-gcc &>/dev/null || die "Missing tool: arm-linux-gnueabi-gcc"

    for mod in "${MODULES[@]}"; do
        [[ -d "$SRC_DIR/${SOURCE_DIRS[$mod]}" ]] || die "Source not found: $SRC_DIR/${SOURCE_DIRS[$mod]} (run scripts/fetch-sources.sh first)"
    done

    log DEBUG "Parallel jobs: $BUILD_JOBS"
    log DEBUG "Output directory: $OUTPUT_DIR"
    log OK "Environment check passed"
}

# ==============================================================================
# Build functions
# ==============================================================================

# Build a single module by name
build_module() {
    local module="$1"
    local step_info="${2:-}"
    local name="${MODULE_NAMES[$module]}"
    local src_dir="$SRC_DIR/${SOURCE_DIRS[$module]}"
    local script
    script="$(module_script "$module")"
    local start_time
    start_time=$(date +%s)

    log BUILD "${step_info}Building ${name}..."

    [[ -x "$script" ]] || die "Build script not found or not executable: $script"

    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "[DRY RUN] $script"
        return 0
    fi

    cd "$src_dir"

    # Export board name and output directory for sub-scripts
    export BOARD_NAME OUTPUT_DIR

    # ATF needs special handling: build output goes to $OUTPUT_DIR/atf
    if [[ "$module" == "atf" ]]; then
        [[ -d build ]] && rm -rf build
        "$script" || { cd "$ROOT_DIR"; die "${name} build failed (elapsed: $(format_elapsed "$start_time"))"; }
        mkdir -p "$OUTPUT_DIR"
        rm -rf "$OUTPUT_DIR/atf"
        mv build "$OUTPUT_DIR/atf"
    else
        "$script" || { cd "$ROOT_DIR"; die "${name} build failed (elapsed: $(format_elapsed "$start_time"))"; }
    fi

    cd "$ROOT_DIR"
    log OK "${name} build completed (elapsed: $(format_elapsed "$start_time"))"
}

# Build all modules, optionally in parallel
build_all() {
    log INFO "Building all modules..."

    # ATF must be built first (U-Boot depends on it)
    # M4 must be built before BusyBox (M4 ELF is copied into rootfs)
    build_module atf "[1/5] "

    if [[ "$PARALLEL_BUILD" == "true" ]]; then
        local pids=()
        build_module uboot  "[2/5] " & pids+=($!)
        build_module kernel "[3/5] " & pids+=($!)
        build_m4                     & pids+=($!)
        for pid in "${pids[@]}"; do
            wait "$pid" || die "Parallel build failed"
        done
    else
        build_module uboot  "[2/5] "
        build_module kernel "[3/5] "
        build_m4
    fi

    # Generate FIP image (requires ATF + U-Boot both built)
    build_fip

    build_module busybox "[5/6] "
    build_rootfs         "[6/6] "
}

# ==============================================================================
# FIP image generation (requires ATF trusted + U-Boot already built)
# ==============================================================================

build_fip() {
    local atf_script="$ROOT_DIR/boards/stm32mp157/common/build_script/tfa/build.sh"
    log INFO "Generating FIP image..."
    "$atf_script" fip
}

build_rootfs() {
    local step_info="${1:-}"
    local script
    script="$(module_script busybox)"
    local start_time
    start_time=$(date +%s)

    log BUILD "${step_info}Creating rootfs image..."

    [[ -x "$script" ]] || die "Build script not found or not executable: $script"

    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "[DRY RUN] $script rootfs"
        return 0
    fi

    cd "$SRC_DIR/busybox"
    export BOARD_NAME OUTPUT_DIR
    "$script" rootfs || { cd "$ROOT_DIR"; die "rootfs build failed (elapsed: $(format_elapsed "$start_time"))"; }
    cd "$ROOT_DIR"
    log OK "rootfs build completed (elapsed: $(format_elapsed "$start_time"))"
}

# ==============================================================================
# Cortex-M4 firmware build
# ==============================================================================

build_m4() {
    local m4_dir="$ROOT_DIR/firmware/m4"
    local m4_script="$m4_dir/build.sh"
    local build_config="${1:-Debug}"

    [[ -d "$m4_dir" ]] || die "M4 source not found: $m4_dir"
    [[ -x "$m4_script" ]] || die "M4 build script not found: $m4_script"

    # clean is not a build config — delegate and return early
    if [[ "$build_config" == "clean" ]]; then
        local start_time
        start_time=$(date +%s)
        log BUILD "Building Cortex-M4 firmware (clean)..."
        "$m4_script" clean || die "M4 clean failed"
        log OK "M4 clean completed (elapsed: $(format_elapsed "$start_time"))"
        return 0
    fi

    local elf="$m4_dir/CM4/$build_config/stm32_m4_CM4.elf"
    local start_time
    start_time=$(date +%s)

    log BUILD "Building Cortex-M4 firmware ($build_config)..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "[DRY RUN] $m4_script $build_config"
        return 0
    fi

    "$m4_script" "$build_config" || die "M4 build failed (elapsed: $(format_elapsed "$start_time"))"

    [[ -f "$elf" ]] || die "M4 ELF not found: $elf"

    # Copy ELF to board's M4 directory
    local m4_dest="$BOARD_DIR/M4"
    mkdir -p "$m4_dest"
    cp "$elf" "$m4_dest/"
    log OK "M4 firmware copied to: $m4_dest/$(basename "$elf")"
    log OK "M4 build completed (elapsed: $(format_elapsed "$start_time"))"
}

# ==============================================================================
# Flash firmware
# ==============================================================================

flash_firmware() {
    local flash_script="$BOARDS_BASE_DIR/common/flash/flash.sh"

    [[ -x "$flash_script" ]] || die "Flash script not found: $flash_script"

    # Forward all arguments to flash script
    "$flash_script" "$@"
}

# ==============================================================================
# Clean build outputs
# ==============================================================================

clean_build() {
    local targets=("$@")

    # If no targets specified, clean all
    if [[ ${#targets[@]} -eq 0 ]]; then
        targets=("${MODULES[@]}")
        log INFO "Cleaning all modules..."

        # Also remove output directory when cleaning all
        if [[ -d "$OUTPUT_DIR" ]]; then
            rm -rf "$OUTPUT_DIR"
            log OK "Removed: $OUTPUT_DIR"
        fi
    else
        log INFO "Cleaning specified modules: ${targets[*]}"
    fi

    # Clean each target module
    for target in "${targets[@]}"; do
        # Validate module name
        local valid=false
        for mod in "${MODULES[@]}"; do
            if [[ "$mod" == "$target" ]]; then
                valid=true
                break
            fi
        done

        if [[ "$valid" != "true" ]]; then
            log WARN "Unknown module: $target (skipping)"
            continue
        fi

        local dir="$SRC_DIR/${SOURCE_DIRS[$target]}"
        if [[ -d "$dir" ]] && [[ -f "$dir/Makefile" ]]; then
            make -C "$dir" distclean 2>/dev/null || true
            log INFO "Cleaned ${MODULE_NAMES[$target]}"
        fi

        # Also remove module-specific output directory
        local module_output="$OUTPUT_DIR/$target"
        if [[ -d "$module_output" ]]; then
            rm -rf "$module_output"
            log INFO "Removed: $module_output"
        fi
    done

    log OK "Clean completed"
}

# ==============================================================================
# Build summary
# ==============================================================================

show_summary() {
    [[ -d "$OUTPUT_DIR" ]] || return 0

    log INFO "Build summary:"
    for mod in "${MODULES[@]}"; do
        local dir="$OUTPUT_DIR/$mod"
        [[ -d "$dir" ]] && log INFO "  ${MODULE_NAMES[$mod]}: $(du -sh "$dir" | cut -f1)"
    done
    for f in bootfs.ext4 rootfs.ext4; do
        [[ -f "$OUTPUT_DIR/$f" ]] && log INFO "  $f: $(du -h "$OUTPUT_DIR/$f" | cut -f1)"
    done
}

# ==============================================================================
# Help and version
# ==============================================================================

show_version() {
    echo "STM32MP157 SDK v$VERSION"
}

show_help() {
    show_version
    cat <<EOF

Usage: $SCRIPT_NAME [options] <command> [args]

Commands:
    config              Select target board (required before first build)
    all                 Build all modules (TFA + U-Boot + Kernel + BusyBox + rootfs)
    atf|tfa             Build ARM Trusted Firmware
    uboot               Build U-Boot
    kernel              Build Linux Kernel + bootfs
    busybox             Build BusyBox only (compile)
    rootfs              Create rootfs.ext4 image from BusyBox
    flash [args...]     Flash firmware (forwards to flash.sh)
                        Profiles: full, kernel, bootloader, rootfs, buildroot
    m4                  Build Cortex-M4 firmware (STM32CubeIDE)
    clean [modules...]  Clean build outputs
                        No args: clean all modules + output directory
                        With args: clean specific modules only
    help                Show this help

Options:
    -b BOARD            Target board (overrides .config)
    -j N                Parallel jobs (default: $(nproc))
    -v                  Verbose output
    -f                  Force rebuild
    -p                  Parallel module builds
    -n                  Dry run
    -o DIR              Output directory (default: output/<board>)

Available boards:
EOF
    list_boards | sed 's/^/    /'
    cat <<EOF

Examples:
    $SCRIPT_NAME config                 # Select target board (do this first)
    $SCRIPT_NAME all                    # Build all modules
    $SCRIPT_NAME -b 100ask_stm32mp157 all  # Build for specific board
    $SCRIPT_NAME -j8 -v kernel          # Build kernel with 8 jobs, verbose
    $SCRIPT_NAME clean                  # Clean all
    $SCRIPT_NAME flash kernel           # Flash kernel only
EOF
}

# ==============================================================================
# Argument parsing and main entry
# ==============================================================================

main() {
    local command=""
    local args=()

    # Parse all arguments in a single pass
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help|help)     show_help; exit 0 ;;
            --version|version)  show_version; exit 0 ;;
            -b|--board)         set_board "$2"; shift ;;
            -j|--jobs)          BUILD_JOBS="$2"; shift ;;
            -v|--verbose)       VERBOSE=true ;;
            -f|--force)         FORCE_REBUILD=true ;;
            -p|--parallel)      PARALLEL_BUILD=true ;;
            -n|--dry-run)       DRY_RUN=true ;;
            -o|--output)        OUTPUT_DIR="$2"; shift ;;
            config|all|atf|tfa|uboot|kernel|busybox|rootfs|m4|flash|clean)
                if [[ -z "$command" ]]; then
                    command="$1"
                else
                    args+=("$1")
                fi
                ;;
            *)
                if [[ -n "$command" ]]; then
                    args+=("$1")
                else
                    die "Unknown option: $1"
                fi
                ;;
        esac
        shift
    done

    [[ -n "$command" ]] || die "No command specified. Use '$SCRIPT_NAME --help' for usage."

    # Config command does not require an existing .config
    if [[ "$command" == "config" ]]; then
        do_config
        return 0
    fi

    # All other commands require a configured board
    load_board_config
    source "$BOARD_DIR/board.conf"
    OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output/$BOARD_NAME}"
    export OUTPUT_DIR BOARD_NAME

    local start_time
    start_time=$(date +%s)
    log INFO "Board: $BOARD_NAME"
    log INFO "Starting task: $command (jobs=$BUILD_JOBS)"

    case "$command" in
        all)     check_environment; build_all; show_summary ;;
        atf|tfa) check_environment; build_module atf; build_fip ;;
        uboot)   check_environment; build_module uboot ;;
        kernel)  check_environment; build_module kernel ;;
        busybox) check_environment; build_module busybox ;;
        rootfs)  check_environment; build_rootfs ;;
        m4)      build_m4 "${args[0]:-Debug}" ;;
        flash)   flash_firmware "${args[@]}" ;;
        clean)   clean_build "${args[@]}" ;;
    esac

    log OK "Done (elapsed: $(format_elapsed "$start_time"))"
}

trap 'die "Build interrupted"' INT TERM
main "$@"
