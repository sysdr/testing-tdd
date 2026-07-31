package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
)

func main() {
	port := flag.Int("port", 8080, "HTTP listen port")
	flag.Parse()

	store := NewStore()
	mux := http.NewServeMux()
	mux.HandleFunc("/keys/", keysHandler(store))

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("kvstore-server listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func keysHandler(store *Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		key := strings.TrimPrefix(r.URL.Path, "/keys/")
		if key == "" || strings.Contains(key, "/") {
			http.Error(w, "invalid key", http.StatusBadRequest)
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
			store.Put(key, string(body))
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("ok"))
		case http.MethodGet:
			value, ok := store.Get(key)
			if !ok {
				http.NotFound(w, r)
				return
			}
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(value))
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	}
}
