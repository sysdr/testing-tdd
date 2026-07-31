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
