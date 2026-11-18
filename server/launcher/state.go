package main

import (
	"fmt"
	"sync"
	"time"
)

// status is what the local status page shows. Everything that happens in the
// background reports here in plain words.
type status struct {
	mu sync.Mutex

	Version     string
	Setup       string // what the worker bootstrap is doing, or "Ready"
	WorkerUp    bool
	Tailnet     string // "Starting", "Sign in needed", "Connected", or an error
	LoginURL    string
	TailnetIP   string
	TailnetName string
	Update      string
	AllowLAN    bool
	LANAddress  string
	log         []string
}

func (s *status) set(fn func(*status)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	fn(s)
}

func (s *status) logf(format string, args ...any) {
	line := time.Now().Format("15:04:05") + "  " + fmt.Sprintf(format, args...)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.log = append(s.log, line)
	if len(s.log) > 200 {
		s.log = s.log[len(s.log)-200:]
	}
	appendLogFile(line)
}

// view is a copy of the status for rendering.
type view struct {
	Version, Setup, Tailnet, LoginURL, TailnetIP, TailnetName, Update, LANAddress string
	WorkerUp, AllowLAN                                                            bool
}

// snapshot copies the fields for rendering, so the page is built without
// holding the lock.
func (s *status) snapshot() (view, []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	copyOf := view{
		Version: s.Version, Setup: s.Setup, WorkerUp: s.WorkerUp, Tailnet: s.Tailnet,
		LoginURL: s.LoginURL, TailnetIP: s.TailnetIP, TailnetName: s.TailnetName,
		Update: s.Update, AllowLAN: s.AllowLAN, LANAddress: s.LANAddress,
	}
	lines := append([]string(nil), s.log...)
	return copyOf, lines
}
