"""Run the server: `python -m myna_server`."""

from __future__ import annotations

import argparse
import threading

import uvicorn

from .app import create_app
from .config import Config, data_dir
from .engines import LlamaWriter, Voices, WhisperTranscriber
from .store import Store


def main() -> None:
    parser = argparse.ArgumentParser(prog="myna-server", description="Myna home server")
    parser.add_argument("--host", default="127.0.0.1", help="Address to listen on (the launcher puts Tailscale in front)")
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--allow-lan", action="store_true", help="Also answer devices on the home network")
    parser.add_argument("--show-token", action="store_true", help="Print the pairing token and exit")
    args = parser.parse_args()

    config = Config.load()
    if args.show_token:
        print(config.token)
        return
    store = Store(data_dir() / "myna.db")
    transcriber, writer, voices = WhisperTranscriber(config), LlamaWriter(config), Voices()
    app = create_app(config, transcriber, writer, allow_lan=args.allow_lan, store=store, voices=voices)

    # Get both models downloaded and loaded now rather than on the first request.
    def warm() -> None:
        transcriber.warm()
        voices.warm()
        writer.warm()

    threading.Thread(target=warm, daemon=True).start()
    uvicorn.run(app, host=args.host, port=args.port or config.port, log_level="info")


if __name__ == "__main__":
    main()
