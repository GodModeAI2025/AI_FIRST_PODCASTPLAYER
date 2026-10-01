#!/usr/bin/env python3
"""Erzeugt den tvOS-Katalog `App Icon & Top Shelf Image` aus dem App-Symbol.

Das Symbol von iOS und Mac (icon-1024.png) ist die einzige Quelle. Für tvOS
braucht es Ebenen: hinten der Verlauf, vorn die Balken. Der Verlauf kommt aus
den vier Ecken des Symbols, die Balken aus dem Unterschied zum Verlauf.

    python3 app/scripts/make-tv-icons.py

Schreibt nach app/Apps/PodcastAITV/Assets.xcassets. Braucht Pillow.
"""

import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Apps/Shared/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
CATALOG = ROOT / "Apps/PodcastAITV/Assets.xcassets"
BRAND = CATALOG / "App Icon & Top Shelf Image.brandassets"
INFO = {"author": "xcode", "version": 1}


def write_json(path: Path, content: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(content, indent=2, ensure_ascii=False) + "\n")


def gradient(size: tuple[int, int], corners: list[tuple[int, int, int]]) -> Image.Image:
    """Bilinearer Verlauf aus vier Eckfarben (oben links, oben rechts, unten links, unten rechts)."""
    tl, tr, bl, br = corners
    vertical = Image.linear_gradient("L").resize(size, Image.BILINEAR)
    horizontal = Image.linear_gradient("L").rotate(90, expand=True).resize(size, Image.BILINEAR)

    def solid(color: tuple[int, int, int]) -> Image.Image:
        return Image.new("RGB", size, color)

    top = Image.composite(solid(tr), solid(tl), horizontal)
    bottom = Image.composite(solid(br), solid(bl), horizontal)
    return Image.composite(bottom, top, vertical)


def layers(source: Image.Image, size: tuple[int, int]) -> tuple[Image.Image, Image.Image]:
    """Gibt (hinten, vorn) in der Größe `size` zurück."""
    width, height = size
    s = source.convert("RGB")
    last = s.width - 1
    corners = [s.getpixel((6, 6)), s.getpixel((last - 6, 6)), s.getpixel((6, last - 6)), s.getpixel((last - 6, last - 6))]

    # Das Symbol wird so groß wie die Höhe; die Bühne dahinter ist der Verlauf.
    side = height
    icon = s.resize((side, side), Image.LANCZOS)
    background_small = gradient((side, side), corners)
    back = gradient(size, corners)

    front = Image.new("RGBA", size, (0, 0, 0, 0))
    offset = ((width - side) // 2, 0)
    ip, bp = icon.load(), background_small.load()
    fp = front.load()
    for y in range(side):
        for x in range(side):
            r, g, b = ip[x, y]
            br_, bg_, bb_ = bp[x, y]
            diff = max(abs(r - br_), abs(g - bg_), abs(b - bb_))
            alpha = max(0, min(255, round((diff - 12) * 255 / 90)))
            if alpha:
                fp[x + offset[0], y + offset[1]] = (r, g, b, alpha)
    return back, front


def stack(name: str, size: tuple[int, int], scales: tuple[int, ...], source: Image.Image) -> None:
    folder = BRAND / f"{name}.imagestack"
    renders = {scale: layers(source, (size[0] * scale, size[1] * scale)) for scale in scales}
    for position, layer_name in ((1, "Front"), (0, "Back")):
        layer = folder / f"{layer_name}.imagestacklayer"
        write_json(layer / "Contents.json", {"info": INFO})
        content = layer / "Content.imageset"
        images = []
        for scale, pair in renders.items():
            filename = f"{layer_name.lower()}-{size[0] * scale}x{size[1] * scale}.png"
            content.mkdir(parents=True, exist_ok=True)
            pair[position].save(content / filename)
            images.append({"filename": filename, "idiom": "tv", "scale": f"{scale}x"})
        write_json(content / "Contents.json", {"images": images, "info": INFO})
    write_json(folder / "Contents.json", {
        "layers": [{"filename": "Front.imagestacklayer"}, {"filename": "Back.imagestacklayer"}],
        "info": INFO,
    })


def shelf(name: str, size: tuple[int, int], source: Image.Image) -> None:
    folder = BRAND / f"{name}.imageset"
    images = []
    for scale in (1, 2):
        pixel = (size[0] * scale, size[1] * scale)
        back, front = layers(source, pixel)
        flat = back.convert("RGBA")
        flat.alpha_composite(front)
        filename = f"{name.lower().replace(' ', '-')}-{pixel[0]}x{pixel[1]}.png"
        folder.mkdir(parents=True, exist_ok=True)
        flat.convert("RGB").save(folder / filename)
        images.append({"filename": filename, "idiom": "tv", "scale": f"{scale}x"})
    write_json(folder / "Contents.json", {"images": images, "info": INFO})


def main() -> None:
    source = Image.open(SOURCE)
    write_json(CATALOG / "Contents.json", {"info": INFO})
    stack("App Icon - Large", (1280, 768), (1,), source)
    stack("App Icon - Small", (400, 240), (1, 2), source)
    shelf("Top Shelf Image", (1920, 720), source)
    shelf("Top Shelf Image Wide", (2320, 720), source)
    write_json(BRAND / "Contents.json", {
        "assets": [
            {"filename": "App Icon - Large.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
            {"filename": "App Icon - Small.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
            {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
            {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        ],
        "info": INFO,
    })
    # Akzentfarbe wie in den anderen Apps: dunkel auf Hell, hell auf Dunkel.
    write_json(CATALOG / "AccentColor.colorset/Contents.json", {
        "colors": [
            {"idiom": "universal", "color": {"color-space": "srgb", "components": {"red": "0.200", "green": "0.160", "blue": "0.550", "alpha": "1.000"}}},
            {"idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}],
             "color": {"color-space": "srgb", "components": {"red": "0.450", "green": "0.600", "blue": "1.000", "alpha": "1.000"}}},
        ],
        "info": INFO,
    })


if __name__ == "__main__":
    main()
