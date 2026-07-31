#!/usr/bin/env bash
set -uo pipefail

# Always run from this script's directory
cd "$(dirname "$(readlink -f "$0")")"

PORT=8081
BINARY_NAME="waldb_bin"

echo "================================================================================"
echo "                   DAY 2 WAL ENGINE - TEARDOWN                                  "
echo "================================================================================"

# Find and terminate server process(es) listening on the port
PIDS=$(lsof -t -iTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true)

if [ -n "${PIDS}" ]; then
    echo "Stopping WAL engine server running on PID(s) ${PIDS}..."
    for pid in ${PIDS}; do
        kill -15 "${pid}" 2>/dev/null || true
    done
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

# Clean up binary and generated runtime artifacts
if [ -f "${BINARY_NAME}" ]; then
    echo "Removing compiled binary: ${BINARY_NAME}..."
    rm -f "${BINARY_NAME}"
fi

echo "Cleanup complete."
echo "================================================================================"
