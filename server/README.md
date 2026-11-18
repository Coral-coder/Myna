# Myna Server

Runs Myna's heavy work — transcription and note-writing — on your own computer
at home, so the phone doesn't have to. The phone uses it whenever it answers and
does the work itself whenever it doesn't.

## What it is

- `MynaServer.exe` (in `launcher/`) is the only thing you run. It:
  - installs Python and the speech and language packages into its own folder
    (`%LOCALAPPDATA%\MynaServer`), with nothing else to install;
  - runs and restarts the worker that does the transcription and writing;
  - joins your private Tailscale network by itself — no Tailscale app, no
    administrator rights. You sign in once in the browser;
  - opens its own window with the status and the pairing code to scan with
    Myna (closing the window leaves the server running; open the exe again to
    see it);
  - starts when you sign in to Windows;
  - checks GitHub every ten minutes and replaces itself when a new release is out.
- `myna_server/` is the worker: a small API (`/health`, `/v1/transcribe`,
  `/v1/generate`). Every request needs the pairing token.

## Requirements

- Windows 11, an NVIDIA graphics card with a current driver (built for an
  RTX 4070, 12 GB). No separate CUDA install: the packages bring their own.
- A free Tailscale account, used only so the phone and this computer can find
  each other privately.
- About 20 GB of disk for packages and models on first run.

## Models

- Transcription: Whisper large-v3 turbo (faster-whisper).
- Writing: Gemma 4 12B, 4-bit (llama.cpp), downloaded from Hugging Face on
  first use.

Both can be changed in `%LOCALAPPDATA%\MynaServer\config.json`.

## Updates and trust

A release publishes `MynaServer.exe` and `manifest.json` (version and SHA-256).
The running server downloads the exe only if the version is later and the file
matches the checksum. The checksum comes from the same GitHub release as the
exe, so this guards against a damaged download, not against someone who can
publish to this repository. The exe is not code-signed, so Windows SmartScreen
will warn the first time it is run.

## Development

```
cd server
pip install fastapi uvicorn httpx numpy pytest
python -m pytest tests

zip -r launcher/payload.zip pyproject.toml uv.lock myna_server   # the worker, embedded in the exe
cd launcher
go test ./...
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "-H=windowsgui -X main.version=0.1.0" -o MynaServer.exe .
```
