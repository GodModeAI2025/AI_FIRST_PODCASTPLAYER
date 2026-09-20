"""
Referenzmodell zu PodcastAICore/ListeningLedger.swift.

Prueft die Zusagen, die das Produkt gegenueber dem Nutzer macht:
  - Gehoert bleibt gehoert, egal ueber welchen Wiedergabeweg.
  - Ueberspringen macht Gehoertes nicht rueckgaengig.
  - Zusammenfuehren zweier Geraete ist kommutativ und idempotent.
  - Zu kurze Restfragmente loesen keine persoenliche Ausgabe aus.
"""
import random
from intervalset_reference import normalize, union, subtracting, total


class State:
    """Portierung von MediaListeningState."""

    def __init__(self):
        self.heard = []
        self.skipped = []

    def apply(self, rng, kind):
        if rng[1] <= rng[0]:
            return
        if kind in ("played", "markedKnown"):
            self.heard = union(self.heard, [rng])
            self.skipped = subtracting(self.skipped, [rng])
        elif kind == "skipped":
            self.skipped = union(self.skipped, subtracting([rng], self.heard))

    def unheard(self, rng, minimum=0):
        rest = subtracting([rng], self.heard)
        return [r for r in rest if r[1] - r[0] >= minimum]

    def snapshot(self):
        return (tuple(self.heard), tuple(self.skipped))


def merged(a: State, b: State) -> State:
    """Portierung von ListeningLedger.merged(with:)."""
    out = State()
    out.heard, out.skipped = list(a.heard), list(a.skipped)
    for r in b.heard:
        out.apply(r, "played")
    for r in b.skipped:
        out.apply(r, "skipped")
    return out


def replay(events) -> State:
    s = State()
    for rng, kind in events:
        s.apply(rng, kind)
    return s


def main():
    rng = random.Random(4711)
    kinds = ["played", "skipped", "markedKnown"]
    checks = 0

    for _ in range(20000):
        def rand_events(n):
            out = []
            for _ in range(n):
                s = rng.randint(0, 100)
                out.append(((s, s + rng.randint(0, 30)), rng.choice(kinds)))
            return out

        ev_a, ev_b = rand_events(rng.randint(0, 5)), rand_events(rng.randint(0, 5))
        A, B = replay(ev_a), replay(ev_b)

        # Invariante: heard und skipped sind immer disjunkt.
        for S in (A, B):
            from intervalset_reference import intersection
            assert not intersection(S.heard, S.skipped), \
                f"heard und skipped ueberlappen: {S.heard} / {S.skipped}"
        checks += 2

        # Idempotenz: dieselben Ereignisse nochmal anwenden aendert nichts.
        again = replay(ev_a + ev_a)
        assert again.snapshot() == A.snapshot(), "Ereignisse nicht idempotent"
        checks += 1

        # Kommutativitaet des Zusammenfuehrens.
        m1, m2 = merged(A, B), merged(B, A)
        assert m1.heard == m2.heard, f"merge nicht kommutativ (heard): {m1.heard} vs {m2.heard}"
        checks += 1

        # Idempotenz des Zusammenfuehrens.
        assert merged(m1, B).heard == m1.heard, "merge nicht idempotent"
        checks += 1

        # Gehoertes geht beim Zusammenfuehren nie verloren.
        assert total(subtracting(A.heard, m1.heard)) == 0, "merge verliert Gehoertes"
        assert total(subtracting(B.heard, m1.heard)) == 0, "merge verliert Gehoertes"
        checks += 2

    # --- Die Produktzusagen explizit ---

    # 1. Im AI-Update gehoert -> in der Originalfolge nicht mehr neu.
    s = State()
    s.apply((600_000, 900_000), "played")           # via smartFeedEpisode
    assert s.unheard((0, 3_600_000)) == [(0, 600_000), (900_000, 3_600_000)]

    # 2. Und umgekehrt: im Original gehoert -> nicht mehr im Update.
    s2 = State()
    s2.apply((0, 1_200_000), "played")              # via originalEpisode, 0-20 Min
    candidate = (600_000, 900_000)                   # Kandidat fuers Update
    assert s2.unheard(candidate) == [], "Kandidat haette unterdrueckt werden muessen"

    # 3. Ueberspringen macht Gehoertes nicht rueckgaengig.
    s3 = State()
    s3.apply((0, 60_000), "played")
    s3.apply((0, 60_000), "skipped")
    assert s3.heard == [(0, 60_000)] and s3.skipped == []

    # 4. Zu kurze Reste loesen keine Ausgabe aus.
    s4 = State()
    s4.apply((0, 295_000), "played")                 # 0:00-4:55 gehoert
    rest = s4.unheard((0, 300_000), minimum=20_000)  # 5 Sek Rest, Schwelle 20 Sek
    assert rest == [], f"Fragment haette verworfen werden muessen: {rest}"

    # 5. Ein echter Rest bleibt erhalten.
    s5 = State()
    s5.apply((0, 240_000), "played")                 # 0:00-4:00
    assert s5.unheard((0, 300_000), minimum=20_000) == [(240_000, 300_000)]

    checks += 5
    print(f"ListeningLedger-Referenz: {checks} Pruefungen bestanden (20000 Zufallsfaelle).")


if __name__ == "__main__":
    main()
