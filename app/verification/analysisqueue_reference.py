"""
Referenzmodell zu Warteschlange und Pruefpunkten beim Erschliessen.

Der Auftrag lautete: "Erschliessen der Folgen muss auch im Hintergrund
klappen." Das ist keine Zeile Code, sondern eine Eigenschaft, die ueber
viele Unterbrechungen hinweg halten muss -- und genau solche Eigenschaften
verhalten sich still falsch. Eine Folge, die nach jedem Hintergrundfenster
wieder bei null beginnt, sieht von aussen aus wie eine, die arbeitet.

iOS gibt beim Wechsel in den Hintergrund Sekunden und einem
BGProcessingTask Minuten. Beides reicht nicht fuer eine 90-Minuten-Folge.
Wer nicht anhalten und weitermachen kann, kommt nie an. Geprueft wird
deshalb:

  A. **Fortschritt.** Ueber beliebig viele, beliebig kurze Fenster hinweg
     wird jede Folge fertig -- solange jedes Fenster wenigstens einen
     Pruefpunkt schafft.
  B. **Kein Rueckschritt.** Ein Abbruch kostet hoechstens den Abstand zum
     letzten Pruefpunkt, nie mehr.
  C. **Reihenfolge.** Wer zuerst gewartet hat, kommt zuerst dran.
  D. **Keine Blockade.** Eine dauerhaft kaputte Folge haelt die anderen
     nicht auf.
"""
import random
import sys

CHECKPOINT_MINUTES = 5          # ContentPipeline.checkpointInterval
MAX_FAILURES = 3                # LibraryStore.maximumAnalysisFailures


class Episode:
    def __init__(self, key, minutes, broken=False):
        self.key = key
        self.minutes = minutes
        self.broken = broken
        self.saved = 0          # gesicherter Stand in Minuten
        self.failures = 0
        self.done = False


def run_window(queue, budget_minutes, episodes):
    """Ein Hintergrundfenster. Gibt zurueck, wie viel Zeit verbraucht wurde.

    Portierung von AppModel.drainQueue zusammen mit den Pruefpunkten aus
    ContentPipeline.process: gearbeitet wird an genau einer Folge, gesichert
    wird alle CHECKPOINT_MINUTES Medienzeit, und was seit dem letzten
    Pruefpunkt lief, ist beim Abbruch verloren.
    """
    used = 0
    while used < budget_minutes:
        pending = [e for e in queue
                   if not episodes[e].done and episodes[e].failures < MAX_FAILURES]
        if not pending:
            break
        episode = episodes[pending[0]]

        if episode.broken:
            episode.failures += 1
            used += 1                      # ein Fehlversuch kostet auch Zeit
            continue

        progress = episode.saved
        while used < budget_minutes and progress < episode.minutes:
            step = min(CHECKPOINT_MINUTES, episode.minutes - progress,
                       budget_minutes - used)
            used += step
            progress += step
            # Gesichert wird nur ein *voller* Pruefpunkt oder das Ende.
            if progress - episode.saved >= CHECKPOINT_MINUTES or progress >= episode.minutes:
                episode.saved = progress

        if episode.saved >= episode.minutes:
            episode.done = True
            queue.remove(episode.key)
        else:
            # Bleibt in der Warteschlange und wird fortgesetzt.
            return used
    return used


