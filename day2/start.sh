#!/usr/bin/env bash
set -euo pipefail

# Always run from this script's directory
cd "$(dirname "$(readlink -f "$0")")"

# --- CONFIGURATION ---
PORT=8081
BINARY_NAME="waldb_bin"

echo "================================================================================"
echo "       DAY 2: Write-Ahead Log & Disk Emulation — INITIALIZATION                 "
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

# Create project structure if it doesn't exist
if [ ! -f go.mod ]; then
    echo "No existing project found. Generating clean WAL implementation..."

    go mod init waldb

    mkdir -p storage wal db

    # 1. Storage interface + MemDisk / PhysicalDisk
    cat << 'EOF' > storage/storage.go
package storage

import (
	"errors"
	"io"
	"os"
	"sync"
)

var ErrDiskFault = errors.New("simulated disk fault")

type Disk interface {
	Append(data []byte) (offset int64, err error)
	ReadAt(b []byte, off int64) (n int, err error)
	Sync() error
	Size() int64
	Truncate(size int64) error
	Close() error
}

// PhysicalDisk implements Disk using real OS file operations
type PhysicalDisk struct {
	file *os.File
	mu   sync.RWMutex
}

func OpenPhysicalDisk(path string) (*PhysicalDisk, error) {
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_APPEND, 0644)
	if err != nil {
		return nil, err
	}
	return &PhysicalDisk{file: file}, nil
}

func (p *PhysicalDisk) Append(data []byte) (int64, error) {
	p.mu.Lock()
	defer p.mu.Unlock()

	stat, err := p.file.Stat()
	if err != nil {
		return 0, err
	}
	offset := stat.Size()

	_, err = p.file.Write(data)
	if err != nil {
		return 0, err
	}
	return offset, nil
}

func (p *PhysicalDisk) ReadAt(b []byte, off int64) (int, error) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.file.ReadAt(b, off)
}

func (p *PhysicalDisk) Sync() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.file.Sync()
}

func (p *PhysicalDisk) Size() int64 {
	p.mu.RLock()
	defer p.mu.RUnlock()
	stat, err := p.file.Stat()
	if err != nil {
		return 0
	}
	return stat.Size()
}

func (p *PhysicalDisk) Truncate(size int64) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.file.Truncate(size)
}

func (p *PhysicalDisk) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.file.Close()
}

// MemDisk simulates disk storage with configurable fault injection
type MemDisk struct {
	mu          sync.RWMutex
	data        []byte
	faultActive bool
}

func NewMemDisk() *MemDisk {
	return &MemDisk{
		data: make([]byte, 0),
	}
}

func (m *MemDisk) SetFault(active bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.faultActive = active
}

func (m *MemDisk) Append(data []byte) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.faultActive {
		return 0, ErrDiskFault
	}
	offset := int64(len(m.data))
	m.data = append(m.data, data...)
	return offset, nil
}

func (m *MemDisk) ReadAt(b []byte, off int64) (int, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if off >= int64(len(m.data)) {
		return 0, io.EOF
	}
	end := off + int64(len(b))
	if end > int64(len(m.data)) {
		end = int64(len(m.data))
	}
	n := copy(b, m.data[off:end])
	if n < len(b) {
		return n, io.EOF
	}
	return n, nil
}

func (m *MemDisk) Sync() error {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.faultActive {
		return ErrDiskFault
	}
	return nil
}

func (m *MemDisk) Size() int64 {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return int64(len(m.data))
}

func (m *MemDisk) Truncate(size int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if size > int64(len(m.data)) {
		return errors.New("truncate size exceeds disk size")
	}
	m.data = m.data[:size]
	return nil
}

func (m *MemDisk) Close() error {
	return nil
}

// CorruptByte manually flips a bit in the simulated disk for corruption testing
func (m *MemDisk) CorruptByte(offset int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if offset < int64(len(m.data)) {
		m.data[offset] ^= 0xFF
	}
}
EOF

    # 2. WAL engine
    cat << 'EOF' > wal/wal.go
package wal

import (
	"encoding/binary"
	"errors"
	"hash/crc32"
	"waldb/storage"
)

var ErrCorruptFrame = errors.New("wal record corruption detected via checksum")

const (
	OpSet    byte = 1
	OpDelete byte = 2
)

type WAL struct {
	disk storage.Disk
}

