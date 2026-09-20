"""
Referenzmodell zu PodcastAICore/IntervalSet.swift.

Der Algorithmus ist Zeile fuer Zeile aus dem Swift-Code portiert. Getestet wird
gegen ein Brute-Force-Modell (Menge einzelner Millisekunden), das offensichtlich
korrekt, aber unbrauchbar langsam ist. Stimmen beide auf zufaelligen Eingaben
ueberein, ist die Intervalllogik belegt -- unabhaengig davon, dass hier kein
Swift-Compiler verfuegbar ist.
"""
import random


# ---------- Portierung aus IntervalSet.swift ----------

def normalize(ranges):
    """Entspricht IntervalSet.normalize."""
    s = sorted((r for r in ranges if r[1] > r[0]))
    if not s:
        return []
    out, cur = [], s[0]
    for r in s[1:]:
        if r[0] <= cur[1]:                      # ueberlappt oder grenzt an
            if r[1] > cur[1]:
                cur = (cur[0], r[1])
            # sonst vollstaendig enthalten -> verwerfen
        else:
            out.append(cur)
            cur = r
    out.append(cur)
    return out


def union(a, b):
    return normalize(a + b)


def subtracting(a, b):
    """Entspricht IntervalSet.subtracting."""
    if not b or not a:
        return a
    result = []
    for start, end in a:
        cursor = start
        for h0, h1 in b:
            if h1 <= cursor:
                continue
            if h0 >= end:
                break
            if h0 > cursor:
                result.append((cursor, min(h0, end)))
            cursor = max(cursor, h1)
            if cursor >= end:
                break
        if cursor < end:
            result.append((cursor, end))
    return normalize(result)


def intersection(a, b):
    """Entspricht IntervalSet.intersection."""
    if not a or not b:
        return []
    result = []
    i = j = 0
    while i < len(a) and j < len(b):
        lo, hi = max(a[i][0], b[j][0]), min(a[i][1], b[j][1])
        if lo < hi:
            result.append((lo, hi))
        if a[i][1] < b[j][1]:
            i += 1
        else:
            j += 1
    return normalize(result)


def total(a):
    return sum(e - s for s, e in a)


def coverage(a, rng):
    if rng[1] <= rng[0]:
        return 1.0
    return total(intersection(a, [rng])) / (rng[1] - rng[0])


# ---------- Brute-Force-Modell ----------

def to_set(ranges):
    out = set()
    for s, e in ranges:
        out.update(range(s, e))
    return out


def from_set(ms):
    """Millisekundenmenge zurueck in minimale sortierte Intervalle."""
    if not ms:
        return []
    xs = sorted(ms)
    out, start, prev = [], xs[0], xs[0]
    for x in xs[1:]:
        if x != prev + 1:
            out.append((start, prev + 1))
            start = x
        prev = x
    out.append((start, prev + 1))
    return out


# ---------- Eigenschaften ----------

def invariants_hold(a):
    """Normalform: sortiert, disjunkt, nicht leer, keine Beruehrungen."""
    for s, e in a:
        if e <= s:
            return False, "leeres Intervall"
    for i in range(len(a) - 1):
        if a[i][1] >= a[i + 1][0]:
            return False, "nicht disjunkt oder beruehrend"
    return True, ""


def rand_ranges(rng, n_max=6, span=80):
    n = rng.randint(0, n_max)
    out = []
    for _ in range(n):
        s = rng.randint(0, span)
        e = s + rng.randint(0, 25)
        out.append((s, e))
    return out


def main():
    rng = random.Random(20260920)
    checks = 0
    for _ in range(30000):
        A, B = rand_ranges(rng), rand_ranges(rng)
        na, nb = normalize(A), normalize(B)
        sa, sb = to_set(A), to_set(B)

        for name, got, want in (
            ("normalize", na, from_set(sa)),
            ("union", union(A, B), from_set(sa | sb)),
            ("subtracting", subtracting(na, nb), from_set(sa - sb)),
            ("intersection", intersection(na, nb), from_set(sa & sb)),
        ):
            assert got == want, f"{name}: {A} / {B}\n got {got}\n want {want}"
            ok, why = invariants_hold(got)
            assert ok, f"{name} verletzt Normalform ({why}): {got}"
            checks += 1

        # Idempotenz: nochmal vereinigen aendert nichts.
        assert union(na, na) == na, f"union nicht idempotent: {na}"
        # totalDuration stimmt mit der Millisekundenmenge ueberein.
        assert total(na) == len(sa), f"totalDuration falsch: {na}"
        # remainder(of:) plus intersection ergibt wieder das ganze Intervall.
        if nb:
            r = nb[0]
            rest = subtracting([r], na)
            inter = intersection(na, [r])
            assert total(rest) + total(inter) == r[1] - r[0], "remainder + intersection != range"
        checks += 3

    # Die Produktaussage explizit: gehoert im persoenlichen Update == gehoert im Original.
    ledger = normalize([(600_000, 900_000)])                 # 10:00-15:00 im AI-Update gehoert
    episode = (0, 3_600_000)                                  # Originalfolge, 60 Minuten
    unheard = subtracting([episode], ledger)
    assert unheard == [(0, 600_000), (900_000, 3_600_000)], unheard
    assert abs(coverage(ledger, (600_000, 900_000)) - 1.0) < 1e-12
    assert coverage(ledger, (0, 1_200_000)) == 0.25
    checks += 3

    print(f"IntervalSet-Referenz: {checks} Pruefungen bestanden (30000 Zufallsfaelle).")




# ---------- Referenz zu StableDigest (Identifiers.swift) ----------

def fnv1a64(data: bytes, offset_basis: int) -> int:
    h = offset_basis
    for b in data:
        h ^= b
        h = (h * 0x00000100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def stable_hex(s: str) -> str:
    d = s.encode("utf-8")
    return "%016x%016x" % (fnv1a64(d, 0xCBF29CE484222325),
                           fnv1a64(d, 0x9DCF9B0D1E7A3D41))


def check_digest():
    # Determinismus
    assert stable_hex("abc") == stable_hex("abc")
    # Laenge
    assert all(len(stable_hex(x)) == 32 for x in ["", "a", "x" * 5000, "üäö"])
    # Kollisionsfreiheit auf realistischen Schluesseln
    keys = [f"https://example.com/feed{i}/episode-{j}" for i in range(200) for j in range(200)]
    seen = {}
    for k in keys:
        h = stable_hex(k)
        assert h not in seen, f"Kollision: {k} vs {seen[h]}"
        seen[h] = k
    # Trennzeichen verhindert Mehrdeutigkeit: ["ab","c"] != ["a","bc"]
    sep = "\x1f"
    assert stable_hex(sep.join(["ab", "c"])) != stable_hex(sep.join(["a", "bc"]))
    # ofUnordered ist sortierungsunabhaengig, ofOrdered nicht
    assert stable_hex(sep.join(sorted(["b", "a"]))) == stable_hex(sep.join(sorted(["a", "b"])))
    assert stable_hex(sep.join(["b", "a"])) != stable_hex(sep.join(["a", "b"]))
    print(f"StableDigest-Referenz: {len(keys)} Schluessel kollisionsfrei, Determinismus und Trennzeichen belegt.")


if __name__ == "__main__":
    main()
    check_digest()
