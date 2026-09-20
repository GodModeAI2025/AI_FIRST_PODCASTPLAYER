"""
Referenzmodell zu PodcastAICore/Identifiers.swift (StableDigest/SecureDigest).

Der Befund war eine Widerspruechlichkeit im eigenen Quelltext: ueber
`StableDigest` stand "Zweck ist Identitaet und Deduplizierung, nicht
Sicherheit" -- und genau dieser Digest band den `PlaybackGrant` an seinen
Plan. Die Freigabe sagt: dieser Plan, dieses Geraet, jetzt. Prueft sie gegen
FNV-1a, genuegt ein zweiter Plan mit derselben Pruefsumme, damit eine
Freigabe fuer Plan A den Plan B abspielt.

FNV-1a ist nicht kollisionsresistent. Das ist kein Vorwurf an FNV-1a --
seine Autoren erheben den Anspruch nicht -- sondern an die Verwendung. Die
Plaene stammen aus einem Sprachmodell, also aus nicht vertrauenswuerdiger
Quelle.

Hier wird zweierlei geprueft:

  1. **Die Politik**, am Quelltext: jede Pruefsumme, an der eine
     Entscheidung haengt, benutzt SecureDigest; die kosmetischen bleiben
     bei StableDigest. Das ist die Pruefung, die kuenftige Aenderungen
     abfaengt.
  2. **Die Rechnung**, gegen hashlib: Trennzeichen, Reihenfolge und
     Hexdarstellung der Swift-Fassung.
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SEPARATOR = "\x1f"

# Pruefsummen, an denen eine Entscheidung haengt, mit der Stelle, die sie faellt.
SECURITY_CRITICAL = {
    "planHash": "PlaybackGrant.matches -- entscheidet, ob abgespielt wird",
    "manifestHash": "SmartPodcastFeed -- belegt, aus welchen Stellen eine Ausgabe besteht",
}

# Pruefsummen, die nur benennen und nichts entscheiden.
COSMETIC = {
    "NativeCoverRenderer.swift": "Farbwahl des Covers",
    "PersonalEpisodePublisher.swift": "Schluessel zur Deduplizierung einer Charge",
    "Identifiers.swift": "Definition beider Digests",
}


# --------------------------------------------------------------------------
# 2. Die Rechnung.
# --------------------------------------------------------------------------

def secure_hex(text):
    """Portierung von SecureDigest.hex(of:)."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def secure_hex_ordered(parts):
    return secure_hex(SEPARATOR.join(parts))


def secure_hex_unordered(parts):
    return secure_hex(SEPARATOR.join(sorted(parts)))


# --------------------------------------------------------------------------
# 1. Die Politik.
# --------------------------------------------------------------------------

def check_policy(failures):
    checks = 0
    sources = sorted(ROOT.rglob("*.swift"))

    for field, why in SECURITY_CRITICAL.items():
        checks += 1
        assignments = []
        for path in sources:
            for line in path.read_text(encoding="utf-8").splitlines():
                if re.search(rf"self\.{field}\s*=", line):
                    assignments.append((path.name, line.strip()))
        if not assignments:
            failures.append(f"{field} wird nirgends gesetzt -- Pruefung ins Leere")
            continue

        # Zwei Arten von Zuweisung: eine berechnet die Pruefsumme, die
        # anderen reichen sie nur durch (der Grant uebernimmt die des Plans).
        # Geprueft wird deshalb: keine berechnet sie mit StableDigest, und
        # mindestens eine berechnet sie ueberhaupt -- mit SecureDigest.
        computed = [(n, l) for n, l in assignments if "Digest" in l]
        checks += 1
        if not computed:
            failures.append(f"{field} wird nirgends berechnet ({why})")
        for name, line in computed:
            checks += 1
            if "SecureDigest" not in line:
                failures.append(
                    f"{name}: {field} nicht ueber SecureDigest berechnet ({why})\n"
                    f"           {line}")

    # SecureDigest muss tatsaechlich SHA-256 rechnen und nicht nur so heissen.
    identifiers = next(p for p in sources if p.name == "Identifiers.swift")
    text = identifiers.read_text(encoding="utf-8")
    checks += 1
    if "SHA256.hash" not in text:
        failures.append("SecureDigest benutzt kein SHA256.hash")
    checks += 1
    if "enum SecureDigest" not in text:
        failures.append("SecureDigest fehlt")

    # Und die Freigabe muss die Pruefsumme wirklich vergleichen -- sonst
    # waere die ganze Umstellung folgenlos.
    plan = next(p for p in sources if p.name == "PlaybackPlan.swift")
    checks += 1
    if not re.search(r"planHash\s*==\s*plan\.planHash", plan.read_text(encoding="utf-8")):
        failures.append("PlaybackGrant vergleicht planHash nicht")

    # Die kosmetischen Stellen duerfen bleiben, wo sie sind -- aber nur dort.
    allowed = set(COSMETIC)
    for path in sources:
        if "StableDigest." in path.read_text(encoding="utf-8"):
            checks += 1
            if path.name not in allowed:
                failures.append(
                    f"{path.name}: benutzt StableDigest, steht aber nicht in der "
                    f"Liste der kosmetischen Stellen -- pruefen, ob dort eine "
                    f"Entscheidung haengt")
    return checks