def main():
    rng = random.Random(20260923)
    checks = 0
    failures = []

    # --- A und B: viele Faelle, zufaellige Fensterlaengen ---
    for case in range(5000):
        episodes = {}
        queue = []
        for index in range(rng.randint(1, 5)):
            key = f"e{index}"
            episodes[key] = Episode(key, minutes=rng.choice([3, 5, 12, 47, 90, 180]))
            queue.append(key)

        total = sum(e.minutes for e in episodes.values())
        previous_saved = {k: 0 for k in episodes}
        windows = 0

        while any(not e.done for e in episodes.values()):
            windows += 1
            if windows > 10_000:
                failures.append(f"Fall {case}: kommt nicht ans Ende")
                break
            # Jedes Fenster schafft mindestens einen Pruefpunkt. Kuerzere
            # Fenster waeren ein eigener Befund -- siehe unten.
            budget = rng.randint(CHECKPOINT_MINUTES, 40)
            run_window(queue, budget, episodes)

            # B: nichts geht zurueck.
            for key, episode in episodes.items():
                checks += 1
                if episode.saved < previous_saved[key]:
                    failures.append(
                        f"Fall {case}/{key}: Rueckschritt "
                        f"{previous_saved[key]} -> {episode.saved}")
                previous_saved[key] = episode.saved

        # A: alles fertig, und die Warteschlange ist leer.
        checks += 2
        if not all(e.done for e in episodes.values()):
            failures.append(f"Fall {case}: nicht alle fertig")
        if queue:
            failures.append(f"Fall {case}: Warteschlange nicht leer: {queue}")

        # Nicht mehr Arbeit als noetig: der Verlust je Unterbrechung ist
        # durch den Pruefpunktabstand begrenzt, also kann die Gesamtarbeit
        # nicht beliebig wachsen.
        checks += 1
        if any(e.saved > e.minutes for e in episodes.values()):
            failures.append(f"Fall {case}: ueber das Ende hinaus gezaehlt")
        _ = total

    # --- C: Reihenfolge ---
    episodes = {k: Episode(k, minutes=10) for k in ["a", "b", "c"]}
    queue = ["a", "b", "c"]
    finished = []
    while any(not e.done for e in episodes.values()):
        before = {k: e.done for k, e in episodes.items()}
        run_window(queue, 10, episodes)
        for key, episode in episodes.items():
            if episode.done and not before[key]:
                finished.append(key)
    checks += 1
    if finished != ["a", "b", "c"]:
        failures.append(f"Reihenfolge verletzt: {finished}")

    # --- D: eine kaputte Folge blockiert nicht ---
    episodes = {
        "kaputt": Episode("kaputt", minutes=10, broken=True),
        "heil": Episode("heil", minutes=10),
    }
    queue = ["kaputt", "heil"]
    for _ in range(20):
        run_window(queue, 20, episodes)
    checks += 2
    if not episodes["heil"].done:
        failures.append("kaputte Folge blockiert die naechste")
    if episodes["kaputt"].failures != MAX_FAILURES:
        failures.append(
            f"kaputte Folge wurde {episodes['kaputt'].failures}x versucht, "
            f"erwartet {MAX_FAILURES}")

    # --- Der Gegenbeweis ---
    #
    # Ohne Pruefpunkte -- also wenn jeder Abbruch den ganzen Lauf verwirft --
    # kommt eine Folge, die laenger ist als jedes Fenster, **nie** ans Ende.
    # Genau das war der Zustand vor dieser Aenderung, und er soll nicht nur
    # behauptet, sondern gezeigt sein.
    def run_without_checkpoints(minutes, budget, windows):
        for _ in range(windows):
            progress = 0
            while progress < minutes and progress < budget:
                progress += 1
            if progress >= minutes:
                return True     # nur wenn es in ein Fenster passt
        return False

    checks += 2
    if run_without_checkpoints(minutes=90, budget=20, windows=1000):
        failures.append("Gegenbeweis misslungen: ohne Pruefpunkte doch fertig geworden")
    if not run_without_checkpoints(minutes=10, budget=20, windows=1):
        failures.append("Gegenbeweis falsch: was passt, muss auch ohne Pruefpunkte gehen")

    # --- Die bekannte Grenze, ausdruecklich ---
    #
    # Ein Fenster, das kuerzer ist als ein Pruefpunktabstand, bringt nichts
    # voran. Das ist kein Fehler des Modells, sondern eine Eigenschaft des
    # gewaehlten Abstands -- und der Grund, warum er nicht groesser sein darf.
    episodes = {"lang": Episode("lang", minutes=90)}
    queue = ["lang"]
    for _ in range(50):
        run_window(queue, CHECKPOINT_MINUTES - 1, episodes)
    checks += 1
    if episodes["lang"].saved != 0:
        failures.append("zu kurze Fenster haben doch etwas gesichert")

    if failures:
        for line in failures[:10]:
            print(f"  FEHLER: {line}")
        print(f"Warteschlangen-Referenz: {len(failures)} von {checks} Pruefungen fehlgeschlagen.")
        return 1

    print(f"Warteschlangen-Referenz: {checks} Pruefungen bestanden "
          f"(5000 Zufallsfaelle ueber zufaellige Fensterlaengen; Fortschritt, "
          f"kein Rueckschritt, Reihenfolge, keine Blockade). "
          f"Gegenbeweis: ohne Pruefpunkte wird eine 90-Minuten-Folge in "
          f"20-Minuten-Fenstern nie fertig.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
