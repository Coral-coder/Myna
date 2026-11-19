"""A helper process for the sherpa-onnx models (the non-Whisper transcribers
and the voice models).

They run apart from the main worker for two reasons: their native libraries
can clash with the graphics-card libraries Whisper uses when both are loaded
into one process, and if one of them crashes it must not take the whole
server down with it: transcription carries on and the page says what failed.
"""

from __future__ import annotations

import multiprocessing
import threading


def serve(connection) -> None:
    """Runs in the helper process: load models and answer requests."""
    from . import engines

    recognizers: dict = {}
    voices = engines.VoicesLocal()

    def status(text: str) -> None:
        try:
            connection.send(("status", text))
        except Exception:
            pass

    while True:
        try:
            op, args = connection.recv()
        except (EOFError, OSError):
            return
        try:
            if op == "stt_load":
                (key,) = args
                if key not in recognizers:
                    while len(recognizers) >= 2:  # at most two held: the one in use and its partner
                        recognizers.pop(next(iter(recognizers)))
                    recognizers[key] = engines.load_sherpa(key, status)
                result = None
            elif op == "stt":
                key, samples = args
                if key not in recognizers:
                    while len(recognizers) >= 2:
                        recognizers.pop(next(iter(recognizers)))
                    recognizers[key] = engines.load_sherpa(key, status)
                result = engines.decode_sherpa(recognizers[key], key, samples)
            elif op == "voices_load":
                voices.load(status)
                result = None
            elif op == "split":
                result = voices.split(args[0])
            elif op == "print":
                result = voices.print_of(args[0])
            else:
                raise RuntimeError(f"unknown request: {op}")
            connection.send(("ok", result))
        except Exception as error:  # report it; stay alive for the next request
            connection.send(("error", str(error)))


class Sidecar:
    """The main worker's handle on the helper process."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._process = None
        self._connection = None
        self.crashes = 0

    def _ensure(self) -> None:
        if self._process is not None and self._process.is_alive():
            return
        if self._process is not None:
            self.crashes += 1  # it died between requests
            self._process = None
        if self.crashes >= 3:
            raise RuntimeError("switched off after stopping unexpectedly three times; restart the server to try again")
        context = multiprocessing.get_context("spawn")
        self._connection, child = context.Pipe()
        self._process = context.Process(target=serve, args=(child,), daemon=True, name="myna-sherpa")
        self._process.start()
        child.close()

    def call(self, op: str, *args, report=None, timeout: float = 900):
        with self._lock:
            self._ensure()
            try:
                self._connection.send((op, args))
                while True:
                    if not self._connection.poll(timeout):
                        raise RuntimeError("the helper took too long")
                    kind, value = self._connection.recv()
                    if kind == "status":
                        if report:
                            report(value)
                    elif kind == "ok":
                        return value
                    else:
                        raise RuntimeError(value)
            except (EOFError, OSError, BrokenPipeError) as error:
                code = None
                if self._process is not None:
                    self._process.join(timeout=2)
                    code = self._process.exitcode
                self._process = None
                self.crashes += 1
                shown = f"0x{code & 0xFFFFFFFF:08x}" if isinstance(code, int) else "unknown"
                raise RuntimeError(f"its helper process stopped unexpectedly (code {shown})") from error


# One helper for the whole worker.
helper = Sidecar()
