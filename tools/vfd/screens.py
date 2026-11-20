"""The main Myna screens, drawn immediate-mode into a Frame. Columns are
proportional to the width so they work at 241 cells (3x) and 207 (2x)."""

from __future__ import annotations

import math

from vfd import ALARM, BASE, DIM, TEXT, UNLIT, Frame

TABS = ("ASK", "TODAY", "MEMORY", "SETTINGS")
TAB_H = 15          # tab bar rows (inc. its top rule)
HEAD_H = 22         # header rows (inc. its bottom rule)


class Layout:
    def __init__(self, f: Frame) -> None:
        self.f = f
        self.m = max(4, round(f.cols * 0.03))                  # side margin
        self.left, self.right = self.m, f.cols - self.m          # usable columns [left, right)
        self.top = f.device.top
        self.bottom = f.rows - f.device.bottom                   # first safe-area row at the bottom
        self.body_top = self.top + HEAD_H
        self.body_bottom = self.bottom - TAB_H                   # first tab-bar row

    @property
    def width(self) -> int:
        return self.right - self.left

    def col(self, fraction: float) -> int:
        """A column at a fraction of the usable width."""
        return self.left + round(self.width * fraction)


def header(L: Layout, title: str, back: str | None = None, right: str | None = None, right_color: int = DIM) -> None:
    f = L.f
    r = L.top + 4
    c = L.left
    if back:
        c = f.text(c, r + 4, "< " + back, "small", BASE) + 6
    f.text(c, r, title, "mid", TEXT)
    if right:
        f.text_right(L.right, r + 4, right, "small", right_color)
    f.hline(0, L.top + HEAD_H - 1, f.cols, DIM, step=2)


