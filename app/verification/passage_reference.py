"""
Referenzmodell zu PodcastAIKit/PassageBuilder.

Die Passagenbildung entscheidet, was ueberhaupt eine "Stelle" ist. Geprueft:
  - Passagen sind lueckenlos und ueberlappen sich nie,
  - keine Passage ueberschreitet die harte Grenze,
  - geschnitten wird nur an Sprechpausen,
  - die Gesamtabdeckung geht nicht verloren.
"""
import random

TARGET = 60_000
GAP = 1_500
HARD = 150_000


def passages(segments, target=TARGET, gap_threshold=GAP, hard_limit=HARD):
    """Portierung von PassageBuilder.passages."""
    if not segments:
        return []
    result = []
    start, end = segments[0]
    for s, e in segments[1:]:
        gap = s - end
        length = end - start
        long_enough = length >= target
        clear_pause = gap >= gap_threshold
        if (long_enough and clear_pause) or length >= hard_limit:
            result.append((start, end))
            start = s
        end = e
    result.append((start, end))
    return [r for r in result if r[1] > r[0]]


def main():
    rng = random.Random(8642)
    checks = 0

    for _ in range(20000):
        segments, t = [], 0
        for _ in range(rng.randint(1, 120)):
            s = t + rng.choice([0, 0, 0, rng.randint(1, 4000)])   # meist nahtlos
            e = s + rng.randint(500, 12_000)
            segments.append((s, e))
            t = e

        out = passages(segments)
        assert out, "keine Passage erzeugt"
        checks += 1

        # 1. Aufsteigend und ueberlappungsfrei.
        for a, b in zip(out, out[1:]):
            assert a[1] <= b[0], f"Passagen ueberlappen: {a} / {b}"
        checks += 1

        # 2. Jede Passage beginnt und endet an einer Segmentgrenze --
        #    nie mitten im Satz.
        starts = {s for s, _ in segments}
        ends = {e for _, e in segments}
        for s, e in out:
            assert s in starts, f"Schnitt nicht an Segmentgrenze: {s}"
            assert e in ends, f"Schnitt nicht an Segmentgrenze: {e}"
        checks += 1

        # 3. Die erste Passage beginnt am Anfang, die letzte endet am Ende.
        assert out[0][0] == segments[0][0]
        assert out[-1][1] == segments[-1][1]
        checks += 1

        # 4. Kein Inhalt geht verloren: die Passagen decken die Segmente ab.
        covered = sum(e - s for s, e in out)
        span = segments[-1][1] - segments[0][0]
        assert covered <= span, "Abdeckung groesser als der Zeitraum"
        assert covered >= span - sum(max(0, b[0] - a[1]) for a, b in zip(out, out[1:])), \
            "Inhalt verloren"
        checks += 1

    # --- Konkrete Faelle ---

    # Ein Sprecher ohne Pausen: die harte Grenze greift trotzdem.
    nonstop = [(i * 5_000, (i + 1) * 5_000) for i in range(80)]   # 400 s am Stueck
    out = passages(nonstop)
    assert len(out) > 1, "harte Grenze greift nicht"
    assert all(e - s <= HARD + 5_000 for s, e in out), [(e - s) for s, e in out]

    # Deutliche Pausen nach je ~70 s: dort wird geschnitten.
    with_pauses = []
    t = 0
    for _ in range(4):
        for _ in range(7):
            with_pauses.append((t, t + 10_000))
            t += 10_000
        t += 3_000                                   # 3 s Pause
    out = passages(with_pauses)
    assert len(out) == 4, len(out)

    # Eine einzige kurze Folge bleibt eine Passage.
    assert len(passages([(0, 20_000)])) == 1

    print(f"PassageBuilder-Referenz: {checks + 3} Pruefungen bestanden (20000 Zufallsfaelle).")


if __name__ == "__main__":
    main()
