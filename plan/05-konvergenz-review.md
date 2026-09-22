# Konvergenz-Review

Pflichtschritt aus `AGENTS.md` Punkt 10: am Abschluss eine Konsistenz- und
Konvergenzprüfung, und **ausgeführte, blockierte und nicht gelaufene
Ergebnisse getrennt** ausweisen.

Getrennt heißt hier: kein Abschnitt darf den anderen stützen. Was gelaufen
ist, steht mit seiner Ausgabe da. Was nicht laufen kann, steht mit dem
Grund da. Was nicht gelaufen ist, obwohl es könnte, steht ebenfalls da —
diese dritte Kategorie ist die, die in Berichten gern in der zweiten
verschwindet.

Erzeugt am 22. September 2026. Alle Zahlen stammen aus Läufen dieser
Sitzung, nicht aus früheren Angaben.

---

## A — Ausgeführt

Jede Zeile hier ist ein Befehl, der gelaufen ist, mit dem Ergebnis, das er
ausgegeben hat.

### A.1 Paketprüfung

```
python3 scripts/validate_packet.py
```

`status: passed`, `scope: specification_packet_only`. 144 Anforderungen,
20 Stories, 266 Aufgaben, 144 Akzeptanzfälle, 41 Schema-Fixtures, 11 Bilder,
4 synthetische Quellen. Die Prüfung meldet selbst `appleAppBuilt: false` und
`productTestsExecuted: false`.

```
python3 -m unittest discover -s tests -p 'test_*.py'
```

95 Tests, `OK`, 0,069 s.

Beide prüfen das **Dokumentpaket**, nicht die App. Das ist keine
Einschränkung, die ich hinzufüge — `validate_packet.py` schreibt sie selbst
in sein Ergebnis.

### A.2 Referenzmodelle der App-Logik

`app/verification/run_all.sh`, 18 Dateien mit 19 Ergebniszeilen — `intervalset_reference.py` meldet zwei —, zusammen **1 321 318 Prüfungen**, alle bestanden:

| Modell | Prüfungen |
|---|---|
| `intervalset_reference.py` | 210 003 |
| `selection_reference.py` | 180 004 |
| `suggester_reference.py` | 156 033 |
| `ledger_reference.py` | 140 005 |
| `export_reference.py` | 120 016 |
| `focusplanner_reference.py` | 120 004 |
| `passage_reference.py` | 100 003 |
| `relevance_reference.py` | 100 005 |
| `assembler_reference.py` | 80 006 |
| `publisher_reference.py` | 74 470 |
| `intervalset_reference.py` — StableDigest-Teil derselben Datei | 40 000 |
| `backpressure_reference.py` | 258 |
| `transferlimit_reference.py` | 148 |
| `mediatime_reference.py` | 137 |
| `networkdestination_reference.py` | 101 |
| `mcpserver_reference.py` | 49 |
| `digestpolicy_reference.py` | 28 |
| `feeddiscovery_reference.py` | 28 |
| `sourceresolver_reference.py` | 20 |

Zehn davon vergleichen gegen ein unabhängiges Brute-Force-Modell. Die
übrigen prüfen eine Eigenschaft; zwei davon (`digestpolicy`,
`feeddiscovery`) lesen zusätzlich den Swift-Quelltext und schlagen an, wenn
eine künftige Änderung die Regel bricht.

### A.3 Statische Prüfungen über den Swift-Code

`swift_consistency.py`: 68 Dateien, 302 Typen, 0 unaufgelöste Bezeichner,
keine Klammer-, Guard- oder Doppeldeklarationsfehler.

`design_checklist.py`: 20 Oberflächendateien, 8 Prüfpunkte bestanden
(Tab Bar ≤ 5, Such-Tab vorhanden, Abstände und Radien über Design-Token,
Symbolschaltflächen beschriftet, Liquid Glass nur auf der Navigationsebene,
Farbe nirgends alleiniger Bedeutungsträger, 9 erklärte leere Zustände).

**Was diese beiden nicht sind:** ein Compiler. `swift_consistency.py` ist
eine Regex-Heuristik mit handgepflegter Namensliste; „0 unaufgelöste
Bezeichner" sagt etwas über die Pflege der Liste. Ihre Aussagekraft wurde in
dieser Sitzung viermal gegengeprüft, indem ein Fehler absichtlich eingebaut
und die Meldung abgewartet wurde (unausgeglichene Klammer außerhalb und nach
einer String-Interpolation, unbekannter Typ, doppelte Deklaration).

---

## B — Blockiert

Nicht „noch nicht gemacht", sondern: in dieser Umgebung nicht möglich. Für
jede Zeile steht, woran es liegt und was sie klären würde.