func NewWAL(disk storage.Disk) *WAL {
	return &WAL{disk: disk}
}

// EncodeFrame serializes a record: Length (4B) + Op (1B) + KeyLen (4B) + Key + ValLen (4B) + Val + CRC (4B)
func EncodeFrame(op byte, key, value []byte) []byte {
	kl := len(key)
	vl := len(value)
	payloadSize := 1 + 4 + kl + 4 + vl
	totalSize := 4 + payloadSize + 4 // Length prefix + payload + CRC32

	buf := make([]byte, totalSize)
	binary.BigEndian.PutUint32(buf[0:4], uint32(totalSize))
	buf[4] = op
	binary.BigEndian.PutUint32(buf[5:9], uint32(kl))
	copy(buf[9:9+kl], key)
	binary.BigEndian.PutUint32(buf[9+kl:13+kl], uint32(vl))
	copy(buf[13+kl:], value)

	checksum := crc32.ChecksumIEEE(buf[4 : totalSize-4])
	binary.BigEndian.PutUint32(buf[totalSize-4:], checksum)

	return buf
}

// AppendWrite writes an operation frame to the WAL and synchronizes disk blocks
func (w *WAL) AppendWrite(op byte, key, value []byte) error {
	frame := EncodeFrame(op, key, value)
	_, err := w.disk.Append(frame)
	if err != nil {
		return err
	}
	return w.disk.Sync()
}
EOF

    # 3. Core DB engine
    cat << 'EOF' > db/db.go
package db

import (
	"encoding/binary"
	"errors"
	"hash/crc32"
	"io"
	"sync"
	"waldb/storage"
	"waldb/wal"
)

type DB struct {
	mu       sync.RWMutex
	memTable map[string]string
	wal      *wal.WAL
	disk     storage.Disk
}

func Open(disk storage.Disk) (*DB, error) {
	database := &DB{
		memTable: make(map[string]string),
		wal:      wal.NewWAL(disk),
		disk:     disk,
	}

	if err := database.recover(); err != nil {
		return nil, err
	}

	return database, nil
}

func (d *DB) Get(key string) (string, bool) {
	d.mu.RLock()
	defer d.mu.RUnlock()
	val, ok := d.memTable[key]
	return val, ok
}

func (d *DB) Set(key, value string) error {
	d.mu.Lock()
	defer d.mu.Unlock()

	err := d.wal.AppendWrite(wal.OpSet, []byte(key), []byte(value))
	if err != nil {
		return err
	}

	d.memTable[key] = value
	return nil
}

func (d *DB) Delete(key string) error {
	d.mu.Lock()
	defer d.mu.Unlock()

	err := d.wal.AppendWrite(wal.OpDelete, []byte(key), nil)
	if err != nil {
		return err
	}

	delete(d.memTable, key)
	return nil
}

// recover parses the WAL sequentially and reconstructs the memory state
func (d *DB) recover() error {
	var offset int64 = 0
	size := d.disk.Size()

	for offset < size {
		lenBuf := make([]byte, 4)
		_, err := d.disk.ReadAt(lenBuf, offset)
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return err
		}

		length := binary.BigEndian.Uint32(lenBuf)
		if length == 0 || offset+int64(length) > size {
			return d.disk.Truncate(offset)
		}

		frameBuf := make([]byte, length)
		_, err = d.disk.ReadAt(frameBuf, offset)
		if err != nil {
			return d.disk.Truncate(offset)
		}

		payload := frameBuf[4 : length-4]
		storedCRC := binary.BigEndian.Uint32(frameBuf[length-4:])
		calculatedCRC := crc32.ChecksumIEEE(payload)

		if storedCRC != calculatedCRC {
			return wal.ErrCorruptFrame
		}

		op := frameBuf[4]
		kl := binary.BigEndian.Uint32(frameBuf[5:9])
		key := string(frameBuf[9 : 9+kl])

		if op == wal.OpSet {
			vl := binary.BigEndian.Uint32(frameBuf[9+kl : 13+kl])
			val := string(frameBuf[13+kl : 13+kl+vl])
			d.memTable[key] = val
		} else if op == wal.OpDelete {
			delete(d.memTable, key)
		}

		offset += int64(length)
	}

	return nil
}
EOF

    # 4. Unit / resiliency tests
    cat << 'EOF' > db/db_test.go
