"""
Referenzmodell zu PodcastAITranscription/TimedTranscriptionEngine.feed
und PodcastAIMedia/AudioFileReader.BufferSequence.

Der Befund war: beide Stroeme liefen mit `bufferingPolicy: .unbounded`, der
Voreinstellung. Der Erzeuger ist die Platte, der Verbraucher die
Spracherkennung -- um Groessenordnungen langsamer. Bei 4096 Frames, 44,1 kHz,
Stereo, 32 Bit sind das rund 32 KB je Block und gut 1,2 GB fuer eine Stunde
Material, die sich im Strom sammeln, bis das System die App beendet.

Eine kleinere Puffergrenze allein waere die falsche Antwort: `AsyncStream`
kann nur *verwerfen*, und ein verworfener Block ist stumm fehlendes
Transkript -- ein Loch, das niemand bemerkt, weil an der Stelle einfach kein
Satz steht.

Die Swift-Fassung loest es zweistufig:

  1. Der Leser zieht (AsyncSequence) statt zu schieben -- er haelt genau
     einen Block.
  2. Die Einspeisung benutzt `.bufferingOldest(n)` und *wiederholt* einen
     abgewiesenen Block, statt ihn fallen zu lassen.

Hier wird belegt, was daraus folgen muss:

  A. Kein Element geht verloren.
  B. Die Reihenfolge bleibt erhalten.
  C. Die Warteschlange ueberschreitet n nie.
"""
import random
import sys


def simulate(produced, capacity, consumer_speed, seed):
    """Fuehrt Erzeuger und Verbraucher verschraenkt aus.

    `capacity` ist `bufferingOldest(n)`; `consumer_speed` ist die
    Wahrscheinlichkeit, dass der Verbraucher in einem Schritt ein Element
    abholt. Der Erzeuger versucht in jedem Schritt einzuspeisen und
    wiederholt bei Abweisung -- genau die Schleife aus `feed`.
    """
    rng = random.Random(seed)
    queue = []
    consumed = []
    pending = None
    next_index = 0
    high_water = 0
    steps = 0
    limit = 200_000

    while (next_index < produced or pending is not None or queue) and steps < limit:
        steps += 1

        # Erzeuger: hoechstens ein Element unterwegs, genau wie `pending`
        # in der Swift-Schleife.
        if pending is None and next_index < produced:
            pending = next_index
            next_index += 1
        if pending is not None:
            if len(queue) < capacity:          # `.enqueued`
                queue.append(pending)
                pending = None
            # sonst `.dropped(rejected)`: `pending` bleibt stehen und wird
            # im naechsten Durchlauf erneut angeboten.

        high_water = max(high_water, len(queue))

        # Verbraucher.
        if queue and rng.random() < consumer_speed:
            consumed.append(queue.pop(0))

    return consumed, high_water, steps < limit


def main():
    checks = 0
    failures = []

    cases = []
    for capacity in (1, 2, 8, 64):
        for consumer_speed in (0.01, 0.1, 0.5, 1.0):
            for produced in (0, 1, 5, 200):
                cases.append((produced, capacity, consumer_speed))

    for seed, (produced, capacity, speed) in enumerate(cases):
        consumed, high_water, terminated = simulate(produced, capacity, speed, seed)

        checks += 1
        if not terminated:
            failures.append(
                f"kein Ende (erzeugt={produced}, Puffer={capacity}, Tempo={speed})")
            continue

        # A: kein Verlust.
        checks += 1
        if len(consumed) != produced:
            failures.append(
                f"Verlust: {len(consumed)} von {produced} "
                f"(Puffer={capacity}, Tempo={speed})")

        # B: Reihenfolge.
        checks += 1
        if consumed != list(range(produced)):
            failures.append(
                f"Reihenfolge verletzt (Puffer={capacity}, Tempo={speed})")

        # C: Speicherschranke.
        checks += 1
        if high_water > capacity:
            failures.append(
                f"Puffer ueberschritten: {high_water} > {capacity}")

    # Der Gegenbeweis: ohne Wiederholung geht bei langsamem Verbraucher
    # tatsaechlich etwas verloren. Sonst waere die Schleife in `feed`
    # ueberfluessig, und das soll hier nicht nur behauptet sein.
    def simulate_without_retry(produced, capacity, consumer_speed, seed):
        rng = random.Random(seed)
        queue, consumed = [], []
        for index in range(produced):
            if len(queue) < capacity:
                queue.append(index)
            # sonst: fallen gelassen, kein zweiter Versuch
            if queue and rng.random() < consumer_speed:
                consumed.append(queue.pop(0))
        return consumed + queue

    checks += 1
    lossy = simulate_without_retry(produced=200, capacity=8, consumer_speed=0.05, seed=1)
    if len(lossy) >= 200:
        failures.append("Gegenbeweis misslungen: ohne Wiederholung ging nichts verloren")

    # Der gezogene Leser haelt genau ein Element -- das ist `capacity == 1`
    # ohne jede Warteschlange.
    checks += 1
    consumed, high_water, _ = simulate(produced=500, capacity=1, consumer_speed=0.02, seed=99)
    if consumed != list(range(500)) or high_water > 1:
        failures.append("gezogener Leser: Verlust oder Puffer groesser als 1")

    if failures:
        for line in failures:
            print(f"  FEHLER: {line}")
        print(f"Gegendruck-Referenz: {len(failures)} von {checks} Pruefungen fehlgeschlagen.")
        return 1

    print(f"Gegendruck-Referenz: {checks} Pruefungen bestanden "
          f"({len(cases)} Kombinationen aus Puffergroesse, Verbrauchertempo und Menge; "
          f"kein Verlust, Reihenfolge erhalten, Schranke eingehalten). "
          f"Ohne Wiederholung gingen {200 - len(lossy)} von 200 Bloecken verloren.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
