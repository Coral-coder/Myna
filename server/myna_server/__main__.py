"""Run the server: `python -m myna_server`."""

from __future__ import annotations

import argparse
import os
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

    # If a native library crashes the worker, leave the Python stack behind
    # in a file so the cause can be seen.
    import faulthandler

    crash_log = open(data_dir() / "worker-crash.log", "a", encoding="utf-8")
    faulthandler.enable(file=crash_log, all_threads=True)

    config = Config.load()
    if args.show_token:
        print(config.token)
        return
    store = Store(data_dir() / "myna.db")
    transcriber, writer, voices = WhisperTranscriber(config), LlamaWriter(config), Voices()
    transcriber.essential = True  # the main recognizer is never unloaded to make room
    helper, summarizer = LlamaWriter(config, "helper"), LlamaWriter(config, "summary")
    checker = LlamaWriter(config, "checker")
    embedder = LlamaWriter(config, "embedder")
    audio_dir = data_dir() / "audio"
    def partner_for(model: str, device: str | None = None):
        """Another recognizer beside the one in use, with its own settings."""
        from dataclasses import replace

        return WhisperTranscriber(replace(config, stt_model=model, stt_device=device or config.stt_device))

    app = create_app(config, transcriber, writer, allow_lan=args.allow_lan, store=store, voices=voices,
                     helper=helper, summarizer=summarizer, audio_dir=audio_dir, partner_for=partner_for,
                     learning_path=data_dir() / "learning.json", checker=checker, embedder=embedder)

    def housekeeping() -> None:
        """Once a minute: write the day's summary when the day has gone quiet,
        and clear out audio past its keeping time."""
        import time
        from datetime import datetime

        last_purge = 0.0
        while True:
            time.sleep(60)
            try:
                now = time.time()
                last = store.last_clip_at()
                if config.daily_summary and last > 0 and now - last >= config.idle_minutes * 60:
                    day = datetime.fromtimestamp(last).strftime("%Y-%m-%d")
                    written = store.get("daily", day)
                    if written is None or float(written.get("writtenAt") or 0) < last:
                        app.state.run_daily(day)
                # Write up conversations that have ended.
                if config.conversations:
                    app.state.run_conversations()
                app.state.run_indexing()
                # Tune the transcription model while things are quiet.
                if (config.auto_tune and last > 0 and now - last >= 20 * 60
                        and now - config.tuned_at >= config.tune_every_hours * 3600):
                    config.tuned_at = now  # don't retry every minute if it can't run
                    app.state.run_tune()
                if now - last_purge > 3600:
                    last_purge = now
                    for path in store.drop_clips_before(now - max(config.keep_audio_days, 0) * 86400):
                        try:
                            os.remove(path)
                        except OSError:
                            pass
            except Exception:
                pass  # try again next minute

    threading.Thread(target=housekeeping, daemon=True).start()

    # Get both models downloaded and loaded now rather than on the first request.
    def warm() -> None:
        transcriber.warm()
        voices.warm()
        writer.warm()
        helper.warm()
        checker.warm()

    threading.Thread(target=warm, daemon=True).start()
    uvicorn.run(app, host=args.host, port=args.port or config.port, log_level="info")


if __name__ == "__main__":
    main()
