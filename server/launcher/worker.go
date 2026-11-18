package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"
)

// The Python worker does the transcription and writing. Nobody has to install
// Python: the launcher fetches Astral's `uv`, which fetches Python and every
// package into the server's own folder.

const (
	uvVersion = "0.13.9"
	// sha256 of uv-x86_64-pc-windows-msvc.zip for uvVersion.
	uvWindowsSHA256 = "edd61f7f5728a56cc62455386661860bdfc7bab65872f39b0c25bdcc1d8e1beb"
	workerPort      = "8787"
	pythonVersion   = "3.12"
)

func uvPath() string {
	if runtime.GOOS == "windows" {
		return sub("uv", "uv.exe")
	}
	if path, err := exec.LookPath("uv"); err == nil {
		return path
	}
	return sub("uv", "uv")
}

// ensureUV downloads the pinned uv build on Windows and checks it against the
// known hash before unpacking. Elsewhere it expects uv to be installed.
func ensureUV(ctx context.Context) error {
	if _, err := os.Stat(uvPath()); err == nil {
		return nil
	}
	if runtime.GOOS != "windows" {
		return fmt.Errorf("uv is not installed (https://docs.astral.sh/uv/)")
	}
	url := "https://github.com/astral-sh/uv/releases/download/" + uvVersion + "/uv-x86_64-pc-windows-msvc.zip"
	data, err := download(ctx, url, 200<<20)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	if hex.EncodeToString(sum[:]) != uvWindowsSHA256 {
		return fmt.Errorf("the uv download did not match its expected checksum; not installing it")
	}
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return err
	}
	if err := os.MkdirAll(sub("uv"), 0o755); err != nil {
		return err
	}
	for _, file := range reader.File {
		if filepath.Base(file.Name) != "uv.exe" {
			continue
		}
		source, err := file.Open()
		if err != nil {
			return err
		}
		defer source.Close()
		out, err := os.Create(uvPath())
		if err != nil {
			return err
		}
		if _, err := io.Copy(out, source); err != nil {
			out.Close()
			return err
		}
		return out.Close()
	}
	return fmt.Errorf("uv.exe was not in the download")
}

func download(ctx context.Context, url string, limit int64) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	reply, err := http.DefaultClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer reply.Body.Close()
	if reply.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s answered %s", url, reply.Status)
	}
	data, err := io.ReadAll(io.LimitReader(reply.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%s is larger than expected", url)
	}
	return data, nil
}

// uvEnv keeps uv's Python, cache and environment inside the server's folder,
// and stops it touching the machine's own Python or registry.
func uvEnv() []string {
	return append(os.Environ(),
		"UV_PYTHON_INSTALL_DIR="+sub("python"),
		"UV_CACHE_DIR="+sub("cache"),
		"UV_PROJECT_ENVIRONMENT="+sub("venv"),
		"UV_MANAGED_PYTHON=1",
		"UV_PYTHON_INSTALL_BIN=0",
		"UV_PYTHON_INSTALL_REGISTRY=0",
		"UV_NO_CONFIG=1",
		"UV_NO_PROGRESS=1",
		"MYNA_SERVER_HOME="+home(),
	)
}

func venvPython() string {
	if runtime.GOOS == "windows" {
		return sub("venv", "Scripts", "python.exe")
	}
	return sub("venv", "bin", "python")
}

// run executes a command, sending its output to the launcher log.
func run(ctx context.Context, st *status, dir string, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	cmd.Env = uvEnv()
	hideWindow(cmd)
	output, err := cmd.CombinedOutput()
	if len(output) > 0 {
		tail := output
		if len(tail) > 4000 {
			tail = tail[len(tail)-4000:]
		}
		st.logf("%s", string(tail))
	}
	return err
}

// prepareWorker gets everything in place: the server files, uv, Python, and the
// packages (including the GPU ones). The first run downloads several GB.
func prepareWorker(ctx context.Context, st *status) (string, error) {
	st.set(func(s *status) { s.Setup = "Unpacking the server files" })
	payload, err := extractPayload()
	if err != nil {
		return "", err
	}
	removeOldPayloads()

	st.set(func(s *status) { s.Setup = "Getting the package installer" })
	if err := ensureUV(ctx); err != nil {
		return "", err
	}

	st.set(func(s *status) { s.Setup = "Installing Python" })
	if err := run(ctx, st, payload, uvPath(), "python", "install", pythonVersion); err != nil {
		return "", fmt.Errorf("installing Python failed: %w", err)
	}

	st.set(func(s *status) { s.Setup = "Installing the speech and language packages (several GB the first time)" })
	if err := run(ctx, st, payload, uvPath(), "sync", "--frozen", "--extra", "gpu", "--python", pythonVersion); err != nil {
		return "", fmt.Errorf("installing packages failed: %w", err)
	}
	return payload, nil
}

// superviseWorker runs the Python server and restarts it if it stops, waiting
// longer after each quick failure.
func superviseWorker(ctx context.Context, st *status, payload string) {
	backoff := time.Second
	for ctx.Err() == nil {
		started := time.Now()
		cmd := exec.CommandContext(ctx, venvPython(), "-m", "myna_server", "--host", "127.0.0.1", "--port", workerPort)
		cmd.Dir = payload
		cmd.Env = uvEnv()
		hideWindow(cmd)
		logFile, _ := os.OpenFile(sub("worker.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if logFile != nil {
			cmd.Stdout = logFile
			cmd.Stderr = logFile
		}
		if err := cmd.Start(); err != nil {
			st.logf("Could not start the worker: %v", err)
		} else {
			bindToLauncher(cmd)
			st.set(func(s *status) { s.WorkerUp = true; s.Setup = "Ready" })
			st.logf("Worker started.")
			err = cmd.Wait()
			st.set(func(s *status) { s.WorkerUp = false })
			if ctx.Err() == nil {
				st.logf("Worker stopped (%v); restarting.", err)
			}
		}
		if logFile != nil {
			logFile.Close()
		}
		if time.Since(started) > time.Minute {
			backoff = time.Second
		} else if backoff < time.Minute {
			backoff *= 2
		}
		select {
		case <-ctx.Done():
		case <-time.After(backoff):
		}
	}
}