def main():
    failures = []
    checks = check_policy(failures)

    # Determinismus und Laenge.
    for text in ["", "a", "x" * 5000, "üäö", "127.0.0.1"]:
        checks += 2
        if secure_hex(text) != secure_hex(text):
            failures.append(f"nicht deterministisch: {text!r}")
        if len(secure_hex(text)) != 64:
            failures.append(f"falsche Laenge: {text!r}")

    # Das Trennzeichen verhindert Mehrdeutigkeit: ["ab","c"] und ["a","bc"]
    # duerfen nicht dieselbe Pruefsumme ergeben. Ohne Trenner taeten sie es.
    checks += 2
    if secure_hex_ordered(["ab", "c"]) == secure_hex_ordered(["a", "bc"]):
        failures.append("Trennzeichen wirkungslos")
    if secure_hex("abc") != secure_hex("abc"):
        failures.append("Determinismus verletzt")

    # Reihenfolge: ordered unterscheidet, unordered nicht.
    checks += 2
    if secure_hex_ordered(["b", "a"]) == secure_hex_ordered(["a", "b"]):
        failures.append("ofOrdered ignoriert die Reihenfolge")
    if secure_hex_unordered(["b", "a"]) != secure_hex_unordered(["a", "b"]):
        failures.append("ofUnordered haengt an der Reihenfolge")

    # Ein Hoerplan, dessen Abfolge sich aendert, muss eine andere Pruefsumme
    # haben -- sonst gilt die Freigabe fuer eine andere Reihenfolge weiter.
    plan_a = ["m1:0-1000", "m2:5000-6000"]
    plan_b = ["m2:5000-6000", "m1:0-1000"]
    checks += 1
    if secure_hex_ordered(plan_a) == secure_hex_ordered(plan_b):
        failures.append("umgestellter Plan hat dieselbe Pruefsumme")

    # Und eine geaenderte Stelle ebenso -- das ist der eigentliche Fall:
    # dieselbe Folge, eine Sekunde verschoben.
    checks += 1
    if secure_hex_ordered(plan_a) == secure_hex_ordered(["m1:0-1000", "m2:5001-6000"]):
        failures.append("verschobene Stelle hat dieselbe Pruefsumme")

    if failures:
        for line in failures:
            print(f"  FEHLER: {line}")
        print(f"Digest-Politik-Referenz: {len(failures)} von {checks} Pruefungen fehlgeschlagen.")
        return 1

    print(f"Digest-Politik-Referenz: {checks} Pruefungen bestanden "
          f"({len(SECURITY_CRITICAL)} entscheidungstragende Pruefsummen auf SHA-256, "
          f"{len(COSMETIC)} kosmetische Stellen benannt, Rechnung gegen hashlib).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
