package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"healthsync/internal/vitals"
)

func TestAPI(t *testing.T) {
	srv := httptest.NewServer(newMux(vitals.NewStore()))
	defer srv.Close()

	body := `{"patient_id":"P-1","device_id":"W-1","kind":"spo2","value":97,"taken_at":"` +
		time.Now().UTC().Add(-time.Minute).Format(time.RFC3339) + `"}`
	resp, err := http.Post(srv.URL+"/api/v1/vitals", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create: status %d", resp.StatusCode)
	}

	resp, err = http.Post(srv.URL+"/api/v1/vitals", "application/json", strings.NewReader(`{"patient_id":"P-1","device_id":"W-1","kind":"spo2","value":5}`))
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("invalid reading: status %d", resp.StatusCode)
	}

	resp, err = http.Get(srv.URL + "/api/v1/patients/P-1/vitals")
	if err != nil {
		t.Fatal(err)
	}
	var got []vitals.Reading
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil || len(got) != 1 {
		t.Fatalf("list: %v %+v", err, got)
	}
}

func TestVersionEndpoint(t *testing.T) {
	srv := httptest.NewServer(newMux(vitals.NewStore()))
	defer srv.Close()
	resp, err := http.Get(srv.URL + "/version")
	if err != nil {
		t.Fatal(err)
	}
	var b buildInfo
	if err := json.NewDecoder(resp.Body).Decode(&b); err != nil || b.Version == "" || b.Go == "" {
		t.Fatalf("version: %v %+v", err, b)
	}
}
