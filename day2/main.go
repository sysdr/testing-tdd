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
