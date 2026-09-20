"""
Referenzmodell zu PodcastAISmartFeeds/PersonalEpisodePublisher.swift.

Geprueft werden die Zusagen der Smart Podcast List:
  - Zweimal derselbe Refresh ergibt EINE Ausgabe, nicht zwei (batchKey).
  - Eine Ausgabe enthaelt nie bereits Gehoertes als Kernmaterial.
  - Die virtuelle Zeitachse bildet lueckenlos auf die Originale zurueck.
  - Was in der Ausgabe gehoert wird, gilt danach auch im Original.
  - Das Budget wird nie ueberschritten.
  - Kontextvorlauf zaehlt nicht als neuer Inhalt.
"""
import random
from intervalset_reference import subtracting, intersection, union, stable_hex

CONTEXT_LEAD = 6_000
MIN_SEG = 25_000
MAX_SEG = 600_000
TRANSITION = 800
SEP = "\x1f"


def resolve_unheard(cands, heard, filter_mode="unheardSegments"):
    """Portierung von resolveUnheard."""
    out, reserved = [], {}
    for c in cands:
        mid, rng = c["media"], c["range"]
        if filter_mode == "neverStartedEpisodes" and heard.get(mid):
            continue
        avail = [r for r in subtracting([rng], heard.get(mid, [])) if r[1] - r[0] >= MIN_SEG]
        if reserved.get(mid):
            avail = [r for r in subtracting(avail, reserved[mid]) if r[1] - r[0] >= MIN_SEG]
        if not avail:
            continue
        core = max(avail, key=lambda r: r[1] - r[0])
        if core[1] - core[0] > MAX_SEG:
            core = (core[0], core[0] + MAX_SEG)
        playback = (max(0, core[0] - CONTEXT_LEAD), core[1])
        reserved.setdefault(mid, [])
        reserved[mid] = sorted(set(reserved[mid] + [core]))
        out.append({"c": c, "core": core, "playback": playback})
    return out


def batch_key(unheard):
    """Portierung: reihenfolgeunabhaengig ueber die Kernbereiche."""
    parts = sorted(f"{u['c']['media']}:{u['core'][0]}-{u['core'][1]}" for u in unheard)
    return stable_hex(SEP.join(parts))


def rank(unheard):
    return sorted(unheard, key=lambda u: (-u["c"]["score"],
                                          u["c"].get("published", 0),
                                          u["c"]["id"]))


def apply_budget(ranked, budget, rate=1.0):
    if budget is None:
        return ranked, 0
    sel, used, left = [], 0, 0
    for u in ranked:
        lst = round((u["playback"][1] - u["playback"][0]) / rate)
        trans = 0 if not sel else TRANSITION
        if used + trans + lst <= budget:
            used += trans + lst
            sel.append(u)
        else:
            left += u["core"][1] - u["core"][0]
    return sel, left


def build_segments(sel):
    segs, cursor = [], 0
    for u in sel:
        length = u["playback"][1] - u["playback"][0]
        segs.append({**u, "virtual": (cursor, cursor + length)})
        cursor += length + TRANSITION
    return segs


def original_position(segs, t):
    """Portierung von PersonalEpisode.originalPosition(forVirtual:)."""
    for s in segs:
        if s["virtual"][0] <= t < s["virtual"][1]:
            return s["c"]["media"], s["playback"][0] + (t - s["virtual"][0])
    return None


def ledger_events(segs, vrange):
    """Portierung von PersonalEpisode.ledgerEvents(forVirtualRange:)."""
    out = []
    for s in segs:
        lo, hi = max(s["virtual"][0], vrange[0]), min(s["virtual"][1], vrange[1])
        if lo >= hi:
            continue
        off0 = lo - s["virtual"][0]
        off1 = hi - s["virtual"][0]
        out.append((s["c"]["media"], (s["playback"][0] + off0, s["playback"][0] + off1)))
    return out


