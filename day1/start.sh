#!/usr/bin/env bash
set -euo pipefail

# Always run from this script's directory
cd "$(dirname "$(readlink -f "$0")")"

# --- CONFIGURATION ---
PORT=8080
BINARY_NAME="kvstore-server"

echo "================================================================================"
echo "              DISTRIBUTED SYSTEMS ENGINE - DAY 1 INITIALIZATION                 "
echo "================================================================================"

# 1. Check prerequisites
echo "Checking system dependencies..."
if ! command -v go &> /dev/null; then
    echo "ERROR: Go compiler is not installed. Please install Go (1.18+) first."
    exit 1
fi
echo "Go compiler found: $(go version)"

# Ensure port is free before we spend time on tests/build
if command -v lsof &> /dev/null; then
    EXISTING_PIDS=$(lsof -t -iTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true)
    if [ -n "${EXISTING_PIDS}" ]; then
        echo "ERROR: Port ${PORT} is already in use (PID(s): ${EXISTING_PIDS})."
        echo "Run ./stop.sh first, then try again."
        exit 1
    fi
fi

# 2. Run Tests with Race Detector
echo "Running test suite with Go Race Detector..."
go test -v -race ./...

# 3. Build Binary
echo "Building high-performance KV-Store server binary..."
go build -o "${BINARY_NAME}" main.go store.go

# 4. Start Server
echo "Starting service on port ${PORT}..."
./"${BINARY_NAME}" -port="${PORT}" &
SERVER_PID=$!

# Ensure server process is tracked or cleaned up on interrupt
trap 'kill -9 $SERVER_PID 2>/dev/null || true' INT TERM EXIT

# 5. Verify Health & Functionality
echo "Waiting for server to initialize..."
sleep 1.5

if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "ERROR: Server failed to start. Check terminal output."
    exit 1
fi

echo "Verifying API endpoints..."
# Test PUT
curl -s -X PUT "http://localhost:${PORT}/keys/test-key" -d "hyperscale-payload"
echo ""

# Test GET
RESPONSE=$(curl -s "http://localhost:${PORT}/keys/test-key")
echo "GET response: ${RESPONSE}"

if [ "${RESPONSE}" != "hyperscale-payload" ]; then
    echo "ERROR: Read value does not match written value!"
    exit 1
fi

echo "================================================================================"
echo "SUCCESS: Day 1 Memory-Backed KV Store is running on PID ${SERVER_PID}"
echo "Use ./stop.sh to terminate the service"
echo "================================================================================"

# Keep script alive to let user interact, or exit cleanly if backgrounded
# To run in foreground, we can wait on the server process
wait $SERVER_PID
