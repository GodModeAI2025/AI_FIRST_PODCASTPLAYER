"""
Referenzmodell zu PodcastAIKnowledge/InterestSuggester.swift.

`InterestOrigin.suggestedBySystem` war von Anfang an im Modell, und die
Oberflaeche hatte einen eigenen Abschnitt dafuer -- erzeugt hat die
Vorschlaege nie jemand. `profile.suggested` war immer leer.

Ein Vorschlagswesen, das der Nutzer nicht nachvollziehen kann, ist keine
Transparenz. Die Regel muss deshalb einfach genug sein, um sie aufschreiben
zu koennen, und sie muss halten, was sie aufschreibt:

  A. Ein Begriff wird nur vorgeschlagen, wenn er in mindestens N
     **verschiedenen** gehoerten Stellen vorkommt. Zehnmal dasselbe Wort in
     einer Stelle ist ein Hinweis auf diese Stelle, nicht auf ein Interesse.
  B. Was schon im Profil steht -- bestaetigt oder vorgeschlagen -- kommt
     nicht noch einmal.
  C. Die Reihenfolge ist zwischen zwei Laeufen gleich.
  D. Ein Vorschlag wirkt nie von selbst.

Geprueft wird gegen ein Brute-Force-Modell, das dieselbe Frage anders
beantwortet: fuer jeden vorkommenden Begriff alle Stellen aufzaehlen.
"""
import random
import sys

STOP_WORDS = {
    "und", "oder", "aber", "denn", "dass", "diese", "dieser", "dieses",
    "eine", "einen", "einem", "einer", "eines", "nicht", "auch", "noch",
    "beim", "durch", "gegen", "ohne", "über", "unter", "zwischen",
    "mein", "meine", "meinen", "mit", "von", "vom", "zum", "zur",
    "the", "and", "for", "with", "from", "that", "this",
}

MIN_MENTIONS = 3
MAX_SUGGESTIONS = 5
MIN_LENGTH = 6


def normalize(text):
    """Portierung von RelevanceScorer.normalize."""
    out, last_space = [], True
    for ch in text.lower():
        if ch.isalpha() or ch.isdigit():
            out.append(ch)
            last_space = False
        elif not last_space:
            out.append(" ")
            last_space = True
    return "".join(out).strip()


def terms_for(interest):
    """Portierung von RelevanceScorer.terms."""
    result = set()
    for raw in [interest["label"]] + interest.get("keywords", []):
        n = normalize(raw)
        if not n:
            continue
        result.add(n)
        for word in n.split(" "):
            if len(word) >= 4 and word not in STOP_WORDS:
                result.add(word)
    return result


def suggest(heard, profile, learning=True):
    """Portierung von InterestSuggester.suggestions."""
    if not learning:
        return []

    covered = set()
    for interest in profile:
        covered |= terms_for(interest)

    mentions = {}
    for item in heard:
        n = normalize(item["text"])
        if not n:
            continue
        seen_here = set()
        for word in n.split(" "):
            if len(word) < MIN_LENGTH:
                continue
            if word in STOP_WORDS or word in covered or word.isdigit():
                continue
            seen_here.add(word)
        for term in seen_here:
            mentions.setdefault(term, set()).add(item["id"])

    candidates = sorted(
        ((term, ids) for term, ids in mentions.items() if len(ids) >= MIN_MENTIONS),
        key=lambda pair: (-len(pair[1]), pair[0]),
    )[:MAX_SUGGESTIONS]
    return sorted(term for term, _ in candidates)


def brute_force(heard, profile, learning=True):
    """Dieselbe Frage, anders beantwortet: je Begriff alle Stellen aufzaehlen."""
    if not learning:
        return []
    covered = set()
    for interest in profile:
        covered |= terms_for(interest)

    vocabulary = set()
    for item in heard:
        vocabulary |= set(normalize(item["text"]).split(" "))

    counted = []
    for term in vocabulary:
        if len(term) < MIN_LENGTH or term in STOP_WORDS or term in covered:
            continue
        if term.isdigit() or not term:
            continue
        places = [item["id"] for item in heard
                  if term in normalize(item["text"]).split(" ")]
        if len(set(places)) >= MIN_MENTIONS:
            counted.append((term, len(set(places))))

    counted.sort(key=lambda pair: (-pair[1], pair[0]))
    return sorted(term for term, _ in counted[:MAX_SUGGESTIONS])


def main():
    rng = random.Random(4711)
    checks = 0
    words = ["datenschutz", "sprachmodelle", "netzbetrieb", "regulierung",
             "agenten", "inferenz", "und", "mit", "apple", "energie",
             "lieferkette", "halbleiter", "ki"]

    for _ in range(20000):
        heard = [{"id": f"e{i}",
                  "text": " ".join(rng.choices(words, k=rng.randint(0, 20)))}
                 for i in range(rng.randint(0, 10))]
        profile = [{"label": rng.choice(words), "keywords": []}
                   for _ in range(rng.randint(0, 3))]

        result = suggest(heard, profile)

        # A/B: identisch zum Brute-Force-Modell.
        checks += 1
        assert result == brute_force(heard, profile), (result, brute_force(heard, profile))

        # C: zwei Laeufe, dasselbe Ergebnis.
        checks += 1
        assert result == suggest(heard, profile), "nicht deterministisch"

        # Reihenfolge der Belege aendert nichts.
        checks += 1
        shuffled = list(heard)
        rng.shuffle(shuffled)
        assert result == suggest(shuffled, profile), "haengt an der Eingabereihenfolge"

        # B: nichts, was schon im Profil steht.
        covered = set()
        for interest in profile:
            covered |= terms_for(interest)
        checks += 1
        assert not (set(result) & covered), "schlaegt Bekanntes vor"

        # Hoechstens die Obergrenze, jeder Begriff lang genug.
        checks += 1
        assert len(result) <= MAX_SUGGESTIONS
        assert all(len(t) >= MIN_LENGTH for t in result)

        # Die Schwelle haelt: jeder Vorschlag kommt in >= MIN_MENTIONS
        # verschiedenen Stellen vor.
        for term in result:
            checks += 1
            places = {item["id"] for item in heard
                      if term in normalize(item["text"]).split(" ")}
            assert len(places) >= MIN_MENTIONS, (term, len(places))

    # D: Abgeschaltetes Lernen schlaegt nichts vor -- auch nicht bei viel Material.
    dense = [{"id": f"e{i}", "text": "datenschutz " * 10} for i in range(20)]
    checks += 1
    assert suggest(dense, [], learning=False) == []

    # Und ein Begriff, der nur in *einer* Stelle steht, kommt nie durch,
    # egal wie oft er dort steht. Das ist der Fall, gegen den die Menge
    # statt einer Zaehlung gebaut ist.
    single = [{"id": "e0", "text": "halbleiter " * 50}]
    checks += 1
    assert suggest(single, []) == []

    print(f"InterestSuggester-Referenz: {checks} Pruefungen bestanden "
          f"(20000 Zufallsfaelle gegen ein Brute-Force-Modell; "
          f"Schwelle, Deduplizierung, Reihenfolge und Lernschalter).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