def main():
    rng = random.Random(1312)
    checks = 0

    for _ in range(15000):
        media = [f"m{i}" for i in range(rng.randint(1, 4))]
        cands = []
        for i in range(rng.randint(0, 8)):
            s = rng.randint(0, 2_000_000)
            cands.append({"id": f"c{i}", "media": rng.choice(media),
                          "range": (s, s + rng.randint(0, 500_000)),
                          "score": rng.random(), "published": rng.randint(0, 1000)})
        heard = {}
        for m in media:
            if rng.random() < 0.5:
                hs = rng.randint(0, 2_000_000)
                heard[m] = [(hs, hs + rng.randint(0, 400_000))]
        budget = rng.choice([None, 300_000, 1_200_000])

        unheard = resolve_unheard(cands, heard)
        if not unheard:
            continue
        key = batch_key(unheard)
        sel, left = apply_budget(rank(unheard), budget)
        segs = build_segments(sel)

        # 1. Kein Kernmaterial war bereits gehoert.
        for s in segs:
            h = heard.get(s["c"]["media"], [])
            if h:
                assert sum(e - b for b, e in intersection([s["core"]], h)) == 0, \
                    f"Gehoertes im Kern: {s['core']} / {h}"
        checks += 1

        # 2. Kernbereiche derselben Fassung ueberlappen sich nicht.
        for m in media:
            cores = sorted(s["core"] for s in segs if s["c"]["media"] == m)
            for a, b in zip(cores, cores[1:]):
                assert a[1] <= b[0], f"Kernbereiche ueberlappen: {a} / {b}"
        checks += 1

        # 3. Budget eingehalten.
        if budget is not None:
            total = sum(s["playback"][1] - s["playback"][0] for s in segs)
            total += max(0, len(segs) - 1) * TRANSITION
            assert total <= budget, f"Budget ueberschritten: {total} > {budget}"
        checks += 1

        # 4. Virtuelle Zeitachse ist lueckenlos aufsteigend und rueckuebersetzbar.
        for i, s in enumerate(segs):
            assert s["virtual"][1] - s["virtual"][0] == s["playback"][1] - s["playback"][0]
            if i:
                assert segs[i - 1]["virtual"][1] + TRANSITION == s["virtual"][0]
            mid, pos = original_position(segs, s["virtual"][0])
            assert mid == s["c"]["media"] and pos == s["playback"][0]
        checks += 1

        # 5. batchKey ist reihenfolgeunabhaengig -> zweiter Refresh, eine Ausgabe.
        shuffled = cands[:]
        rng.shuffle(shuffled)
        u2 = resolve_unheard(shuffled, heard)
        if {(u["c"]["media"], u["core"]) for u in u2} == {(u["c"]["media"], u["core"]) for u in unheard}:
            assert batch_key(u2) == key, "batchKey haengt an der Reihenfolge"
            checks += 1

        # 6. Die Kernzusage: in der Ausgabe gehoert == im Original gehoert.
        if segs:
            full = (0, segs[-1]["virtual"][1])
            events = ledger_events(segs, full)
            new_heard = dict(heard)
            for mid, r in events:
                new_heard[mid] = union(new_heard.get(mid, []), [r])
            # Nach dem Hoeren liefert derselbe Kandidatenlauf nichts Neues mehr.
            again = resolve_unheard(cands, new_heard)
            remaining_cores = {(u["c"]["media"], u["core"]) for u in again}
            played_cores = {(s["c"]["media"], s["core"]) for s in segs}
            assert not (remaining_cores & played_cores), \
                f"Bereits gehoerte Stelle erneut angeboten: {remaining_cores & played_cores}"
            checks += 1

    # --- Konkrete Produktfaelle ---

    # "Mein KI Update": vier Quellen, 20-Minuten-Budget.
    cands = [
        {"id": "a", "media": "lex", "range": (492_000, 821_000), "score": 0.9, "published": 1},
        {"id": "b", "media": "decoder", "range": (1_880_000, 2_224_000), "score": 0.8, "published": 2},
        {"id": "c", "media": "enbw", "range": (1_022_000, 1_430_000), "score": 0.7, "published": 3},
        {"id": "d", "media": "priv", "range": (2_531_000, 2_798_000), "score": 0.6, "published": 4},
    ]
    u = resolve_unheard(cands, {})
    assert len(u) == 4
    sel, left = apply_budget(rank(u), 1_200_000)
    segs = build_segments(sel)

    # Vier Stellen ergeben 22,9 Minuten und passen nicht in 20 Minuten.
    # Drei kommen hinein, die vierte bleibt sichtbar fuer die naechste Ausgabe
    # -- gekuerzt wird nicht, eine halbe Aussage ist schlechter als keine.
    assert len(segs) == 3, len(segs)
    assert left == cands[3]["range"][1] - cands[3]["range"][0], left
    assert [s["c"]["id"] for s in segs] == ["a", "b", "c"]

    assert segs[0]["virtual"][0] == 0
    # Kontextvorlauf ist enthalten, zaehlt aber nicht als Kern.
    assert segs[0]["playback"][0] == 492_000 - CONTEXT_LEAD
    assert segs[0]["core"][0] == 492_000
    total_core = sum(s["core"][1] - s["core"][0] for s in segs)
    total_play = sum(s["playback"][1] - s["playback"][0] for s in segs)
    assert total_play == total_core + len(segs) * CONTEXT_LEAD

    # Budget wirklich eingehalten.
    spent = total_play + (len(segs) - 1) * TRANSITION
    assert spent <= 1_200_000 and spent > 1_100_000, spent

    # Ohne Budget kommen alle vier hinein.
    all_sel, all_left = apply_budget(rank(u), None)
    assert len(all_sel) == 4 and all_left == 0

    # Zweiter identischer Lauf -> gleicher batchKey -> keine zweite Ausgabe.
    assert batch_key(resolve_unheard(cands, {})) == batch_key(u)

    checks += 3
    print(f"Publisher-Referenz: {checks} Pruefungen bestanden (15000 Zufallsfaelle).")


if __name__ == "__main__":
    main()
