package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"

	"github.com/minio/selfupdate"
)

// The server keeps itself current. A release publishes two files: the new
// MynaServer.exe and a small manifest naming its version and checksum. If the
// manifest's version is later than this one, the exe is downloaded, checked
// against the checksum, swapped in, and started in place of this one.

const manifestURL = "https://github.com/Coral-coder/Myna/releases/download/server-latest/manifest.json"

type manifest struct {
	Version string `json:"version"`
	URL     string `json:"url"`
	SHA256  string `json:"sha256"`
}

func checkForUpdate(ctx context.Context, st *status) {
	if runtime.GOOS != "windows" {
		return
	}
	raw, err := download(ctx, manifestURL, 1<<20)
	if err != nil {
		st.set(func(s *status) { s.Update = "Could not check for updates" })
		return
	}
	var latest manifest
	if err := json.Unmarshal(raw, &latest); err != nil || latest.URL == "" || len(latest.SHA256) != 64 {
		st.set(func(s *status) { s.Update = "Could not read the update information" })
		return
	}
	if !newer(latest.Version, version) {
		st.set(func(s *status) { s.Update = "Up to date" })
		return
	}
	st.set(func(s *status) { s.Update = "Downloading " + latest.Version })
	st.logf("Updating %s → %s.", version, latest.Version)
	data, err := download(ctx, latest.URL, 400<<20)
	if err != nil {
		st.set(func(s *status) { s.Update = "Update download failed: " + err.Error() })
		st.logf("Update download failed: %v", err)
		return
	}
	sum := sha256.Sum256(data)
	if hex.EncodeToString(sum[:]) != latest.SHA256 {
		st.set(func(s *status) { s.Update = "Update rejected: checksum mismatch" })
		st.logf("Update rejected: the download did not match its checksum.")
		return
	}
	// The running exe is moved aside under a name of its own each time. With
	// one fixed name, a copy still in use (an open window keeps running the
	// exe it was started from) blocked every update after the first.
	options := selfupdate.Options{}
	if exe, err := os.Executable(); err == nil {
		options.OldSavePath = fmt.Sprintf("%s.old-%d", exe, time.Now().Unix())
	}
	if err := selfupdate.Apply(bytes.NewReader(data), options); err != nil {
		st.set(func(s *status) { s.Update = "Update could not be installed: " + err.Error() })
		st.logf("Update failed: %v", err)
		return
	}
	st.logf("Update installed; restarting.")
	if err := restart(); err != nil {
		st.logf("Restart failed (%v); the update takes effect next start.", err)
		st.set(func(s *status) { s.Update = fmt.Sprintf("%s installed — restart to use it", latest.Version) })
	}
}

// restart starts the freshly installed exe and ends this one.
func restart() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := exec.Command(exe, "--background", "--after-update")
	hideWindow(cmd)
	if err := cmd.Start(); err != nil {
		return err
	}
	os.Exit(0)
	return nil
}

// cleanOldCopies removes exes left behind by earlier updates. Any still in use
// are skipped and go next time.
func cleanOldCopies() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	olds, _ := filepath.Glob(exe + ".old-*")
	olds = append(olds, filepath.Join(filepath.Dir(exe), "."+filepath.Base(exe)+".old"))
	for _, old := range olds {
		_ = os.Remove(old)
	}
}

// updateNow asks for an update check right away (the Update now button).
var updateNow = make(chan struct{}, 1)

func updateLoop(ctx context.Context, st *status) {
	for {
		checkForUpdate(ctx, st)
		select {
		case <-ctx.Done():
			return
		case <-time.After(10 * time.Minute):
		case <-updateNow:
		}
	}
}