package db

import (
	"errors"
	"fmt"
	"sync"
	"testing"
	"waldb/storage"
	"waldb/wal"
)

func TestDurableLifecycle(t *testing.T) {
	disk := storage.NewMemDisk()

	db1, err := Open(disk)
	if err != nil {
		t.Fatalf("failed to open database: %v", err)
	}

	if err := db1.Set("cloud_provider", "aws"); err != nil {
		t.Fatalf("failed to set key: %v", err)
	}
	if err := db1.Set("region", "us-east-1"); err != nil {
		t.Fatalf("failed to set key: %v", err)
	}

	db1 = nil

	db2, err := Open(disk)
	if err != nil {
		t.Fatalf("failed to recover database: %v", err)
	}

	if val, ok := db2.Get("cloud_provider"); !ok || val != "aws" {
		t.Errorf("expected cloud_provider to be 'aws', got '%s'", val)
	}
	if val, ok := db2.Get("region"); !ok || val != "us-east-1" {
		t.Errorf("expected region to be 'us-east-1', got '%s'", val)
	}
}

func TestDiskWriteFailureDefendsMemTable(t *testing.T) {
	disk := storage.NewMemDisk()
	database, err := Open(disk)
	if err != nil {
		t.Fatalf("failed to open database: %v", err)
	}

	if err := database.Set("status", "healthy"); err != nil {
		t.Fatalf("failed to set status: %v", err)
	}

	disk.SetFault(true)

	err = database.Set("status", "degraded")
	if !errors.Is(err, storage.ErrDiskFault) {
		t.Fatalf("expected DiskFault, got: %v", err)
	}

	val, _ := database.Get("status")
	if val != "healthy" {
		t.Errorf("MemTable state changed despite write failure! Expected 'healthy', got '%s'", val)
	}
}

func TestRecoveryHaltsOnCorruptedChecksum(t *testing.T) {
	disk := storage.NewMemDisk()
	database, err := Open(disk)
	if err != nil {
		t.Fatalf("failed to open database: %v", err)
	}

	if err := database.Set("secure_token", "super-secret"); err != nil {
		t.Fatalf("failed to set key: %v", err)
	}

	disk.CorruptByte(12)

	_, err = Open(disk)
	if !errors.Is(err, wal.ErrCorruptFrame) {
		t.Fatalf("expected ErrCorruptFrame, got: %v", err)
	}
}

func TestConcurrentSets(t *testing.T) {
	disk := storage.NewMemDisk()
	database, err := Open(disk)
	if err != nil {
		t.Fatalf("failed to open database: %v", err)
	}

	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			key := fmt.Sprintf("k-%d", n)
			if err := database.Set(key, "v"); err != nil {
				t.Errorf("set failed: %v", err)
			}
			if _, ok := database.Get(key); !ok {
				t.Errorf("missing key after set: %s", key)
			}
		}(i)
	}
	wg.Wait()
}
EOF

    # 5. HTTP durability console (API for live checks)
    cat << 'EOF' > main.go
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"waldb/db"
	"waldb/storage"
)

type engine struct {
	mu   sync.Mutex
	disk *storage.MemDisk
	db   *db.DB
}

func main() {
	port := flag.Int("port", 8081, "HTTP listen port")
	flag.Parse()

	disk := storage.NewMemDisk()
	activeDB, err := db.Open(disk)
	if err != nil {
		log.Fatalf("initialization failed: %v", err)
	}

	eng := &engine{disk: disk, db: activeDB}
	mux := http.NewServeMux()
	mux.HandleFunc("/keys/", eng.keysHandler)
	mux.HandleFunc("/admin/crash", eng.crashHandler)
	mux.HandleFunc("/admin/recover", eng.recoverHandler)
	mux.HandleFunc("/stats", eng.statsHandler)

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("waldb-server listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func (e *engine) keysHandler(w http.ResponseWriter, r *http.Request) {
	key := strings.TrimPrefix(r.URL.Path, "/keys/")
	if key == "" || strings.Contains(key, "/") {
		http.Error(w, "invalid key", http.StatusBadRequest)
		return
	}

	e.mu.Lock()
	active := e.db
	e.mu.Unlock()
	if active == nil {
		http.Error(w, "database crashed; call /admin/recover", http.StatusServiceUnavailable)
		return
	}

	switch r.Method {
	case http.MethodPut, http.MethodPost:
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "failed to read body", http.StatusBadRequest)
			return
		}
		defer r.Body.Close()
		if err := active.Set(key, string(body)); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	case http.MethodGet:
		value, ok := active.Get(key)
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(value))
	case http.MethodDelete:
		if err := active.Delete(key); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (e *engine) crashHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	e.mu.Lock()
	e.db = nil
	e.mu.Unlock()
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("crashed"))
}

