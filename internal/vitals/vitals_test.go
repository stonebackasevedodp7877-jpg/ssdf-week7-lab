package vitals

import (
	"errors"
	"testing"
	"time"
)

var now = time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)

func good() Reading {
	return Reading{PatientID: "P-1001", DeviceID: "W-77", Kind: HeartRate, Value: 72, TakenAt: now.Add(-time.Minute)}
}

func TestValidate(t *testing.T) {
	cases := []struct {
		name string
		mod  func(*Reading)
		want error
	}{
		{"ok", func(*Reading) {}, nil},
		{"no patient", func(r *Reading) { r.PatientID = " " }, ErrPatient},
		{"no device", func(r *Reading) { r.DeviceID = "" }, ErrDevice},
		{"bad kind", func(r *Reading) { r.Kind = "glucose" }, ErrKind},
		{"too high", func(r *Reading) { r.Value = 400 }, ErrRange},
		{"spo2 low", func(r *Reading) { r.Kind, r.Value = SpO2, 20 }, ErrRange},
		{"future", func(r *Reading) { r.TakenAt = now.Add(time.Hour) }, ErrFuture},
	}
	for _, c := range cases {
		r := good()
		c.mod(&r)
		if err := r.Validate(now); !errors.Is(err, c.want) {
			t.Errorf("%s: got %v, want %v", c.name, err, c.want)
		}
	}
}

func TestStoreOrderAndIDs(t *testing.T) {
	s := NewStore()
	late, early := good(), good()
	early.TakenAt = now.Add(-time.Hour)
	a, err := s.Add(late, now)
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.Add(early, now)
	if err != nil {
		t.Fatal(err)
	}
	if a.ID == "" || a.ID == b.ID {
		t.Fatalf("expected distinct non-empty IDs, got %q and %q", a.ID, b.ID)
	}
	got := s.ForPatient("P-1001")
	if len(got) != 2 || !got[0].TakenAt.Equal(early.TakenAt) {
		t.Fatalf("readings not sorted oldest first: %+v", got)
	}
	if _, err := s.Add(Reading{}, now); err == nil {
		t.Fatal("invalid reading was stored")
	}
}
