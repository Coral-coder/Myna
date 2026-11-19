"""The three VFD text sizes, built from the 5x7 glyphs.

small: the 5x7 glyphs (9 rows with descenders), 6-cell advance
mid:   Scale2x (EPX) of small -> 10x14 (18 rows with descenders), 12-cell advance
big:   Scale3x of small -> 15x21 (27 rows with descenders), 18-cell advance

Scale2x/Scale3x add pixels along diagonals instead of plain doubling, so the
larger sizes are smoother while every pixel stays one grid cell."""

from __future__ import annotations

from glyphs import G, rows9

Bitmap = list[list[int]]   # rows of 0/1


def bitmap(ch: str) -> Bitmap:
    return [[1 if c == "#" else 0 for c in row] for row in rows9(ch)]


def _at(src: Bitmap, y: int, x: int) -> int:
    if 0 <= y < len(src) and 0 <= x < len(src[0]):
        return src[y][x]
    return 0


def scale2x(src: Bitmap) -> Bitmap:
    h, w = len(src), len(src[0])
    out = [[0] * (w * 2) for _ in range(h * 2)]
    for y in range(h):
        for x in range(w):
            p = src[y][x]
            a, b, c, d = _at(src, y - 1, x), _at(src, y, x + 1), _at(src, y, x - 1), _at(src, y + 1, x)
            e0 = a if (c == a and c != d and a != b) else p
            e1 = b if (a == b and a != c and b != d) else p
            e2 = c if (d == c and d != b and c != a) else p
            e3 = d if (b == d and b != a and d != c) else p
            out[2 * y][2 * x], out[2 * y][2 * x + 1] = e0, e1
            out[2 * y + 1][2 * x], out[2 * y + 1][2 * x + 1] = e2, e3
    return out


def scale3x(src: Bitmap) -> Bitmap:
    h, w = len(src), len(src[0])
    out = [[0] * (w * 3) for _ in range(h * 3)]
    for y in range(h):
        for x in range(w):
            A, B, C = _at(src, y - 1, x - 1), _at(src, y - 1, x), _at(src, y - 1, x + 1)
            D, E, F = _at(src, y, x - 1), src[y][x], _at(src, y, x + 1)
            Gg, H, I = _at(src, y + 1, x - 1), _at(src, y + 1, x), _at(src, y + 1, x + 1)
            if B != H and D != F:
                e0 = D if D == B else E
                e1 = B if (D == B and E != C) or (B == F and E != A) else E
                e2 = F if B == F else E
                e3 = D if (D == B and E != Gg) or (D == H and E != A) else E
                e5 = F if (B == F and E != I) or (H == F and E != C) else E
                e6 = D if D == H else E
                e7 = H if (D == H and E != I) or (H == F and E != Gg) else E
                e8 = F if H == F else E
            else:
                e0 = e1 = e2 = e3 = e5 = e6 = e7 = e8 = E
            block = [[e0, e1, e2], [e3, E, e5], [e6, e7, e8]]
            for dy in range(3):
                for dx in range(3):
                    out[3 * y + dy][3 * x + dx] = block[dy][dx]
    return out


SIZES = {"small": (1, 6), "mid": (2, 12), "big": (3, 18)}   # scale, advance in cells


def glyph(ch: str, size: str) -> Bitmap:
    base = bitmap(ch)
    return {"small": base, "mid": scale2x(base) if size == "mid" else base,
            "big": scale3x(base) if size == "big" else base}[size]


_cache: dict[tuple[str, str], Bitmap] = {}


def cached(ch: str, size: str) -> Bitmap:
    key = (ch, size)
    if key not in _cache:
        _cache[key] = glyph(ch, size)
    return _cache[key]


def chars() -> list[str]:
    return sorted(G, key=ord)