func (e *engine) recoverHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.db != nil {
		http.Error(w, "database still running; crash first", http.StatusConflict)
		return
	}
	recovered, err := db.Open(e.disk)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	e.db = recovered
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("recovered"))
}

func (e *engine) statsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	e.mu.Lock()
	alive := e.db != nil
	diskBytes := e.disk.Size()
	e.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"alive":      alive,
		"disk_bytes": diskBytes,
	})
}
EOF
fi

# 2. Run tests with race detector
echo "Running resiliency test suite with Go Race Detector..."
go test -v -race ./...

# 3. Build binary
echo "Building WAL engine server binary..."
go build -o "${BINARY_NAME}" .

# 4. Start server
echo "Starting service on port ${PORT}..."
./"${BINARY_NAME}" -port="${PORT}" &
SERVER_PID=$!

trap 'kill -9 $SERVER_PID 2>/dev/null || true' INT TERM EXIT

# 5. Verify health & durability demo
echo "Waiting for server to initialize..."
sleep 1.5

if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "ERROR: Server failed to start. Check terminal output."
    exit 1
fi

echo "Verifying API endpoints (write → read → crash → recover)..."

# Write a durable value
PUT_RESP=$(curl -s -X PUT "http://localhost:${PORT}/keys/cloud_provider" -d "aws-durable")
echo "PUT response: ${PUT_RESP}"
if [ "${PUT_RESP}" != "ok" ]; then
    echo "ERROR: PUT failed (got '${PUT_RESP}')"
    exit 1
fi

# Read it back
RESPONSE=$(curl -s "http://localhost:${PORT}/keys/cloud_provider")
echo "GET response: ${RESPONSE}"
if [ "${RESPONSE}" != "aws-durable" ]; then
    echo "ERROR: Read value does not match written value!"
    exit 1
fi

# Stats must show non-zero WAL bytes
STATS=$(curl -s "http://localhost:${PORT}/stats")
echo "STATS response: ${STATS}"
DISK_BYTES=$(echo "${STATS}" | sed -n 's/.*"disk_bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
if [ -z "${DISK_BYTES}" ] || [ "${DISK_BYTES}" -le 0 ]; then
    echo "ERROR: Expected positive disk_bytes after write, got '${DISK_BYTES}'"
    exit 1
fi

# Simulate crash (volatile mem wiped; WAL on MemDisk remains)
CRASH_RESP=$(curl -s -X POST "http://localhost:${PORT}/admin/crash")
echo "CRASH response: ${CRASH_RESP}"
if [ "${CRASH_RESP}" != "crashed" ]; then
    echo "ERROR: Crash simulation failed"
    exit 1
fi

# Reads should fail while crashed
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT}/keys/cloud_provider")
if [ "${HTTP_CODE}" != "503" ]; then
    echo "ERROR: Expected 503 while crashed, got ${HTTP_CODE}"
    exit 1
fi

# Recover from WAL
RECOVER_RESP=$(curl -s -X POST "http://localhost:${PORT}/admin/recover")
echo "RECOVER response: ${RECOVER_RESP}"
if [ "${RECOVER_RESP}" != "recovered" ]; then
    echo "ERROR: Recovery failed (got '${RECOVER_RESP}')"
    exit 1
fi

# Value must survive crash via WAL replay
RECOVERED=$(curl -s "http://localhost:${PORT}/keys/cloud_provider")
echo "GET after recover: ${RECOVERED}"
if [ "${RECOVERED}" != "aws-durable" ]; then
    echo "ERROR: Recovered value stale/empty — expected 'aws-durable', got '${RECOVERED}'"
    exit 1
fi

echo "================================================================================"
echo "SUCCESS: Day 2 WAL Engine is running on PID ${SERVER_PID} (port ${PORT})"
echo "Use ./stop.sh to terminate the service"
echo "================================================================================"

wait $SERVER_PID
