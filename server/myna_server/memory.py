"""Keeping models within the memory there is.

Every model that loads asks here first. Loads happen one at a time, so two big
models never start loading together. Before a model loads, the free memory on
the graphics card (or in ordinary memory, for one running on the processor) is
checked; if there isn't room, the models used longest ago are unloaded until
there is. A model unloaded this way simply loads again the next time it is
needed. The main speech recognizer is never unloaded to make room. If room
still can't be made on the graphics card, the caller falls back to the
processor (or, for a writing model, to sharing the two)."""

from __future__ import annotations

import os
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from typing import Callable

GB = 1024 ** 3
MARGIN = {"gpu": 0.8 * GB, "ram": 4 * GB}

# Rough graphics-card memory for each Whisper size (float16), in GB.
WHISPER_GB = {"tiny.en": 0.3, "base.en": 0.4, "small.en": 0.9, "medium.en": 2.1, "distil-medium.en": 1.2,
              "turbo": 1.9, "distil-large-v3": 1.8, "large-v2": 3.6, "large-v3": 3.6}


@dataclass
class Loaded:
    name: str
    device: str
    size: float
    unload: Callable[[], bool]
    keep: bool = False
    used: float = field(default_factory=time.time)


def _gpu_free() -> tuple[float, float] | None:
    """(free, total) bytes on the graphics card, or None if it can't be read."""
    try:
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.free,memory.total", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5, creationflags=flags,
        ).stdout.strip().splitlines()
        free, total = (float(part) * 1024 * 1024 for part in out[0].split(","))
        return free, total
    except Exception:
        return None


def _ram_free() -> tuple[float, float] | None:
    """(free, total) bytes of ordinary memory, or None if it can't be read."""
    try:
        if sys.platform == "win32":
            import ctypes

            class Status(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]

            status = Status()
            status.dwLength = ctypes.sizeof(Status)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status))
            return float(status.ullAvailPhys), float(status.ullTotalPhys)
        values = {}
        with open("/proc/meminfo", encoding="ascii") as info:
            for line in info:
                key, rest = line.split(":", 1)
                values[key] = float(rest.split()[0]) * 1024
        return values["MemAvailable"], values["MemTotal"]
    except Exception:
        return None


class Budget:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.loading = threading.Lock()   # one model loads at a time
        self.models: dict[str, Loaded] = {}
        self.probe: dict[str, Callable[[], tuple[float, float] | None]] = {"gpu": _gpu_free, "ram": _ram_free}
        self.last_note = ""
        self._cache: dict[str, tuple[float, tuple[float, float] | None]] = {}

    def reading(self, device: str, fresh: bool = False) -> tuple[float, float] | None:
        """Free and total memory, read at most every few seconds unless `fresh`
        (the status pages refresh often; reading the card isn't free)."""
        at, value = self._cache.get(device, (0.0, None))
        if fresh or time.time() - at > 3:
            value = self.probe[device]()
            self._cache[device] = (time.time(), value)
        return value

    def register(self, name: str, device: str, size: float, unload: Callable[[], bool], keep: bool = False) -> None:
        with self._lock:
            self.models[name] = Loaded(name, device, size, unload, keep)

    def forget(self, name: str) -> None:
        with self._lock:
            self.models.pop(name, None)

    def touch(self, name: str) -> None:
        with self._lock:
            if name in self.models:
                self.models[name].used = time.time()

    def free(self, device: str) -> float | None:
        reading = self.reading(device, fresh=True)
        return None if reading is None else reading[0]

    def make_room(self, name: str, device: str, size: float) -> bool:
        """Unload the least recently used models on `device` until `size`
        bytes fit. True if it fits (or memory can't be read, so we can't tell)."""
        free = self.free(device)
        if free is None:
            return True
        need = size + MARGIN[device]
        if free >= need:
            return True
        with self._lock:
            candidates = sorted((m for m in self.models.values() if m.device == device and m.name != name and not m.keep),
                                key=lambda m: m.used)
        for model in candidates:
            if free >= need:
                break
            try:
                freed = model.unload()   # False if it is busy right now; then it isn't idle, leave it
            except Exception:
                freed = False
            if freed:
                self.forget(model.name)
                self.last_note = f"{time.strftime('%H:%M')}: unloaded {model.name.split('@')[0]} to make room for {name.split('@')[0]}."
                time.sleep(1.0)  # let the memory actually come back
                free = self.free(device) or free + model.size
        return free >= need

    def snapshot(self) -> dict:
        def reading(device: str) -> str:
            value = self.reading(device)
            if value is None:
                return "unknown"
            free, total = value
            return f"{(total - free) / GB:.1f} of {total / GB:.0f} GB in use"

        with self._lock:
            loaded = sorted(self.models.values(), key=lambda m: -m.used)
            listing = [f"{m.name.split('@')[0]} ({'graphics card' if m.device == 'gpu' else 'processor'}, "
                       f"~{m.size / GB:.1f} GB{', kept' if m.keep else ''})" for m in loaded]
        return {"gpu": reading("gpu"), "ram": reading("ram"), "loaded": listing, "note": self.last_note}


budget = Budget()


def file_size(path: str) -> float:
    try:
        return float(os.path.getsize(path))
    except OSError:
        return 0.0
