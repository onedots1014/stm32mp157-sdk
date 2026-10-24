#!/bin/bash
set -e
BOARD_DIR="$(dirname $0)"
# Ensure BINARIES_DIR exists
mkdir -p "${BINARIES_DIR}"
# Copy boot files from the external boot directory
cp $BOARD_DIR/../../../boot/* -rfd ${BINARIES_DIR}/

exit $?
