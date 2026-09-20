"""
Referenzmodell zu PodcastAIIntelligence/EvidenceSelection.swift.

Das ist die Sicherheitsgrenze zwischen Modellausgabe und App-Zustand.
Geprueft wird gegen boesartige und kaputte Modellantworten:
  - erfundene Verweise werden verworfen, nicht korrigiert,
  - Wiederholungen entfernt,
  - die Hoechstzahl haelt,
  - jede zurueckgegebene Kennung stammt aus der vorgelegten Liste,
  - Begruendungen tragen keine Steuerzeichen in die Oberflaeche.
"""
import random
import string

MAX_SELECTIONS = 12
MAX_RATIONALE = 280


def sanitize(text, limit=MAX_RATIONALE):
    """Portierung von EvidenceSelectionValidator.sanitize."""
    cleaned = "".join(" " if (ord(c) < 32 or ord(c) == 127) else c for c in text)
    collapsed = " ".join(cleaned.split())
    return collapsed if len(collapsed) <= limit else collapsed[:limit] + "…"


def validate(raw_indices, raw_rationales, candidates):
    """Portierung von EvidenceSelectionValidator.validate."""
    by_index = {c["index"]: c for c in candidates}
    audit = {"outOfRange": [], "duplicates": [], "truncated": 0}
    seen, ids, rationales = set(), [], {}

    for idx in raw_indices:
        c = by_index.get(idx)
        if c is None:
            audit["outOfRange"].append(idx)
            continue
        if idx in seen:
            audit["duplicates"].append(idx)
            continue
        seen.add(idx)
        if len(ids) >= MAX_SELECTIONS:
            audit["truncated"] += 1
            continue
        ids.append(c["id"])
        if idx in raw_rationales:
            s = sanitize(raw_rationales[idx])
            if s:
                rationales[c["id"]] = s
    return ids, rationales, audit


def main():
    rng = random.Random(31337)
    checks = 0

    for _ in range(30000):
        n = rng.randint(0, 40)
        candidates = [{"index": i + 1, "id": f"ev-{i}", "excerpt": "x"} for i in range(n)]
        valid_ids = {c["id"] for c in candidates}

        # Boesartige Modellantwort: gueltige, ungueltige, negative, riesige,
        # doppelte Verweise, in zufaelliger Reihenfolge.
        raw = []
        for _ in range(rng.randint(0, 30)):
            raw.append(rng.choice([
                rng.randint(1, max(n, 1)),       # evtl. gueltig
                rng.randint(-100, 0),            # negativ
                rng.randint(n + 1, n + 1000),    # ausserhalb
                0,                               # Nullindex
            ]))
        rationales = {i: "".join(rng.choice(string.printable) for _ in range(rng.randint(0, 400)))
                      for i in set(raw)}

        ids, rats, audit = validate(raw, rationales, candidates)

        # 1. Jede zurueckgegebene Kennung stammt aus der Liste. Nie erfunden.
        assert set(ids) <= valid_ids, f"erfundene Kennung: {set(ids) - valid_ids}"
        checks += 1

        # 2. Keine Wiederholung.
        assert len(ids) == len(set(ids)), "Wiederholung durchgelassen"
        checks += 1

        # 3. Hoechstzahl haelt.
        assert len(ids) <= MAX_SELECTIONS, f"zu viele: {len(ids)}"
        checks += 1

        # 4. Jeder ungueltige Verweis ist protokolliert, keiner stillschweigend weg.
        accounted = len(ids) + len(audit["outOfRange"]) + len(audit["duplicates"]) + audit["truncated"]
        assert accounted == len(raw), f"Verweise verloren: {accounted} vs {len(raw)}"
        checks += 1

        # 5. Begruendungen tragen keine Steuerzeichen und halten die Laenge.
        for r in rats.values():
            assert all(ord(c) >= 32 and ord(c) != 127 for c in r), "Steuerzeichen durchgelassen"
            assert len(r) <= MAX_RATIONALE + 1, f"zu lang: {len(r)}"
            assert r == r.strip(), "nicht getrimmt"
        checks += 1

        # 6. Reihenfolge der Auswahl entspricht der Modellantwort.
        expected = []
        seen = set()
        for i in raw:
            if 1 <= i <= n and i not in seen and len(expected) < MAX_SELECTIONS:
                seen.add(i)
                expected.append(f"ev-{i - 1}")
        assert ids == expected, f"Reihenfolge verletzt: {ids} vs {expected}"
        checks += 1

    # --- Konkrete Angriffsfaelle ---

    cands = [{"index": i + 1, "id": f"ev-{i}", "excerpt": "x"} for i in range(3)]

    # Modell erfindet eine Kennung statt einer Nummer -> nichts kommt durch.
    ids, _, audit = validate([99, 100, -1], {}, cands)
    assert ids == [] and len(audit["outOfRange"]) == 3

    # Modell gibt alles zurueck, um jede Relevanzaussage zu entwerten.
    big = [{"index": i + 1, "id": f"ev-{i}", "excerpt": "x"} for i in range(40)]
    ids, _, audit = validate(list(range(1, 41)), {}, big)
    assert len(ids) == MAX_SELECTIONS and audit["truncated"] == 40 - MAX_SELECTIONS

    # Begruendung versucht, Zeilenumbrueche und Steuerzeichen einzuschleusen.
    ids, rats, _ = validate([1], {1: "Zeile eins\n\r\tZeile zwei\x00\x07"}, cands)
    assert rats["ev-0"] == "Zeile eins Zeile zwei", repr(rats["ev-0"])

    # Leere Kandidatenliste: jede Antwort ist ungueltig.
    ids, _, audit = validate([1, 2, 3], {}, [])
    assert ids == [] and len(audit["outOfRange"]) == 3

    checks += 4
    print(f"EvidenceSelection-Referenz: {checks} Pruefungen bestanden (30000 Zufallsfaelle).")


if __name__ == "__main__":
    main()
