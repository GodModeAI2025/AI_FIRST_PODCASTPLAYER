#!/usr/bin/env python3
"""
Erzeugt den Platzhalter-App-Icon-Satz fuer PodcastAI.

**Warum ein Skript und keine abgelegten PNGs.** Ein Binaerblob im Repo ist
eine Datei, die niemand mehr aendern kann, ohne das Werkzeug zu haben, mit
dem sie entstand. Hier steht die Vorschrift, und die PNGs entstehen daraus.

**Warum ueberhaupt ein Icon.** Ohne AppIcon im Asset-Katalog scheitert
`xcodebuild archive` an der Validierung, und ohne Archiv gibt es keinen
TestFlight-Upload. Das hier ist ausdruecklich ein Platzhalter: Farbverlauf
und ein Wellenzeichen, keine Marke und kein Entwurf.

Kein PIL in dieser Umgebung, deshalb ein eigener PNG-Schreiber. PNG ist
dafuer einfach genug: Kopf, ein zlib-komprimierter Bilddatenblock mit einem
Filterbyte je Zeile, Ende.

    python3 app/Design/make_app_icon.py
"""
import math
import pathlib
import struct
import sys
import zlib

# Dieselben Farben wie `CoverView` sie fuer die erste Palette benutzt --
# Indigo nach Violett. Das Icon soll zur App gehoeren, nicht neben ihr stehen.
TOP = (0x34, 0x2E, 0x8C)
BOTTOM = (0x6D, 0x28, 0xA8)


def write_png(path, size, pixels):
    """Schreibt RGBA-Pixel als PNG. `pixels` ist eine Liste von Zeilen."""
    raw = bytearray()
    for row in pixels:
        raw.append(0)                      # Filtertyp 0: keiner
        for r, g, b, a in row:
            raw += bytes((r, g, b, a))

    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def render(size):
    """Farbverlauf mit einem Wellenzeichen in der Mitte."""
    center = (size - 1) / 2
    # Fuenf Balken, wie eine Tonspur. Die Hoehen sind fest und nicht
    # zufaellig: derselbe Lauf muss dasselbe Bild ergeben.
    bars = [0.34, 0.62, 1.00, 0.62, 0.34]
    bar_width = size * 0.072
    gap = size * 0.055
    total = len(bars) * bar_width + (len(bars) - 1) * gap
    left = center - total / 2 + 0.5
    max_height = size * 0.46
    radius = bar_width / 2

    rows = []
    for y in range(size):
        row = []
        t = y / max(1, size - 1)
        base = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
        for x in range(size):
            coverage = 0.0
            for index, scale in enumerate(bars):
                bx = left + index * (bar_width + gap)
                half = (max_height * scale) / 2
                # Abstand zum Balken als abgerundetes Rechteck.
                dx = max(bx - x, 0, x - (bx + bar_width))
                dy = max((center - half) - y, 0, y - (center + half))
                # Oben und unten runde Kappen, an den Seiten gerade Kanten.
                if dy > 0:
                    distance = math.hypot(x - (bx + radius), dy) - radius
                else:
                    distance = dx
                # Weiche Kante ueber knapp ein Pixel.
                edge = max(size / 512, 0.75)
                coverage = max(coverage, min(1.0, max(0.0, (edge - distance) / edge)))
            if coverage > 0:
                mixed = tuple(round(base[i] + (255 - base[i]) * coverage) for i in range(3))
                row.append((*mixed, 255))
            else:
                row.append((*base, 255))
        rows.append(row)
    return rows


IOS_SET = [1024]
MAC_SET = [16, 32, 64, 128, 256, 512, 1024]


def contents_ios():
    return """{
  "images" : [
    {
      "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""


def contents_mac():
    entries = []
    for point, scale in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                         (256, 1), (256, 2), (512, 1), (512, 2)]:
        pixels = point * scale
        entries.append(
            '    {\n'
            f'      "filename" : "icon-{pixels}.png",\n'
            '      "idiom" : "mac",\n'
            f'      "scale" : "{scale}x",\n'
            f'      "size" : "{point}x{point}"\n'
            '    }'
        )
    return '{\n  "images" : [\n' + ',\n'.join(entries) + \
           '\n  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n'


def main():
    root = pathlib.Path(__file__).resolve().parents[1]
    targets = [
        (root / "Apps/PodcastAI/Assets.xcassets/AppIcon.appiconset", IOS_SET, contents_ios()),
        (root / "Apps/PodcastAIMac/Assets.xcassets/AppIcon.appiconset", MAC_SET, contents_mac()),
    ]

    cache = {}
    for directory, sizes, contents in targets:
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "Contents.json").write_text(contents)
        (directory.parent / "Contents.json").write_text(
            '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n')
        for size in sizes:
            if size not in cache:
                cache[size] = render(size)
            write_png(directory / f"icon-{size}.png", size, cache[size])
            print(f"  {directory.name}/icon-{size}.png")

    print("Platzhalter-Icons erzeugt. Ein echtes Icon ersetzt sie, "
          "indem es dieselben Dateinamen belegt.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
