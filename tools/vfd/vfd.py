"""The VFD frame buffer and its drawing calls: the same model the app's
renderer uses (one byte per cell = palette index, 0 = unlit), so layouts
worked out here carry over cell for cell."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from font import SIZES, cached

UNLIT, BASE, TEXT, DIM, ALARM = 0, 1, 2, 3, 4   # palette indexes; 5+ are swatches


def hex_rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def palette_for(base: str) -> dict[int, tuple[int, int, int]]:
    """The four lit colours from one base colour. Amber gives the specified
    #FFB014 / #FFE8C4 / #966428 / #FF5028."""
    if base.upper() == "#FFB014":
        text, dim = (0xFF, 0xE8, 0xC4), (0x96, 0x64, 0x28)
    else:
        r, g, b = hex_rgb(base)
        text = tuple(round(c + (255 - c) * 0.74) for c in (r, g, b))
        dim = tuple(min(255, round(c * 0.56 + 14)) for c in (r, g, b))
    return {UNLIT: (0x09, 0x09, 0x09), BASE: hex_rgb(base), TEXT: text, DIM: dim, ALARM: (0xFF, 0x50, 0x28)}


@dataclass
class Device:
    name: str
    width: int     # device pixels
    height: int
    pitch: int     # device pixels per cell
    top: int       # safe-area rows left empty at the top
    bottom: int    # and at the bottom


IPHONE_17_PRO = Device("iPhone 17 Pro (3x)", 1206, 2622, 5, top=38, bottom=21)
IPHONE_2X = Device("iPhone 11 (2x)", 828, 1792, 4, top=24, bottom=17)


