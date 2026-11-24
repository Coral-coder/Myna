"""Renders the VFD screens at device resolution for review."""

import sys
from pathlib import Path

from screens import SCREENS, SWATCHES
from vfd import IPHONE_2X, IPHONE_17_PRO, Frame, hex_rgb, palette_for


def render(name: str, device, base: str, out: Path, chosen: str = "AMBER") -> Path:
    f = Frame(device)
    if name == "appearance":
        SCREENS[name](f, chosen)
    else:
        SCREENS[name](f)
    palette = palette_for(base)
    for i, (_, colour) in enumerate(SWATCHES):
        palette[5 + i] = hex_rgb(colour)
    path = out / f"{name}-{device.width}x{device.height}-{chosen.lower()}.png"
    f.image(palette).save(path, optimize=True)
    return path


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "previews")
    out.mkdir(parents=True, exist_ok=True)
    for name in SCREENS:
        print(render(name, IPHONE_17_PRO, "#FFB014", out))
    print(render("today", IPHONE_2X, "#FFB014", out))
    print(render("today", IPHONE_17_PRO, "#3CF0DC", out, chosen="CYAN"))
    print(render("appearance", IPHONE_17_PRO, "#3CF0DC", out, chosen="CYAN"))
