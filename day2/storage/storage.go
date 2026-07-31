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
