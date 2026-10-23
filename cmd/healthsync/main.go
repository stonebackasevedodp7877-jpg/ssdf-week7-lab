// Command healthsync receives vital-sign readings from patient wearables and
// serves them to the clinic dashboard.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime"
	"time"

	"healthsync/internal/vitals"
)

// Release metadata, injected at link time with -ldflags "-X main.name=value".
// The reproducible Makefile derives buildDate from SOURCE_DATE_EPOCH (the
// commit time); the starter Makefile used the build host's wall clock.
var (
	version   = "dev"
	commit    = "unknown"
	buildDate = "unknown"
)

type buildInfo struct {
	Version   string `json:"version"`
	Commit    string `json:"commit"`
	BuildDate string `json:"build_date"`
	Go        string `json:"go"`
}

func info() buildInfo {
	return buildInfo{Version: version, Commit: commit, BuildDate: buildDate, Go: runtime.Version()}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func newMux(store *vitals.Store) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /version", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, info())
	})
	mux.HandleFunc("POST /api/v1/vitals", func(w http.ResponseWriter, r *http.Request) {
		var in vitals.Reading
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&in); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed JSON"})
			return
		}
		saved, err := store.Add(in, time.Now())
		if err != nil {
			writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusCreated, saved)
	})
	mux.HandleFunc("GET /api/v1/patients/{id}/vitals", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, store.ForPatient(r.PathValue("id")))
	})
	return mux
}

func main() {
	addr := flag.String("addr", "127.0.0.1:8080", "listen address")
	showVersion := flag.Bool("version", false, "print build information and exit")
	flag.Parse()

	if *showVersion {
		b, _ := json.Marshal(info())
		fmt.Println(string(b))
		os.Exit(0)
	}

	srv := &http.Server{
		Addr:              *addr,
		Handler:           newMux(vitals.NewStore()),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("healthsync %s (%s) listening on %s", version, commit, *addr)
	log.Fatal(srv.ListenAndServe())
}