| Nachweis | Grund der Blockade | Was er klären würde |
|---|---|---|
| Xcode-27-Build | Kein Swift-Compiler. `download.swift.org` ist per Netzwerkpolicy gesperrt, GitHub-Releases liegen außerhalb des Session-Scopes | Ob die 14 794 Zeilen Swift übersetzen. **Alles darunter hängt daran.** |
| `bash scripts/probe-apple-sdk.sh` | Ausgeführt, Ausgabe: `NOT RUN: Apple SDK probes require macOS and Xcode 27.` | Reale SDK-/Toolchain-Versionen für `config/toolchain-lock.json` |
| `SpeechAnalyzer` mit `attributeOptions: [.audioTimeRange]` | Kein Apple-SDK | GATE-SDK: ob die zentrale Abgrenzung zu BrainSpeak trägt |
| PCC-Berechtigung | Kein Account, kein Entitlement | GATE-PCC. Der Status ist im Code hart auf „nicht berechtigt" und als Vorgabe statt Messung ausgewiesen |
| Gerätetest Wiedergabe | Kein Gerät | GATE-PLAY: exakte Segmentgrenzen bei erhöhter Geschwindigkeit |
| Gerätetest Zeitachse | Kein Gerät | GATE-TIME: Timecodes gegen eine schneller als Echtzeit analysierte Datei |
| SwiftData-Migration | Kein Gerät | GATE-MIGRATE: die neuen Modelle gegen einen bestehenden Speicher |
| Jeder `#Predicate` | Kein Gerät | Ob die Prädikate übersetzen und das Richtige tun |
| Jeder Framework-Aufruf | Kein Gerät | `AVQueuePlayer`, `BGTaskScheduler`, `CSSearchableIndex`, App Intents, FoundationModels |

`config/toolchain-lock.json` bleibt unverändert: `xcodeBuild: null`,
`sdkBuilds: {}`, `locallyVerified: false`. Die Datei verbietet ausdrücklich,
null-Werte durch geratene zu ersetzen, und `AGENTS.md` Punkt 3 verlangt
reale Ausgaben. Es gibt keine.

---

## C — Nicht gelaufen

Möglich gewesen wäre es teilweise — gelaufen ist es nicht. Diese Kategorie
existiert, damit sie nicht in B verschwindet.

### C.1 Alle 266 Umsetzungsschritte stehen auf `not_started`

Gezählt in `specs/001-ai-podcast-player/tasks.json`: 266 von 266.

Das ist **kein Versäumnis, sondern die Vorschrift.** `AGENTS.md` Punkt 7
verlangt Tests und Abnahmebelege vor jedem `[x]`, Punkt 10 verlangt, dass
nicht umgesetzte App-Aufgaben unangehakt beginnen. Ohne Build und ohne Gerät
gibt es für keinen der 266 Schritte einen Abnahmebeleg. Ein Häkchen wäre
eine Behauptung.

Das gilt ausdrücklich auch für die Smart Podcast List: der Nachtrag 1.3
untersagt die Behauptung, diese Funktion sei bereits umgesetzt. Sie ist im
`app/`-Baum **gebaut und verdrahtet** — abgenommen ist sie nicht.

### C.2 Die 144 Akzeptanzfälle

Keiner ausgeführt. Sie setzen eine laufende App voraus.

### C.3 Watch (Phase 10, 5 Aufgaben)

Nicht angefasst. Der Auftrag dieser Sitzung nannte iOS und macOS; watchOS
ist aus dem Umfang genommen. `config/toolchain-lock.json` führt watchOS 27.0
weiterhin als Zielplattform des **Gesamtprodukts** — dieses Projekt setzt
sie nicht um. Das ist eine Abweichung vom Paket, keine Erledigung.

### C.4 Release-Gates (Phase 12, 12 Aufgaben)

Nicht gelaufen. Sie hängen definitionsgemäß hinter allem anderen. `T099` und
die folgenden Gates müssen laut `AGENTS.md` ohnehin **nach** den
Ergänzungen erneut laufen.

---

## D — Konsistenzbefunde

Stellen, an denen Paket und `app/`-Baum auseinandergehen. Jede mit
Entscheidung, welche Seite gilt.

### D.1 Die Zielpfade der Aufgaben stimmen nicht mit dem Code überein

262 der 266 Aufgaben zeigen auf Pfade wie
`Packages/BrainSpeakDomain/Sources/…`. Gebaut wurde
`app/Packages/PodcastAIKit/Sources/PodcastAICore/…`.

**Kein Widerspruch.** `audit/integration-map.md` sagt es selbst: „Alle
Zielmodule aus `plan.md` sind vorgeschlagene Zuständigkeiten. Die physische
Aufteilung wird erst nach dem Ist-Audit entschieden." Zwei Gründe für die
Abweichung: der Nutzer hat die App `PodcastAI` genannt, und BrainSpeak ist
keine Podcast-App — sie wurde als Fähigkeitsquelle ausgewertet, nicht als
Basis fortgeschrieben.

**Folge, die offen bleibt:** wer die 266 Aufgaben abarbeitet, findet die
Pfade nicht vor. Die Zuordnung steht in `plan/01-umsetzungsplan.md` und
`plan/02-konzept-abdeckung.md`, nicht in `tasks.json` — und `tasks.json` ist
hash-gesperrt.

