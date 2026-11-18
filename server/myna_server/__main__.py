"""Run the server: `python -m myna_server`."""

from __future__ import annotations

import argparse

import uvicorn

from .app import create_app
from .config import Config
from .engines import LlamaWriter, WhisperTranscriber


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
    app = create_app(config, WhisperTranscriber(config), LlamaWriter(config), allow_lan=args.allow_lan)
    uvicorn.run(app, host=args.host, port=args.port or config.port, log_level="info")


if __name__ == "__main__":
    main()
