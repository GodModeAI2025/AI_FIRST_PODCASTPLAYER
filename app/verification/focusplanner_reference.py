"""
Referenzmodell zu PodcastAIPlayback/FocusPlanner.swift.

Geprueft werden die Zusagen, die ein Hoerplan gegenueber dem Nutzer macht:
  - Das Zeitbudget wird nie ueberschritten.
  - Abschnitte derselben Fassung ueberlappen sich im Plan nie.
  - Keine vorgeschlagene Fundstelle verschwindet stillschweigend.
  - Die Reihenfolge ist deterministisch, unabhaengig von Dictionary-Iteration.
  - Bereits Gehoertes taucht nicht auf.
"""
import random
from intervalset_reference import normalize, subtracting, intersection

MIN_SEG = 15_000          # minimumSegmentDuration
MAX_SEG = 720_000         # maximumSegmentDuration
PADDING = 8_000           # contextPadding
TRANSITION = 600


def listening(ms, rate):
    return round(ms / rate)


def media_from_listening(ms, rate):
    return round(ms * rate)


def resolve(cands, heard_by_media, skip_heard):
    """Portierung von FocusPlanner.resolve (Zeitanteil)."""
    out, excluded = [], []
    for idx, c in enumerate(cands):
        s, e = c["range"]
        s, e = max(0, s - PADDING), min(c["media_duration"], e + PADDING)
        if e - s > MAX_SEG:
            e = s + MAX_SEG
        if skip_heard:
            heard = heard_by_media.get(c["media"], [])
            rest = [r for r in subtracting([(s, e)], heard) if r[1] - r[0] >= MIN_SEG]
            if not rest:
                excluded.append((c["id"], "alreadyHeard"))
                continue
            s, e = max(rest, key=lambda r: r[1] - r[0])
        if e - s < MIN_SEG:
            excluded.append((c["id"], "alreadyHeard"))
            continue
        out.append({**c, "range": (s, e), "contrib": [(c["id"], (s, e))], "idx": idx})
    return out, excluded


def merge_overlapping(cands):
    """Portierung von FocusPlanner.mergeOverlapping."""
    if len(cands) <= 1:
        return cands
    by_media = {}
    for c in cands:
        by_media.setdefault(c["media"], []).append(c)

    merged = []
    for media in sorted(by_media):                    # Sortierung nur fuer Determinismus des Modells
        group = sorted(by_media[media], key=lambda c: c["range"])
        cur = dict(group[0])
        for nxt in group[1:]:
            # touchesOrOverlaps
            if cur["range"][0] <= nxt["range"][1] and nxt["range"][0] <= cur["range"][1]:
                cur["range"] = (min(cur["range"][0], nxt["range"][0]),
                                max(cur["range"][1], nxt["range"][1]))
                cur["contrib"] = cur["contrib"] + nxt["contrib"]
                cur["idx"] = min(cur["idx"], nxt["idx"])
            else:
                merged.append(cur)
                cur = dict(nxt)
        merged.append(cur)
    return sorted(merged, key=lambda c: (c["idx"], c["range"]))


def apply_budget(cands, budget, rate):
    """Portierung von FocusPlanner.applyBudget."""
    if budget is None:
        return cands, []
    kept, dropped, used = [], [], 0
    for c in cands:
        dur = c["range"][1] - c["range"][0]
        lst = listening(dur, rate)
        trans = 0 if not kept else TRANSITION
        if used + trans + lst <= budget:
            used += trans + lst
            kept.append(c)
            continue
        remaining = max(0, budget - used - trans)
        remaining_media = media_from_listening(remaining, rate)
        if remaining_media >= MIN_SEG:
            t = dict(c)
            t["range"] = (c["range"][0], c["range"][0] + remaining_media)
            still = [(i, r) for i, r in c["contrib"]
                     if r[0] < t["range"][1] and t["range"][0] < r[1]]
            for i, _ in c["contrib"]:
                if i not in {x for x, _ in still}:
                    dropped.append((i, "budgetExhausted"))
            t["contrib"] = still
            if still and c["id"] not in {x for x, _ in still}:
                t["id"] = still[0][0]
            used = budget
            if still:
                kept.append(t)
        else:
            for i, _ in c["contrib"]:
                dropped.append((i, "budgetExhausted"))
    return kept, dropped


def plan(cands, heard_by_media, budget, rate, skip_heard=True):
    resolved, exc1 = resolve(cands, heard_by_media, skip_heard)
    merged = merge_overlapping(resolved)
    kept, exc2 = apply_budget(merged, budget, rate)
    return kept, exc1 + exc2


