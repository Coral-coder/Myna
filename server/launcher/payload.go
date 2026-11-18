package main

import (
	"archive/zip"
	"bytes"
	_ "embed"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// The Python side of the server (pyproject.toml + the myna_server package),
// zipped at build time. Shipping it inside the exe means one file to download
// and one file to update.
//
//go:embed payload.zip
var payloadZip []byte

// extractPayload unpacks the embedded Python source into app/<version>/ and
// returns that folder. A folder that is already complete is reused.
func extractPayload() (string, error) {
	dir := sub("app", version)
	marker := filepath.Join(dir, ".complete")
	if _, err := os.Stat(marker); err == nil {
		return dir, nil
	}
	_ = os.RemoveAll(dir)
	reader, err := zip.NewReader(bytes.NewReader(payloadZip), int64(len(payloadZip)))
	if err != nil {
		return "", fmt.Errorf("the built-in server files are damaged: %w", err)
	}
	for _, file := range reader.File {
		// Never write outside the target folder, whatever the archive says.
		target := filepath.Join(dir, filepath.FromSlash(file.Name))
		if !strings.HasPrefix(target, filepath.Clean(dir)+string(os.PathSeparator)) {
			return "", fmt.Errorf("unsafe path in server files: %s", file.Name)
		}
		if file.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return "", err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return "", err
		}
		source, err := file.Open()
		if err != nil {
			return "", err
		}
		out, err := os.Create(target)
		if err != nil {
			source.Close()
			return "", err
		}
		_, copyErr := io.Copy(out, source)
		source.Close()
		closeErr := out.Close()
		if copyErr != nil {
			return "", copyErr
		}
		if closeErr != nil {
			return "", closeErr
		}
	}
	return dir, os.WriteFile(marker, []byte(version), 0o644)
}

// removeOldPayloads deletes app/<other versions> left behind by updates.
func removeOldPayloads() {
	entries, err := os.ReadDir(sub("app"))
	if err != nil {
		return
	}
	for _, entry := range entries {
		if entry.IsDir() && entry.Name() != version {
			_ = os.RemoveAll(sub("app", entry.Name()))
		}
	}
}
