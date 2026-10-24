#!/bin/bash
# Flash Script for STM32MP157
# Usage: ./build.sh flash [profile]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLASH_CONFIG_DIR="$SCRIPT_DIR/flash_config"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $1"; }

# Load board and flash configuration
load_config() {
    # Load board from .config if not already set by build.sh
    if [[ -z "${BOARD_NAME:-}" ]]; then
        local config_file="$PROJECT_ROOT/.config"
        [[ -f "$config_file" ]] \
            || { log_error "No board configured. Run './build.sh config' first."; return 1; }
        source "$config_file"
    fi

    OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/output/$BOARD_NAME}"
    [[ "$OUTPUT_DIR" == /* ]] || OUTPUT_DIR="$PROJECT_ROOT/$OUTPUT_DIR"

    # Load flash-specific settings (programmer path, connection, profiles)
    [[ -f "$FLASH_CONFIG_DIR/flash_config.conf" ]] \
        || { log_error "Config not found: $FLASH_CONFIG_DIR/flash_config.conf"; return 1; }
    source "$FLASH_CONFIG_DIR/flash_config.conf"
}

# Resolve $OUTPUT_DIR and relative paths in TSV to absolute paths
create_resolved_tsv() {
    local src="$1" dst="$2"
    while IFS=$'\t' read -r opt id name type ip offset binary || [[ -n "$opt" ]]; do
        if [[ "$opt" != \#* ]]; then
            binary="${binary//\$OUTPUT_DIR/$OUTPUT_DIR}"
            [[ -z "$binary" || "$binary" == "none" || "$binary" == /* ]] || binary="$PROJECT_ROOT/$binary"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$opt" "$id" "$name" "$type" "$ip" "$offset" "$binary"
    done < "$src" > "$dst"
}

# Look up TSV filename for a profile name
resolve_profile() {
    for entry in "${AVAILABLE_PROFILES[@]}"; do
        IFS=':' read -ra p <<< "$entry"
        [[ "${p[0]}" == "$1" ]] && { echo "${p[2]}"; return 0; }
    done
    return 1
}

# Print available profiles
show_profiles() {
    load_config 2>/dev/null || return 1
    echo "Available profiles:"
    for entry in "${AVAILABLE_PROFILES[@]}"; do
        IFS=':' read -ra p <<< "$entry"
        printf "  %-12s - %s\n" "${p[0]}" "${p[1]}"
    done
}

# Flash device
do_flash() {
    local profile="${1:-full}"
    load_config

    local tsv_file
    tsv_file=$(resolve_profile "$profile") \
        || { log_error "Unknown profile: $profile"; show_profiles; return 1; }

    local tsv_path="$FLASH_CONFIG_DIR/$tsv_file"
    [[ -f "$tsv_path" ]] || { log_error "TSV not found: $tsv_path"; return 1; }

    command -v "$STM32_PROGRAMMER_CLI" >/dev/null 2>&1 \
        || { log_error "STM32CubeProgrammer not found: $STM32_PROGRAMMER_CLI"; return 1; }

    local temp_tsv="$PROJECT_ROOT/.temp_${tsv_file##*/}"
    create_resolved_tsv "$tsv_path" "$temp_tsv"

    log_info "Profile:    $profile"
    log_info "OUTPUT_DIR: $OUTPUT_DIR"

    log_info "Scanning for connected devices..."
    "$STM32_PROGRAMMER_CLI" -l

    log_info "Flashing..."
    local rc=0
    local flash_log="$PROJECT_ROOT/.flash_log"
    "$STM32_PROGRAMMER_CLI" -c "$DEFAULT_CONNECTION" -w "$temp_tsv" 2>&1 | tee "$flash_log" || rc=$?
    rm -f "$temp_tsv"

    # Check both exit code and output for errors
    if [[ $rc -ne 0 ]] || grep -qi "^Error:" "$flash_log"; then
        rm -f "$flash_log"
        log_error "Flash failed!"
        return 1
    fi
    rm -f "$flash_log"
    log_success "Flash completed!"
}

# Clean temp files
do_clean() {
    local n=0
    for f in "$PROJECT_ROOT"/.temp_*.tsv; do
        [[ -f "$f" ]] || continue
        rm -f "$f"; ((n++))
    done
    [[ $n -eq 0 ]] && log_info "Nothing to clean." || log_success "Cleaned $n file(s)."
}

# Help
show_help() {
    cat <<EOF
Flash Script for STM32MP157
Usage: $(basename "$0") [command|profile]

Commands:
  config       Show available flash profiles
  clean        Remove temporary files
  help         Show this help

Profiles:
EOF
    show_profiles 2>/dev/null || echo "  (config not found)"
    cat <<EOF

Examples:
  $(basename "$0")              Flash full system (default)
  $(basename "$0") kernel       Flash kernel only
  $(basename "$0") bootloader   Flash bootloader only
  $(basename "$0") rootfs       Flash rootfs only
  $(basename "$0") buildroot    Flash buildroot system
EOF
}

case "${1:-}" in
    config|status|show)  show_profiles ;;
    clean)               do_clean ;;
    help|-h|--help)      show_help ;;
    "")                  do_flash full ;;
    *)                   do_flash "$1" ;;
esac
