// Package vitals holds the HealthSync domain model: vital-sign readings
// uploaded by a patient's wearable and synced to the clinic.
package vitals

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

// Kind is the type of vital sign in a reading.
type Kind string

const (
	HeartRate   Kind = "heart_rate"   // beats per minute
	SpO2        Kind = "spo2"         // percent oxygen saturation
	Systolic    Kind = "bp_systolic"  // mmHg
	Diastolic   Kind = "bp_diastolic" // mmHg
	Temperature Kind = "temp_c"       // degrees Celsius
)

// plausible ranges reject sensor glitches and malformed uploads.
var ranges = map[Kind][2]float64{
	HeartRate:   {20, 250},
	SpO2:        {50, 100},
	Systolic:    {50, 260},
	Diastolic:   {30, 160},
	Temperature: {30, 45},
}

// Reading is one measurement from a device.
type Reading struct {
	ID        string    `json:"id"`
	PatientID string    `json:"patient_id"`
	DeviceID  string    `json:"device_id"`
	Kind      Kind      `json:"kind"`
	Value     float64   `json:"value"`
	TakenAt   time.Time `json:"taken_at"`
}

// Validation errors.
var (
	ErrPatient = errors.New("patient_id is required")
	ErrDevice  = errors.New("device_id is required")
	ErrKind    = errors.New("unknown vital kind")
	ErrRange   = errors.New("value outside plausible range")
	ErrFuture  = errors.New("taken_at is in the future")
)

// Validate checks a reading against the clinic's intake rules. now is passed
// in so the check is testable and does not depend on the wall clock.
func (r Reading) Validate(now time.Time) error {
	if strings.TrimSpace(r.PatientID) == "" {
		return ErrPatient
	}
	if strings.TrimSpace(r.DeviceID) == "" {
		return ErrDevice
	}
	lim, ok := ranges[r.Kind]
	if !ok {
		return fmt.Errorf("%w: %q", ErrKind, r.Kind)
	}
	if r.Value < lim[0] || r.Value > lim[1] {
		return fmt.Errorf("%w: %s=%g (allowed %g-%g)", ErrRange, r.Kind, r.Value, lim[0], lim[1])
	}
	if r.TakenAt.After(now.Add(5 * time.Minute)) {
		return ErrFuture
	}
	return nil
}

// Store is an in-memory, concurrency-safe reading store.
type Store struct {
	mu   sync.RWMutex
	byPt map[string][]Reading
}

// NewStore returns an empty store.
func NewStore() *Store { return &Store{byPt: make(map[string][]Reading)} }

// Add validates a reading, assigns it an ID and stores it.
func (s *Store) Add(r Reading, now time.Time) (Reading, error) {
	if err := r.Validate(now); err != nil {
		return Reading{}, err
	}
	r.ID = uuid.NewString()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.byPt[r.PatientID] = append(s.byPt[r.PatientID], r)
	return r, nil
}

// ForPatient returns a patient's readings, oldest first.
func (s *Store) ForPatient(patientID string) []Reading {
	s.mu.RLock()
	out := append([]Reading(nil), s.byPt[patientID]...)
	s.mu.RUnlock()
	sort.SliceStable(out, func(i, j int) bool { return out[i].TakenAt.Before(out[j].TakenAt) })
	return out
}
