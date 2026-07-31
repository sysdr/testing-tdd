package main

import (
	"sync"
	"testing"
)

func TestStorePutGet(t *testing.T) {
	s := NewStore()
	s.Put("alpha", "hyperscale-payload")

	got, ok := s.Get("alpha")
	if !ok {
		t.Fatal("expected key to exist")
	}
	if got != "hyperscale-payload" {
		t.Fatalf("got %q, want %q", got, "hyperscale-payload")
	}
}

func TestStoreGetMissing(t *testing.T) {
	s := NewStore()
	if _, ok := s.Get("missing"); ok {
		t.Fatal("expected missing key to be absent")
	}
}

func TestStoreOverwrite(t *testing.T) {
	s := NewStore()
	s.Put("k", "v1")
	s.Put("k", "v2")

	got, ok := s.Get("k")
	if !ok || got != "v2" {
		t.Fatalf("got (%q, %v), want (\"v2\", true)", got, ok)
	}
}

func TestStoreConcurrentAccess(t *testing.T) {
	s := NewStore()
	var wg sync.WaitGroup

	for i := 0; i < 50; i++ {
		wg.Add(2)
		go func(n int) {
			defer wg.Done()
			s.Put("shared", "value")
			_ = n
		}(i)
		go func() {
			defer wg.Done()
			_, _ = s.Get("shared")
		}()
	}

	wg.Wait()
}
