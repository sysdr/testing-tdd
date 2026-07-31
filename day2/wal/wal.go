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
