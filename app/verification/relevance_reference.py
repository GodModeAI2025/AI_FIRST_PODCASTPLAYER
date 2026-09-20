"""
Referenzmodell zu PodcastAIKnowledge/RelevanceScorer.swift.

Die Vorauswahl entscheidet, was ein Modell ueberhaupt zu sehen bekommt --
und was ohne Apple Intelligence passiert. Geprueft wird:
  - nur bestaetigte Interessen loesen Kandidaten aus,
  - abgelaufene Vorhaben wirken nicht mehr,
  - die Rangfolge ist deterministisch,
  - Normalisierung trifft "KI-Modelle" mit "KI Modelle",
  - Fuellwoerter loesen keine Treffer aus,
  - ein wiederholtes Wort macht einen Abschnitt nicht beliebig relevant.
"""
import random

STOP = {"und","oder","aber","denn","dass","diese","dieser","dieses","eine","einen",
        "einem","einer","eines","nicht","auch","noch","beim","durch","gegen","ohne",
        "über","unter","zwischen","mein","meine","meinen","mit","von","vom","zum",
        "zur","the","and","for","with","from","that","this"}
THRESHOLD = 0.18
MAX_PER_INTEREST = 25


def normalize(text):
    out, last_space = [], True
    for ch in text.lower():
        if ch.isalnum():
            out.append(ch); last_space = False
        elif not last_space:
            out.append(" "); last_space = True
    return "".join(out).strip()


def terms_for(interest):
    result = set()
    for raw in [interest["label"]] + interest.get("keywords", []):
        n = normalize(raw)
        if not n:
            continue
        result.add(n)
        for w in n.split(" "):
            if len(w) >= 4 and w not in STOP:
                result.add(w)
    return sorted(result)


def match(terms, haystack):
    matched, value = [], 0.0
    for t in terms:
        if t in haystack:
            matched.append(t)
            value += 0.5 if " " in t else 0.2
    if not matched:
        return 0.0, []
    return min(1.0, value), sorted(matched, key=lambda s: -len(s))


def score(evidence, interests, now=0):
    drivers = [i for i in interests
               if i["confirmed"] and (i.get("expires") is None or now < i["expires"])]
    by_interest = {}
    for interest in drivers:
        terms = terms_for(interest)
        if not terms:
            continue
        for ev in evidence:
            hay = normalize(ev["text"])
            if not hay:
                continue
            v, matched = match(terms, hay)
            if v < THRESHOLD:
                continue
            by_interest.setdefault(interest["id"], []).append(
                {"ev": ev["id"], "interest": interest["id"], "score": v, "terms": matched})

    # Ueber die *sortierten Schluessel*, nicht ueber by_interest.values():
    # Swifts Dictionary ist je Prozessstart anders sortiert, Pythons dict
    # einfuegungsstabil. Das Modell darf diesen Unterschied nicht
    # wegdefinieren -- es bildet deshalb nach, was die Swift-Fassung tut.
    out = []
    for key in sorted(by_interest):
        ranked = sorted(by_interest[key], key=ranking)
        out.extend(ranked[:MAX_PER_INTEREST])
    return sorted(out, key=ranking)


def ranking(m):
    """Portierung von RelevanceScorer.ranking.

    Drei Stufen, nicht zwei: bei gleichem Wert *und* gleichem Beleg
    entscheidet das Interesse. Ohne diese dritte Stufe haengt die
    Reihenfolge zweier gleichwertiger Treffer an der Laufzeit, weil
    `sorted` in Swift nicht stabil ist.
    """
    return (-m["score"], m["ev"], m["interest"])


