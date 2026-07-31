#!/usr/bin/env bash
set -uo pipefail

# Always run from this script's directory
cd "$(dirname "$(readlink -f "$0")")"

PORT=8080
BINARY_NAME="kvstore-server"

echo "================================================================================"
echo "                   DISTRIBUTED SYSTEMS ENGINE - TEARDOWN                        "
echo "================================================================================"

# Find and terminate server process(es) listening on the port
PIDS=$(lsof -t -iTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true)

if [ -n "${PIDS}" ]; then
    echo "Stopping KV-Store server running on PID(s) ${PIDS}..."
    for pid in ${PIDS}; do
        kill -15 "${pid}" 2>/dev/null || true
    done
    # Give processes a moment to exit gracefully
    sleep 0.5
    for pid in ${PIDS}; do
        if kill -0 "${pid}" 2>/dev/null; then
            kill -9 "${pid}" 2>/dev/null || true
        fi
    done
    echo "Service stopped successfully."
else
    echo "No service detected on port ${PORT}."
fi

# Clean up binary
if [ -f "${BINARY_NAME}" ]; then
    echo "Removing compiled binary: ${BINARY_NAME}..."
    rm -f "${BINARY_NAME}"
fi

echo "Cleanup complete."
echo "================================================================================"
