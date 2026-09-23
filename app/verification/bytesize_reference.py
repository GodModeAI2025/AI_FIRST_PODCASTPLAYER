"""
Referenzmodell zu PodcastAIMedia/MediaLibrary.readableByteSize.

Warum eigene Formatierung statt `ByteCountFormatter`: die Angabe steht in
einer Oberflaeche, die dem Nutzer sagt, wie viel Platz er freigibt. Eine
Zahl, die niemand nachrechnen kann, ist an dieser Stelle wertlos -- und
`ByteCountFormatter` haengt an Systemeinstellungen, laesst sich hier nicht
ausfuehren und waere damit ungeprueft.

Geprueft wird gegen die Regel selbst: Dezimalpraefixe (1000, nicht 1024),
eine Nachkommastelle ab KB, ganze Zahlen bei Bytes, keine negative Groesse.
"""
import sys


def readable(value):
    """Portierung von Int64.readableByteSize."""
    units = ["B", "KB", "MB", "GB", "TB"]
    v = float(max(0, value))
    index = 0
    while v >= 1000 and index < len(units) - 1:
        v /= 1000
        index += 1
    if index == 0:
        return f"{int(v)} {units[index]}"
    return f"{v:.1f} {units[index]}"


CASES = [
    (0, "0 B"),
    (1, "1 B"),
    (999, "999 B"),
    (1000, "1.0 KB"),
    (1500, "1.5 KB"),
    (999_999, "1000.0 KB"),
    (1_000_000, "1.0 MB"),
    (52_400_000, "52.4 MB"),
    (1_000_000_000, "1.0 GB"),
    (2 * 1024 * 1024 * 1024, "2.1 GB"),      # die Download-Obergrenze
    (1_000_000_000_000, "1.0 TB"),
    (10 ** 18, "1000000.0 TB"),              # laeuft nicht ueber die Einheiten hinaus
    (-1, "0 B"),                             # negative Groesse gibt es nicht
    (-10 ** 12, "0 B"),
]


def main():
    checks = 0
    failures = []

    for value, expected in CASES:
        checks += 1
        got = readable(value)
        if got != expected:
            failures.append(f"{value} -> {got!r} statt {expected!r}")

    # Monotonie: mehr Bytes duerfen nie weniger anzeigen. Geprueft ueber den
    # numerischen Anteil zusammen mit der Einheit, nicht ueber den Text.
    order = {u: i for i, u in enumerate(["B", "KB", "MB", "GB", "TB"])}
    previous = None
    for value in [0, 1, 999, 1000, 1001, 999_999, 1_000_000, 10**9, 10**12, 10**15]:
        number, unit = readable(value).split(" ")
        key = (order[unit], float(number))
        checks += 1
        if previous is not None and key < previous:
            failures.append(f"nicht monoton bei {value}: {readable(value)}")
        previous = key

    # Die Einheit wechselt genau bei 1000, nicht bei 1024. Wer 1 KB liest,
    # soll 1000 Bytes meinen duerfen.
    checks += 1
    if not (readable(999).endswith("B") and readable(1000).endswith("KB")):
        failures.append("Einheitenwechsel nicht bei 1000")

    if failures:
        for line in failures:
            print(f"  FEHLER: {line}")
        print(f"Byte-Groessen-Referenz: {len(failures)} von {checks} Pruefungen fehlgeschlagen.")
        return 1

    print(f"Byte-Groessen-Referenz: {checks} Pruefungen bestanden "
          f"({len(CASES)} Festwerte, Monotonie, Dezimalpraefixe).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
