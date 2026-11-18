package main

import (
	"os"
	"path/filepath"
	"runtime"
)

// home is where everything the server owns lives: settings, the Tailscale
// identity, Python, the models. On Windows that is %LOCALAPPDATA%\MynaServer,
// the same folder the Python side uses, so both read one config.json.
func home() string {
	if dir := os.Getenv("MYNA_SERVER_HOME"); dir != "" {
		return dir
	}
	if runtime.GOOS == "windows" {
		if base := os.Getenv("LOCALAPPDATA"); base != "" {
			return filepath.Join(base, "MynaServer")
		}
	}
	user, err := os.UserHomeDir()
	if err != nil {
		return ".myna-server"
	}
	return filepath.Join(user, ".myna-server")
}

func sub(parts ...string) string {
	return filepath.Join(append([]string{home()}, parts...)...)
}