class Frame:
    def __init__(self, device: Device) -> None:
        self.device = device
        self.cols = device.width // device.pitch
        self.rows = device.height // device.pitch
        self.cells = np.zeros((self.rows, self.cols), dtype=np.uint8)
        self.clip = (0, 0, self.cols, self.rows)   # x0, y0, x1, y1

    # -- cells -------------------------------------------------------------------
    def set(self, c: int, r: int, color: int) -> None:
        x0, y0, x1, y1 = self.clip
        if x0 <= c < x1 and y0 <= r < y1:
            self.cells[r, c] = color

    def fill(self, c: int, r: int, w: int, h: int, color: int) -> None:
        x0, y0, x1, y1 = self.clip
        a, b = max(c, x0), max(r, y0)
        e, f = min(c + w, x1), min(r + h, y1)
        if a < e and b < f:
            self.cells[b:f, a:e] = color

    def hline(self, c: int, r: int, w: int, color: int, step: int = 1) -> None:
        for x in range(c, c + w, step):
            self.set(x, r, color)

    def vline(self, c: int, r: int, h: int, color: int, step: int = 1) -> None:
        for y in range(r, r + h, step):
            self.set(c, y, color)

    def box(self, c: int, r: int, w: int, h: int, color: int) -> None:
        self.hline(c, r, w, color)
        self.hline(c, r + h - 1, w, color)
        self.vline(c, r, h, color)
        self.vline(c + w - 1, r, h, color)

    def line(self, c0: int, r0: int, c1: int, r1: int, color: int) -> None:
        """Single-cell Bresenham line."""
        dc, dr = abs(c1 - c0), -abs(r1 - r0)
        sc, sr = (1 if c0 < c1 else -1), (1 if r0 < r1 else -1)
        err = dc + dr
        while True:
            self.set(c0, r0, color)
            if c0 == c1 and r0 == r1:
                return
            e2 = 2 * err
            if e2 >= dr:
                err += dr
                c0 += sc
            if e2 <= dc:
                err += dc
                r0 += sr

    # -- text ----------------------------------------------------------------------
    @staticmethod
    def advance(size: str) -> int:
        return SIZES[size][1]

    @staticmethod
    def height(size: str) -> int:
        return 7 * SIZES[size][0]

    @classmethod
    def width_of(cls, text: str, size: str) -> int:
        if not text:
            return 0
        scale, adv = SIZES[size]
        return len(text) * adv - (adv - 5 * scale)

    def text(self, c: int, r: int, text: str, size: str = "small", color: int = TEXT) -> int:
        """Draws `text` with its top-left at (c, r); returns the column after it."""
        adv = self.advance(size)
        for i, ch in enumerate(text):
            bits = cached(ch, size)
            for y, row in enumerate(bits):
                for x, on in enumerate(row):
                    if on:
                        self.set(c + i * adv + x, r + y, color)
        return c + len(text) * adv

    def text_right(self, right: int, r: int, text: str, size: str = "small", color: int = TEXT) -> int:
        start = right - self.width_of(text, size)
        self.text(start, r, text, size, color)
        return start

    def text_fit(self, c: int, r: int, text: str, most: int, size: str = "small", color: int = TEXT) -> int:
        """Truncated with … to fit in `most` columns."""
        adv = self.advance(size)
        room = (most + (adv - 5 * SIZES[size][0])) // adv
        if len(text) > room:
            text = text[: max(0, room - 1)].rstrip() + "…"
        return self.text(c, r, text, size, color)

    def paragraph(self, c: int, r: int, text: str, most: int, size: str = "small", color: int = TEXT,
                  gap: int = 3, lines: int = 99) -> int:
        """Word-wrapped; returns the row below the last line."""
        adv = self.advance(size)
        room = max(1, (most + (adv - 5 * SIZES[size][0])) // adv)
        out: list[str] = []
        line = ""
        for word in text.split():
            while len(word) > room:
                if line:
                    out.append(line)
                    line = ""
                out.append(word[:room])
                word = word[room:]
            if not line:
                line = word
            elif len(line) + 1 + len(word) <= room:
                line += " " + word
            else:
                out.append(line)
                line = word
        if line:
            out.append(line)
        if len(out) > lines:
            out = out[:lines]
            out[-1] = (out[-1][: room - 1] + "…") if len(out[-1]) >= room else out[-1] + "…"
        step = self.height(size) + 2 * SIZES[size][0] + gap
        for i, piece in enumerate(out):
            self.text(c, r + i * step, piece, size, color)
        return r + len(out) * step

    # -- composite pieces --------------------------------------------------------------
    def inverted(self, c: int, r: int, w: int, text: str, size: str = "small", color: int = BASE,
                 pad: int = 2, center: bool = False) -> int:
        """A solid block with the text cut out (left unlit). Returns its height."""
        h = self.height(size) + 2 * pad + (2 * SIZES[size][0] if any(ch in "gjpqyµ,;" for ch in text) else 0)
        self.fill(c, r, w, h, color)
        room = w - 2 * (pad + 1)
        if self.width_of(text, size) > room:            # never spill out of the block
            adv = self.advance(size)
            text = text[: max(1, (room + adv - 5 * SIZES[size][0]) // adv - 1)].rstrip() + "…"
        tx = c + (w - self.width_of(text, size)) // 2 if center else c + pad + 1
        self.text(tx, r + pad, text, size, UNLIT)
        return h

    def bracket(self, c: int, r: int, text: str, selected: bool, color: int = TEXT) -> int:
        """An [OPTION] selector: inverted when selected. Returns the column after it."""
        tw = self.width_of(text, "small")
        w = tw + 14                                   # "[" 5 + gap 2, text, gap 2 + "]" 5
        if selected:
            self.inverted(c, r - 2, w, text, center=True)
        else:
            self.text(c, r, "[", "small", DIM)
            self.text(c + 7, r, text, "small", color)
            self.text(c + 7 + tw + 2, r, "]", "small", DIM)
        return c + w

    @classmethod
    def bracket_width(cls, text: str) -> int:
        return cls.width_of(text, "small") + 14

    def toggle(self, right: int, r: int, on: bool) -> None:
        """OFF / ON, right-aligned: the live state inverted, the other dim."""
        w_off, w_on = self.width_of("OFF", "small") + 6, self.width_of("ON", "small") + 6
        c_on = right - w_on
        c_off = c_on - 3 - w_off
        if on:
            self.text(c_off + 3, r, "OFF", "small", DIM)
            self.inverted(c_on, r - 2, w_on, "ON", center=True)
        else:
            self.inverted(c_off, r - 2, w_off, "OFF", center=True, color=DIM)
            self.text(c_on + 3, r, "ON", "small", DIM)

    def stepper(self, right: int, r: int, value: str) -> None:
        """[-] value [+], right-aligned."""
        plus = right - self.width_of("[+]", "small")
        self.text(plus, r, "[+]", "small", BASE)
        value_right = plus - 6
        self.text_right(value_right, r, value, "small", TEXT)
        minus = value_right - max(self.width_of(value, "small"), 17) - 6 - self.width_of("[-]", "small")
        self.text(minus, r, "[-]", "small", BASE)

    def led_bar(self, c: int, r: int, w: int, value: float, zone: tuple[float, float] | None = None,
                fill: bool = True, color: int = BASE) -> None:
        """6 rows: a dotted dim track, an optional lit target zone, and a solid
        fill or a 3x6 marker at `value` (0..1)."""
        self.hline(c, r + 2, w, DIM, step=2)
        self.hline(c + 1, r + 3, w - 1, DIM, step=2)
        if zone:
            a, b = int(c + zone[0] * (w - 1)), int(c + zone[1] * (w - 1))
            self.fill(a, r + 2, b - a + 1, 2, DIM)
        at = int(c + max(0.0, min(1.0, value)) * (w - 1))
        if fill:
            for x in range(c, at + 1):
                if (x - c) % 3 != 2:         # LED segments: 2 lit, 1 gap
                    self.vline(x, r + 1, 4, color)
        else:
            self.fill(min(at - 1, c + w - 3), r, 3, 6, color)

    def chart(self, c: int, r: int, w: int, h: int, values: list[float], color: int = BASE) -> None:
        """A single-cell line over a dotted dim baseline; values 0..1."""
        self.hline(c, r + h - 1, w, DIM, step=2)
        if len(values) < 2:
            return
        points = [(c + round(i * (w - 1) / (len(values) - 1)), r + h - 2 - round(v * (h - 2)))
                  for i, v in enumerate(values)]
        for (a, b), (x, y) in zip(points, points[1:]):
            self.line(a, b, x, y, color)

    # -- painting -------------------------------------------------------------------------
    def image(self, palette: dict[int, tuple[int, int, int]]):
        """Device-pixel image: each cell (pitch-1) px square, a 1 px black gap."""
        from PIL import Image

        p = self.device.pitch
        colors = np.zeros((256, 3), dtype=np.uint8)
        for index, rgb in palette.items():
            colors[index] = rgb
        rgb = colors[self.cells]                                  # rows x cols x 3
        big = np.repeat(np.repeat(rgb, p, axis=0), p, axis=1)
        mask = np.ones((p, p), dtype=bool)
        mask[p - 1, :] = False
        mask[:, p - 1] = False
        tile = np.tile(mask, (self.rows, self.cols))
        big[~tile] = 0
        out = np.zeros((self.device.height, self.device.width, 3), dtype=np.uint8)
        out[: big.shape[0], : big.shape[1]] = big
        return Image.fromarray(out)