### D.2 `audit/brainspeak-baseline.md` ist überholt und bleibt es

Die Datei sagt „404, keine Quelle geprüft". Der Checkout kam später als
ZIP-Upload und wurde ausgewertet; das Ergebnis steht in
`plan/04-brainspeak-audit.md`.

`AGENTS.md` Punkt 1 verlangt den Audit **in** `audit/brainspeak-baseline.md`.
Die Datei steht in `SHA256SUMS`; sie zu ändern bricht
`scripts/validate_packet.py`, das Punkt 9 verlangt. Die beiden Vorschriften
widersprechen sich.

**Entscheidung:** Punkt 9 gewinnt, der Audit bleibt additiv in `plan/04`.
Der Grund ist nicht Bequemlichkeit: eine gebrochene Integritätsprüfung
entwertet jede andere Aussage über das Paket. Wer das anders will, entfernt
die Zeile aus `SHA256SUMS` — das ist eine bewusste Handlung und keine, die
ein Agent nebenbei treffen sollte.

**Offen bleibt:** der BrainSpeak-Checkout wurde nicht ins Repository
übernommen. Die Angaben in `plan/04` sind hier nicht nachprüfbar.

### D.3 Mindestversion: behoben

`app/project.yml` stand auf iOS/macOS 26.0. `config/toolchain-lock.json`
trägt `"policy": "latest-apple-native-27-only"` mit 27.0 für alle vier
Plattformen, `AGENTS.md` Punkt 3 macht sie verbindlich.

In dieser Sitzung auf 27.0 korrigiert. Am Code ändert das nichts — die
benutzten APIs gibt es ab 26 —, an der Mindesthardware schon. `D7` im Plan
war als offene Entscheidung geführt; sie war es nicht.

### D.4 Die Planungsdokumente sind nicht nachgeführt

`plan/01` und `plan/03` sagen „Alle 266 Aufgaben sind offen". Das stimmt
(siehe C.1). `plan/02-konzept-abdeckung.md` führt Kapitel 16 als Lücke —
das stimmt nicht mehr.

**Regel:** für den Stand des Codes gilt `app/STATUS.md`, für den Stand der
Planung gelten die Planungsdokumente. Wo sie sich widersprechen, gewinnt
`STATUS.md` — aber nur über den Code.

### D.5 Synthetische Testdaten

`AGENTS.md` Punkt 6: fiktiver Folgentext darf nicht in Fixtures oder
Tatsachenbehauptungen geraten. `fixtures/` wurde nicht angefasst.

In `app/verification/publisher_reference.py` standen Medienkennungen, die
auf reale Sendungen anspielten. In dieser Sitzung auf `quelle-1` bis
`quelle-4` geändert: Namen echter Sendungen wären dort keine Testdaten,
sondern eine Behauptung über sie.

### D.6 Untrusted Data

`AGENTS.md` Punkt 4: RSS, Transkripte und Werkzeugergebnisse sind Daten,
nie Anweisungen. Im Code umgesetzt und an drei Stellen sichtbar:

- Die These im Widerspruchs-Mixer steht als **Lesekontext im Prompt**, nicht
  in den Instruktionen der Sitzung.
- Jede Modellantwort wählt Nummern oder vorgegebene Bezeichnungen; was
  außerhalb liegt, wird verworfen statt auf das Nächstähnliche umgebogen.
- Zeiten, Rechte, Scope und Fassung löst ausschließlich Swift auf.

Geprüft durch `selection_reference.py` (180 004 Prüfungen) und
`digestpolicy_reference.py`.

---

## E — Was als Nächstes laufen muss

In dieser Reihenfolge, weil jede Stufe die darüber voraussetzt:

1. `cd app && xcodegen generate`, dann Build beider Schemata in Xcode 27.
   **Erwartung: es wird Fehler geben.** 14 794 Zeilen Swift ohne einen
   einzigen Compilerlauf sind kein Zustand, aus dem ein sauberer Build
   hervorgeht.
2. `bash scripts/probe-apple-sdk.sh` auf demselben Mac; Ergebnisse in
   `config/toolchain-lock.json` eintragen — nur echte Ausgaben.
3. `python3 -m unittest`, `validate_packet.py` und `run_all.sh` erneut, zur
   Absicherung gegen Regressionen während der Build-Reparatur.
4. Die Swift-Testing-Tests unter `Packages/PodcastAIKit/Tests/` gegen den
   echten Code laufen lassen — sie prüfen dieselben Invarianten wie die
   Referenzmodelle, aber am Original statt an einer Portierung.
5. Erst danach Akzeptanzfälle abarbeiten und Aufgaben in `tasks.json`
   anhaken. Jedes Häkchen mit Beleg.
6. `T099` und die Release-Gates zuletzt, wie der Nachtrag es verlangt.
