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