def tab_bar(L: Layout, active: str) -> None:
    f = L.f
    r = L.body_bottom
    f.hline(0, r, f.cols, DIM, step=2)
    slot = (L.right - L.left + 4) / len(TABS)
    for i, name in enumerate(TABS):
        x0, x1 = L.left - 2 + round(i * slot), L.left - 2 + round((i + 1) * slot)
        if name == active:
            f.inverted(x0 + 2, r + 3, x1 - x0 - 4, name, center=True, pad=3)
        else:
            f.text(x0 + (x1 - x0 - f.width_of(name, "small")) // 2, r + 6, name, "small", DIM)


def clip_body(L: Layout) -> None:
    L.f.clip = (0, L.body_top, L.f.cols, L.body_bottom)


def unclip(L: Layout) -> None:
    L.f.clip = (0, 0, L.f.cols, L.f.rows)


def section(L: Layout, r: int, label: str, right: str | None = None, right_color: int = DIM) -> int:
    """A dim label with a dotted rule after it; returns the row below."""
    f = L.f
    end = f.text(L.left, r, label, "small", DIM)
    rule_end = L.right
    if right:
        rule_end = f.text_right(L.right, r, right, "small", right_color) - 4
    f.hline(end + 3, r + 3, rule_end - end - 3, DIM, step=2)
    return r + 12


# -- TODAY ------------------------------------------------------------------------------------


def today(f: Frame) -> None:
    L = Layout(f)
    header(L, "TODAY", right="THU 19 NOV")
    clip_body(L)
    r = L.body_top + 3
    banner = "LISTENING · BRACELET · HOME SERVER"
    if f.width_of(banner, "small") > L.width - 6:
        banner = "LISTENING · BRACELET · SERVER"
    r += f.inverted(L.left, r, L.width, banner, center=True, pad=2) + 5

    # Hero readouts: labels carry the units.
    c2 = L.col(0.56)
    f.text_fit(L.left, r, "WORDS TODAY", c2 - L.left - 6, "small", DIM)
    f.text(c2, r, "SPEAKING NOW", "small", DIM)
    f.text(L.left, r + 11, "8,412", "big", BASE)
    f.text(c2, r + 11, "ARA", "mid", TEXT)
    f.text(c2, r + 28, "+1 OTHER VOICE", "small", DIM)
    r += 11 + 21 + 8

    # Bracelet + server panel.
    box_h = 41
    f.box(L.left, r, L.width, box_h, DIM)
    inner = L.left + 4
    cols = [inner, L.col(0.33), L.col(0.64), L.right - 4]
    for i, (label, value, colour) in enumerate(zip(("BATTERY %", "RSSI DBM", "HELD CLIPS"),
                                                   ("72", "-61", "0"), (BASE, TEXT, TEXT))):
        c = cols[i]
        f.text_fit(c, r + 3, label, cols[i + 1] - c - 4, "small", DIM)
        f.text(c, r + 13, value, "mid", colour)
    f.led_bar(inner, r + box_h - 10, L.width - 8, 0.72, fill=True)
    r += box_h + 6

    # Speech per hour.
    r = section(L, r, "SPEECH MIN / HOUR", "LAST 12 H")
    values = [0.05, 0.1, 0.0, 0.3, 0.55, 0.4, 0.8, 0.95, 0.6, 0.7, 0.35, 0.5, 0.65]
    f.chart(L.left, r, L.width, 26, values)
    for i, hour in enumerate(("01", "04", "07", "10", "13")):
        x = L.left + round(i * (L.width - 1) / 4)
        if i == 4:
            f.text_right(L.right, r + 28, hour, "small", DIM)
        elif i == 0:
            f.text(x, r + 28, hour, "small", DIM)
        else:
            f.text(x - 5, r + 28, hour, "small", DIM)
    r += 28 + 13

    # Transcript.
    r = section(L, r, "TRANSCRIPT", "LIVE", BASE)
    lines = [
        ("10:04", "CALLER", "Yeah what's your problem? Oh no, I have a problem, we are flooding.", TEXT),
        ("10:04", "ARA", "Other problem is that Alice is sick again, so I'm making her salt water and honey.", TEXT),
        ("10:05", "CALLER", "They just issued a flood warning. Did you get it?", TEXT),
        ("10:05", "ARA", "Yep. Yay. We get to stay home together.", TEXT),
        ("10:06", "ALERT", "Flood warning for Harris County until 7 PM.", ALARM),
    ]
    text_c = L.col(0.25)
    for clock, who, said, colour in lines:
        f.text(L.left, r, clock, "small", DIM)
        f.text(L.left, r + 10, who, "small", ALARM if colour == ALARM else BASE)
        r = f.paragraph(text_c, r, said, L.right - text_c, "small", colour, gap=2) + 5
    unclip(L)
    tab_bar(L, "TODAY")


# -- ASK ------------------------------------------------------------------------------------------


def ask(f: Frame) -> None:
    L = Layout(f)
    header(L, "ASK", right="[NEW CHAT]", right_color=BASE)
    clip_body(L)
    r = L.body_top + 4

    def mine(r: int, text: str) -> int:
        w = round(L.width * 0.74)
        c = L.right - w
        rows_end = f.paragraph(c + 4, r + 4, text, w - 8, "small", TEXT, gap=2)
        h = rows_end - r + 2
        f.box(c, r, w, h, DIM)
        # redraw text after box so nothing overlaps
        f.paragraph(c + 4, r + 4, text, w - 8, "small", TEXT, gap=2)
        return r + h + 6

    def reply(r: int, text: str) -> int:
        f.text(L.left, r, "MYNA", "small", BASE)
        f.text(L.left + 30, r, "10:12", "small", DIM)
        r += 11
        return f.paragraph(L.left, r, text, round(L.width * 0.92), "small", TEXT, gap=2) + 6

    r = mine(r, "Is it going to keep raining today?")
    r = reply(r, "Yes. The flood watch runs until 7 PM and heavy rain eases after about 4.")
    # Weather readout panel inside the reply.
    box_h = 48
    f.box(L.left, r, L.width, box_h, BASE)
    c2 = L.col(0.5)
    f.text(L.left + 4, r + 4, "RAIN NEXT 3 H %", "small", DIM)
    f.text(c2, r + 4, "NOW °F", "small", DIM)
    f.text(L.left + 4, r + 15, "90", "big", BASE)
    f.text(c2, r + 15, "71", "big", TEXT)
    f.led_bar(L.left + 4, r + box_h - 9, L.width - 8, 0.9, zone=(0.0, 0.3), fill=False, color=ALARM)
    r += box_h + 8
    r = mine(r, "What did Alice need?")
    r = reply(r, "Salt water and honey for her throat. You said you'd make it before work, and she's upstairs asleep.")
    r = mine(r, "Remind me at 3 to check on her")
    r = reply(r, "Done: “Check on Alice” at 3:00 PM.")
    f.text(L.left, r, "✓ REMINDER SET", "small", BASE)

    # Input row above the tab bar.
    ir = L.body_bottom - 16
    f.fill(0, ir - 2, f.cols, 18, UNLIT)
    send_w = f.width_of("SEND", "small") + 10
    f.box(L.left, ir, L.width - send_w - 3, 13, DIM)
    f.text(L.left + 4, ir + 3, "Ask Myna…", "small", DIM)
    f.inverted(L.right - send_w, ir, send_w, "SEND", center=True, pad=3)
    unclip(L)
    tab_bar(L, "ASK")


# -- MEMORY --------------------------------------------------------------------------------------


def memory(f: Frame) -> None:
    L = Layout(f)
    header(L, "MEMORY", right="128 SAVED")
    clip_body(L)
    r = L.body_top + 5
    c = L.left
    names = ["CONVERSATIONS", "NOTES", "MEMORIES", "LISTS"]
    if sum(f.bracket_width(n) + 3 for n in names) > L.width:
        names[0] = "TALKS"
    for i, name in enumerate(names):
        c = f.bracket(c, r, name, i == 0) + 3
    r += 15
    items = [
        ("10:05", "HOME", "Flood warning: staying home", "Rain closed everything near NASA Center; working from home together today.", "1 TO DO", False),
        ("09:50", "HEALTH", "Alice is sick: salt water and honey", "Making a hot salt-water gargle and honey; Alice is upstairs asleep.", "2 TO DO", False),
        ("09:58", "ERRAND", "Sandbags on Singleton", "There was a sandbag distribution point on Singleton; not sure it is open.", "", True),
        ("YESTERDAY", "WORK", "Launch moved to March", "Agreed to move the launch; tell the team about the new date.", "1 TO DO · 1 SONG", False),
        ("YESTERDAY", "MUSIC", "Blue in Green, Miles Davis", "Heard at 21:14 while cooking. Added to the Heard playlist.", "", False),
    ]
    for clock, cat, title, gist, meta, alarm in items:
        f.text(L.left, r, clock, "small", DIM)
        f.text_right(L.right, r, cat, "small", ALARM if alarm else BASE)
        r += 11
        r = f.paragraph(L.left, r, title, L.width, "mid", TEXT, gap=1, lines=2) + 2
        r = f.paragraph(L.left, r, gist, L.width, "small", DIM, gap=2, lines=2)
        if meta:
            f.text(L.left, r, meta, "small", BASE)
            r += 11
        r += 2
        f.hline(L.left, r, L.width, DIM, step=2)
        r += 6
    unclip(L)
    tab_bar(L, "MEMORY")


# -- SETTINGS → APPEARANCE ------------------------------------------------------------------------

SWATCHES = [("AMBER", "#FFB014"), ("GREEN", "#3CFF6E"), ("CYAN", "#3CF0DC"), ("BLUE", "#5AA0FF"),
            ("RED", "#FF4B3C"), ("WHITE", "#F0F0F0")]


def appearance(f: Frame, chosen: str = "AMBER") -> None:
    L = Layout(f)
    header(L, "APPEARANCE", back="BACK")
    clip_body(L)
    r = L.body_top + 4
    r = section(L, r, "THEME")
    c = L.left
    for name, on in (("STANDARD", False), ("AMBER VFD", True)):
        c = f.bracket(c, r, name, on) + 5
    r += 16

    r = section(L, r, "BASE COLOR")
    per_row = 3
    cell_w = L.width // per_row
    for i, (name, _) in enumerate(SWATCHES):
        x = L.left + (i % per_row) * cell_w
        y = r + (i // per_row) * 16
        f.fill(x, y, 7, 7, 5 + i)                       # a swatch in its own colour
        if name == chosen:
            f.inverted(x + 10, y - 2, f.width_of(name, "small") + 6, name, center=True)
        else:
            f.text(x + 13, y, name, "small", TEXT)
    r += 2 * 16 + 4
    f.text(L.left, r, "SAMPLE READOUT", "small", DIM)
    f.text(L.left, r + 11, "12:41", "big", BASE)
    f.text(L.col(0.56), r + 11, "LIVE", "mid", TEXT)
    f.text(L.col(0.56), r + 28, "LABEL · UNIT", "small", DIM)
    r += 11 + 21 + 6
    f.led_bar(L.left, r, L.width, 0.62, fill=True)
    r += 12

    r = section(L, r, "DISPLAY")
    rows = [("LIVE TICKER", "toggle", True), ("SERVER ONLY", "toggle", False),
            ("SHOW UNLIT CELLS", "toggle", True), ("TRANSCRIPT LINES", "stepper", "40"),
            ("CLOCK", "options", ("12 H", "24 H"))]
    for label, kind, value in rows:
        f.text(L.left, r, label, "small", TEXT)
        if kind == "toggle":
            f.toggle(L.right, r, value)
        elif kind == "stepper":
            f.stepper(L.right, r, value)
        else:
            w = sum(f.bracket_width(v) for v in value) + 4 * (len(value) - 1)
            c = L.right - w
            for i, v in enumerate(value):
                c = f.bracket(c, r, v, i == 1) + 4
        r += 15
        f.hline(L.left, r - 4, L.width, DIM, step=4)
    r += 2
    f.paragraph(L.left, r, "The whole screen is one grid of cells. Bigger text uses more cells, never bigger ones.",
                L.width, "small", DIM, gap=2)
    unclip(L)
    tab_bar(L, "SETTINGS")


SCREENS = {"today": today, "ask": ask, "memory": memory, "appearance": appearance}
