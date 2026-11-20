package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
)

// readToken returns the pairing token from config.json, creating the file with
// a fresh token if there isn't one. The Python worker reads the same file and
// keeps whatever token it finds, so the two always agree.
func readToken() (string, error) {
	path := sub("config.json")
	settings := map[string]any{}
	if raw, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(raw, &settings)
	}
	if token, ok := settings["token"].(string); ok && len(token) >= 16 {
		return token, nil
	}
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	token := base64.RawURLEncoding.EncodeToString(buf)
	settings["token"] = token
	raw, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	return token, os.WriteFile(path, raw, 0o600)
}

// launcherSettings are the launcher's own switches, kept apart from the
// worker's config so neither overwrites the other.
type launcherSettings struct {
	AllowLAN bool `json:"allow_lan"`
	// The window's password, kept only as a bcrypt hash. Delete this entry
	// from launcher.json to choose a new password.
	PasswordHash string `json:"password_hash,omitempty"`
}

func loadSettings() launcherSettings {
	// The home network is on unless it has been switched off: it lets the
	// phone pair and work at home before, or without, the private network.
	s := launcherSettings{AllowLAN: true}
	if raw, err := os.ReadFile(sub("launcher.json")); err == nil {
		_ = json.Unmarshal(raw, &s)
	}
	return s
}

func (s launcherSettings) save() {
	if raw, err := json.MarshalIndent(s, "", "  "); err == nil {
		_ = os.MkdirAll(home(), 0o700)
		_ = os.WriteFile(sub("launcher.json"), raw, 0o600)
	}
}
