package main

import (
	"os"
	"sync"
)

var logMu sync.Mutex

// appendLogFile keeps a plain text log next to the settings, capped in size.
func appendLogFile(line string) {
	logMu.Lock()
	defer logMu.Unlock()
	path := sub("launcher.log")
	if info, err := os.Stat(path); err == nil && info.Size() > 2<<20 {
		_ = os.Rename(path, path+".old")
	}
	_ = os.MkdirAll(home(), 0o700)
	if f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
		_, _ = f.WriteString(line + "\n")
		_ = f.Close()
	}
}