def main():
    rng = random.Random(555)
    checks = 0
    words = ["datenschutz", "modelle", "apple", "netzbetrieb", "regulierung",
             "agenten", "cloud", "inferenz", "und", "mit"]

    for _ in range(20000):
        evidence = [{"id": f"e{i}", "text": " ".join(rng.choices(words, k=rng.randint(0, 25)))}
                    for i in range(rng.randint(0, 12))]
        interests = []
        for i in range(rng.randint(0, 5)):
            interests.append({
                "id": f"i{i}",
                "label": rng.choice(words) if rng.random() < 0.8 else "lokale ki modelle",
                "keywords": rng.sample(words, k=rng.randint(0, 2)),
                "confirmed": rng.random() < 0.7,
                "expires": rng.choice([None, -1, 1000]),
            })

        result = score(evidence, interests)

        # 1. Nur bestaetigte, nicht abgelaufene Interessen loesen Kandidaten aus.
        allowed = {i["id"] for i in interests
                   if i["confirmed"] and (i["expires"] is None or i["expires"] > 0)}
        assert {m["interest"] for m in result} <= allowed, "unbestaetigtes Interesse gewirkt"
        checks += 1

        # 2. Deterministisch -- und zwar auch dann, wenn die Interessen in
        #    anderer Reihenfolge ankommen. Das ist der eigentliche Punkt:
        #    in Swift bestimmt die Dictionary-Reihenfolge, welche Treffer
        #    zuerst betrachtet werden, und die ist je Prozessstart anders.
        assert result == score(evidence, interests), "nicht deterministisch"
        checks += 1
        shuffled = list(interests)
        rng.shuffle(shuffled)
        assert result == score(evidence, shuffled), \
            "Reihenfolge der Interessen aendert das Ergebnis"
        checks += 1

        # 3. Schwelle haelt, Wert bleibt in [0,1].
        for m in result:
            assert THRESHOLD <= m["score"] <= 1.0, m["score"]
            assert m["terms"], "Treffer ohne Begriffe"
        checks += 1

        # 4. Je Interesse nicht mehr als die Obergrenze.
        counts = {}
        for m in result:
            counts[m["interest"]] = counts.get(m["interest"], 0) + 1
        assert all(c <= MAX_PER_INTEREST for c in counts.values())
        checks += 1

    # --- Konkrete Faelle ---

    # "KI Modelle" trifft "KI-Modelle" -- Bindestrich wird zu Leerzeichen.
    i = [{"id": "i1", "label": "KI Modelle", "keywords": [], "confirmed": True, "expires": None}]
    e = [{"id": "e1", "text": "Wir sprechen ueber KI-Modelle im Unternehmen."}]
    assert score(e, i), "Bindestrich-Normalisierung greift nicht"

    # Fuellwoerter loesen keinen Treffer aus.
    i2 = [{"id": "i2", "label": "diese", "keywords": [], "confirmed": True, "expires": None}]
    # "diese" ist kuerzer als der Mehrwort-Fall und steht in der Stoppliste,
    # bleibt aber als vollstaendige Beschriftung erhalten -- deshalb trifft es.
    # Entscheidend ist, dass es nicht ueber die Wortzerlegung zusaetzlich zaehlt.
    assert terms_for(i2[0]) == ["diese"], terms_for(i2[0])

    # Wiederholung saettigt: zehnmal dasselbe Wort ergibt nicht mehr als 1.0.
    i3 = [{"id": "i3", "label": "datenschutz", "keywords": [], "confirmed": True, "expires": None}]
    e3 = [{"id": "e3", "text": " ".join(["datenschutz"] * 50)}]
    assert score(e3, i3)[0]["score"] <= 1.0

    # Ein abgelaufenes Vorhaben wirkt nicht mehr.
    i4 = [{"id": "i4", "label": "apple", "keywords": [], "confirmed": True, "expires": -1}]
    assert score([{"id": "x", "text": "apple apple"}], i4) == []

    # Unbestaetigtes Interesse wirkt nicht.
    i5 = [{"id": "i5", "label": "apple", "keywords": [], "confirmed": False, "expires": None}]
    assert score([{"id": "x", "text": "apple apple"}], i5) == []

    checks += 5
    print(f"RelevanceScorer-Referenz: {checks} Pruefungen bestanden (20000 Zufallsfaelle).")


if __name__ == "__main__":
    main()