def main():
    rng = random.Random(90210)
    checks = 0

    for _ in range(20000):
        n = rng.randint(0, 7)
        media_pool = [f"m{i}" for i in range(rng.randint(1, 3))]
        cands = []
        for i in range(n):
            s = rng.randint(0, 3_000_000)
            cands.append({
                "id": f"e{i}",
                "media": rng.choice(media_pool),
                "range": (s, s + rng.randint(0, 400_000)),
                "media_duration": 3_600_000,
            })
        heard = {}
        for m in media_pool:
            if rng.random() < 0.5:
                hs = rng.randint(0, 3_000_000)
                heard[m] = normalize([(hs, hs + rng.randint(0, 600_000))])
        budget = rng.choice([None, 300_000, 1_200_000, 60_000])
        rate = rng.choice([1.0, 1.5, 2.0])

        kept, excluded = plan(cands, heard, budget, rate)

        # 1. Budget wird nie ueberschritten.
        if budget is not None:
            total = sum(listening(c["range"][1] - c["range"][0], rate) for c in kept)
            total += max(0, len(kept) - 1) * TRANSITION
            assert total <= budget, f"Budget ueberschritten: {total} > {budget}"
        checks += 1

        # 2. Abschnitte derselben Fassung ueberlappen sich nicht.
        for m in media_pool:
            rs = sorted(c["range"] for c in kept if c["media"] == m)
            for a, b in zip(rs, rs[1:]):
                assert a[1] <= b[0], f"Ueberlappung im Plan: {a} / {b}"
        checks += 1

        # 3. Keine Fundstelle verschwindet stillschweigend.
        accounted = set()
        for c in kept:
            accounted.update(i for i, _ in c["contrib"])
        accounted.update(i for i, _ in excluded)
        proposed = {c["id"] for c in cands}
        assert accounted == proposed, f"Fundstellen verloren: {proposed - accounted}"
        checks += 1

        # 4. Bereits Gehoertes taucht nicht auf.
        for c in kept:
            h = heard.get(c["media"], [])
            if h:
                overlap = intersection([c["range"]], h)
                covered = sum(e - s for s, e in overlap)
                assert covered == 0, f"Gehoertes im Plan: {c['range']} vs {h}"
        checks += 1

        # 5. Jeder Abschnitt ist lang genug.
        for c in kept:
            assert c["range"][1] - c["range"][0] >= MIN_SEG, "Abschnitt zu kurz"
        checks += 1

        # 6. Determinismus: gleiche Eingabe, gleiches Ergebnis.
        kept2, excluded2 = plan(cands, heard, budget, rate)
        assert [c["range"] for c in kept] == [c["range"] for c in kept2], "nicht deterministisch"
        checks += 1

    # --- Konkrete Produktfaelle ---

    # "Spiel mir die drei Stellen zum Datenschutz" -> drei Spruenge, Reihenfolge des Vorschlags.
    cands = [
        {"id": "a", "media": "m1", "range": (733_000, 902_000), "media_duration": 5_400_000},
        {"id": "b", "media": "m1", "range": (2_091_000, 2_290_000), "media_duration": 5_400_000},
        {"id": "c", "media": "m1", "range": (4_323_000, 4_582_000), "media_duration": 5_400_000},
    ]
    kept, exc = plan(cands, {}, None, 1.0)
    assert [c["id"] for c in kept] == ["a", "b", "c"] and not exc

    # Zwei dicht beieinander liegende Stellen werden zu einer -- kein Sprung im selben Gedanken.
    near = [
        {"id": "a", "media": "m1", "range": (600_000, 660_000), "media_duration": 3_600_000},
        {"id": "b", "media": "m1", "range": (670_000, 730_000), "media_duration": 3_600_000},
    ]
    kept, _ = plan(near, {}, None, 1.0)
    assert len(kept) == 1 and [i for i, _ in kept[0]["contrib"]] == ["a", "b"], kept
    assert kept[0]["range"] == (592_000, 738_000)

    # 20-Minuten-Budget bei 1,5-facher Geschwindigkeit fasst mehr Medienzeit.
    many = [{"id": f"e{i}", "media": f"m{i}", "range": (0, 600_000), "media_duration": 3_600_000}
            for i in range(6)]
    kept_1x, _ = plan(many, {}, 1_200_000, 1.0)
    kept_15x, _ = plan(many, {}, 1_200_000, 1.5)
    media_1x = sum(c["range"][1] - c["range"][0] for c in kept_1x)
    media_15x = sum(c["range"][1] - c["range"][0] for c in kept_15x)
    assert media_15x > media_1x, (media_1x, media_15x)

    checks += 4
    print(f"FocusPlanner-Referenz: {checks} Pruefungen bestanden (20000 Zufallsfaelle).")


if __name__ == "__main__":
    main()
