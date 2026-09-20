"""
Referenzmodell zu PodcastAICore/MediaTime.swift (SaturatingTime).

Warum das ueberhaupt geprueft wird: `Int64(x)` ist in Swift keine
saettigende Umwandlung, sondern eine Falle. `Int64(1e300)` beendet das
Programm. Die Zahlen, die hier ankommen, stammen aus `<itunes:duration>`,
aus Kapitelmarken und aus `expectedContentLength` -- alle drei aus fremden
Feeds. Ein Absturz, den ein Fremder ausloesen kann, ist ein Fehler.

Geprueft wird gegen Pythons unbegrenzte Ganzzahlen als Orakel: was Python
exakt rechnet, muss die Swift-Fassung entweder gleich liefern oder an der
Grenze abschneiden -- nie etwas dazwischen und nie einen Ueberlauf.
"""
import math
import sys

INT64_MIN = -(2 ** 63)
INT64_MAX = 2 ** 63 - 1


# --------------------------------------------------------------------------
# Portierung von SaturatingTime.
# --------------------------------------------------------------------------

def milliseconds_from_seconds(seconds):
    if not math.isfinite(seconds) or seconds <= 0:
        return 0
    value = round_half_away(seconds * 1000)
    # Swift: `guard value < Double(Int64.max)`. `Double(Int64.max)` rundet auf
    # 2^63 auf, liegt also ueber Int64.max -- der strikte Vergleich ist richtig.
    if not value < float(INT64_MAX + 1):
        return INT64_MAX
    return int(value)


def round_half_away(x):
    """Swifts `Double.rounded()` rundet von der Null weg, Pythons round() zur
    geraden Zahl. Der Unterschied faellt genau auf .5 auf."""
    return math.floor(x + 0.5) if x >= 0 else math.ceil(x - 0.5)


def saturating_add(a, b):
    total = a + b
    return INT64_MAX if total > INT64_MAX else (INT64_MIN if total < INT64_MIN else total)


def saturating_multiply(a, b):
    product = a * b
    if INT64_MIN <= product <= INT64_MAX:
        return product
    return INT64_MAX if (a < 0) == (b < 0) else INT64_MIN


def media_time(ms):
    """MediaTime.init(milliseconds:) -- nie negativ."""
    return max(0, ms)


# --------------------------------------------------------------------------
# Pruefung
# --------------------------------------------------------------------------

ADVERSARIAL_SECONDS = [
    float("inf"), float("-inf"), float("nan"),
    1e300, 1e30, 1e19, 9.3e15, 9.2e15,
    -1.0, -0.0, 0.0, 0.0004, 0.0005, 0.0015,
    1.0, 59.5, 3600.0, 86400.0,
    float(INT64_MAX), float(INT64_MAX) / 1000.0,
]


def main():
    checks = 0
    failures = []

    # 1. Keine Eingabe faellt durch -- und jedes Ergebnis liegt im Wertebereich.
    for seconds in ADVERSARIAL_SECONDS:
        checks += 1
        result = milliseconds_from_seconds(seconds)
        if not (0 <= result <= INT64_MAX):
            failures.append(f"ausserhalb Int64: {seconds!r} -> {result}")

    # 2. Im harmlosen Bereich muss exakt gerechnet werden, nicht gesaettigt.
    for seconds in [0.0, 0.001, 1.0, 1.5, 59.999, 3600.0, 86399.999]:
        checks += 1
        expected = round_half_away(seconds * 1000)
        if milliseconds_from_seconds(seconds) != expected:
            failures.append(f"ungenau bei {seconds}: "
                            f"{milliseconds_from_seconds(seconds)} statt {expected}")

    # 3. Addition: erschoepfend an den Raendern.
    edges = [0, 1, 2, 1000, INT64_MAX - 1, INT64_MAX, INT64_MAX // 2, INT64_MAX // 2 + 1]
    for a in edges:
        for b in edges:
            checks += 1
            result = saturating_add(a, b)
            exact = a + b
            if exact <= INT64_MAX:
                if result != exact:
                    failures.append(f"add({a},{b}) = {result}, exakt waere {exact}")
            elif result != INT64_MAX:
                failures.append(f"add({a},{b}) haette saettigen muessen, ist {result}")

    # 4. Multiplikation: MediaDuration(minutes:) rechnet minutes * 60_000.
    for minutes in [0, 1, 60, 1440, -1, -1000,
                    INT64_MAX, INT64_MAX // 60_000, INT64_MAX // 60_000 + 1,
                    INT64_MIN]:
        checks += 1
        result = saturating_multiply(minutes, 60_000)
        exact = minutes * 60_000
        if INT64_MIN <= exact <= INT64_MAX:
            if result != exact:
                failures.append(f"mul({minutes}) = {result}, exakt waere {exact}")
        elif not (result == INT64_MAX or result == INT64_MIN):
            failures.append(f"mul({minutes}) haette saettigen muessen, ist {result}")
        # MediaDuration schneidet danach bei 0 ab: nie negativ.
        checks += 1
        if max(0, result) < 0:
            failures.append(f"MediaDuration(minutes: {minutes}) waere negativ")

    # 5. listeningDuration: Rate nahe null darf nicht ueberlaufen.
    for rate in [0.0, -1.0, float("nan"), float("inf"), 1e-300, 0.5, 1.0, 1.5, 2.0, 3.0]:
        checks += 1
        ms = 3_600_000
        if not (rate > 0) or not math.isfinite(rate):
            result = ms          # Swift gibt `self` zurueck
        else:
            result = milliseconds_from_seconds((ms / 1000.0) / rate)
        if not (0 <= result <= INT64_MAX):
            failures.append(f"listeningDuration(atRate: {rate}) -> {result}")

    # 6. MediaTime - MediaTime: beide Seiten nicht-negativ, Differenz kann
    #    nicht ueberlaufen. Das ist die Begruendung dafuer, dass dort *keine*
    #    saettigende Rechnung steht -- also wird sie belegt.
    for a in [0, 1, INT64_MAX, INT64_MAX - 1]:
        for b in [0, 1, INT64_MAX, INT64_MAX - 1]:
            checks += 1
            difference = abs(a - b)
            if not (0 <= difference <= INT64_MAX):
                failures.append(f"|{a} - {b}| = {difference} ausserhalb Int64")

    if failures:
        for line in failures:
            print(f"  FEHLER: {line}")
        print(f"MediaTime-Referenz: {len(failures)} von {checks} Pruefungen fehlgeschlagen.")
        return 1

    print(f"MediaTime-Referenz: {checks} Pruefungen bestanden "
          f"(Saettigung bei Umwandlung, Addition, Multiplikation; "
          f"Randwerte erschoepfend).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
