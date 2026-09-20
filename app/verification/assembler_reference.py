"""
Referenzmodell zu PodcastAITranscription/TranscriptAssembler.swift.

Der Fall, der hier wirklich zaehlt: eine unterbrochene Analyse wird
wiederaufgenommen, dabei werden 5 Sekunden erneut analysiert. Die
Ueberlappung darf weder doppelte Segmente erzeugen noch Text verlieren.
"""
import random
from intervalset_reference import union, total

THRESHOLD = 0.6


def insert(rng, text, result):
    """Portierung von TranscriptAssembler.insert."""
    if rng[1] <= rng[0] or not text.strip():
        return result
    keep = []
    for c in result:
        lo, hi = max(c[0][0], rng[0]), min(c[0][1], rng[1])
        overlap = max(0, hi - lo)
        shorter = min(c[0][1] - c[0][0], rng[1] - rng[0])
        if shorter > 0 and overlap / shorter >= THRESHOLD:
            continue                          # wird verdraengt
        keep.append(c)
    return keep + [(rng, text.strip())]


def merge(existing, incoming):
    """Portierung von TranscriptAssembler.merge."""
    result = []
    # Bestand durch dieselbe Einfuegeregel: die Invariante gilt ohne Vorbedingung.
    for rng, text in existing:
        result = insert(rng, text, result)
    for rng, text, is_final in incoming:
        if is_final:
            result = insert(rng, text, result)
    return sorted(result, key=lambda s: s[0])


def main():
    rng = random.Random(777)
    checks = 0

    for _ in range(20000):
        existing, incoming = [], []
        for i in range(rng.randint(0, 6)):
            s = rng.randint(0, 100_000)
            existing.append(((s, s + rng.randint(1, 20_000)), f"alt{i}"))
        existing = sorted(existing, key=lambda s: s[0])
        for i in range(rng.randint(0, 6)):
            s = rng.randint(0, 100_000)
            incoming.append(((s, s + rng.randint(1, 20_000)), f"neu{i}",
                             rng.random() < 0.8))

        out = merge(existing, incoming)

        # 1. Sortiert nach Medienzeit.
        assert out == sorted(out, key=lambda s: s[0]), "nicht sortiert"
        checks += 1

        # 2. Keine zwei Segmente ueberlappen sich staerker als die Schwelle.
        for i, a in enumerate(out):
            for b in out[i + 1:]:
                lo, hi = max(a[0][0], b[0][0]), min(a[0][1], b[0][1])
                ov = max(0, hi - lo)
                shorter = min(a[0][1] - a[0][0], b[0][1] - b[0][0])
                if shorter:
                    assert ov / shorter < THRESHOLD, f"Dublette geblieben: {a[0]} / {b[0]}"
        checks += 1

        # 3. Vorlaeufige Ergebnisse landen nie im Transkript.
        volatile = {t for _, t, f in incoming if not f}
        assert not (volatile & {t for _, t in out}), "vorlaeufiges Ergebnis persistiert"
        checks += 1

        # 4. Jedes finale eingehende Segment ist entweder enthalten oder wurde
        #    von einem spaeteren finalen Segment verdraengt.
        finals = [(r, t) for r, t, f in incoming if f and t.strip() and r[1] > r[0]]
        if finals:
            assert finals[-1] in out, "letztes finales Ergebnis fehlt"
        checks += 1

    # --- Der Wiederaufnahmefall ---

    # Analyse bricht bei 60 s ab. Wiederaufnahme ab 55 s mit 5 s Ueberlappung.
    before = [((40_000, 48_000), "Satz A"),
              ((48_000, 56_000), "Satz B"),
              ((56_000, 60_000), "Satz C abgeschnitten")]
    after = [((55_000, 60_500), "Satz C vollstaendig", True),
             ((60_500, 68_000), "Satz D", True),
             ((68_000, 75_000), "Satz E", True)]
    out = merge(before, after)
    texts = [t for _, t in out]

    # Der abgeschnittene Satz ist durch die vollstaendige Fassung ersetzt.
    assert "Satz C abgeschnitten" not in texts, texts
    assert "Satz C vollstaendig" in texts
    # Die Saetze davor bleiben unberuehrt.
    assert "Satz A" in texts and "Satz B" in texts
    # Nichts doppelt.
    assert len(texts) == len(set(texts)) == 5, texts
    # Lueckenlos in der Zeit.
    assert out[0][0][0] == 40_000 and out[-1][0][1] == 75_000

    # Abdeckung: Segmente plus eingespeister Bereich.
    ranges = [r for r, _ in out]
    covered = union(ranges, [(0, 75_000)])
    assert total(covered) == 75_000

    checks += 6
    print(f"TranscriptAssembler-Referenz: {checks} Pruefungen bestanden (20000 Zufallsfaelle).")


if __name__ == "__main__":
    main()
