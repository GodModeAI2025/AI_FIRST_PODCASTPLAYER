# PodcastAI — Stand gegen das Konzept

> **Korrigiert am 2026-09-20 nach einem unabhängigen Audit.**
>
> Die vorige Fassung dieses Dokuments behauptete „Alle zwanzig Kapitel sind
> umgesetzt“. Das war falsch. Sie bewertete, ob Code **existiert** — nicht,
> ob er **aufgerufen** wird. Drei Kapitel waren mit Dateien belegt, die null
> Aufrufstellen haben. Die Tabelle unten unterscheidet das jetzt.

Stand: 58 Swift-Dateien, 11 706 Zeilen (mit Tests).
**Kein Xcode-Build** — diese Umgebung hat keinen Swift-Compiler.

## Legende

| | Bedeutung |
|---|---|
| **✅** | Gebaut **und** an die App angeschlossen: es gibt einen Weg dorthin und einen Aufrufer |
| **◐** | Code vorhanden und geprüft, aber **nicht verdrahtet** — null Aufrufstellen oder kein Weg in der Oberfläche |
| **✗** | Fehlt |

## Abdeckung

| # | Konzeptkapitel | Stand | Was fehlt |
|---|---|---|---|
| 1 | Quellen: RSS, Folge, YouTube, lokal | ◐ | Nur direkte Feed-URLs funktionieren. YouTube-Video, Playlist und Webseite mit Feed-Suche werfen „noch nicht eingebaut“ |
| 2 | Jede Folge wird verstanden | ◐ | Pipeline läuft, aber das `Transcript` wird nie persistiert — nur die daraus gezogenen Belege |
| 3 | Interessenmodell, bestätigt vs. vermutet | ◐ | Bestätigte Interessen funktionieren. Es erzeugt nie jemand einen Vorschlag, die vermutete Hälfte ist leer |
| 4 | Relevante Stellen + „Warum für dich?“ | ◐ | `relevantToday` wird **nie zugewiesen**. Der erste Tab der App ist strukturell leer |
| 5 | Smart Podcast List | ◐ | „Anlegen“ rief `createSmartFeed` nicht auf → `smartFeeds` dauerhaft leer → die gesamte Folgekette tot |
| 6 | Dauerhafte Feeds, Veröffentlichungsrhythmus | ◐ | Hängt an Kapitel 5. `processPendingEditions` iteriert über eine leere Liste |
| 7 | Titel, Shownotes, Kapitel, Cover | ◐ | `NativeCoverRenderer` nie instanziiert, `CoverAsset` nie erzeugt. Shownotes tragen „Quelle“/„Folge“ als Platzhalter |
| 8 | Hörzustand auf Segmentebene | ◐→✅ | `PlaybackObserver` war nie implementiert — der Ledger wurde **nie geschrieben**. Verdrahtung nachgezogen, siehe unten |
| 9 | Chat als zweite Bedienoberfläche | ◐ | Stichwortabgleich, **kein Modellaufruf**. `AppleModelRouter` hat null Aufrufstellen. Abdeckungsangabe ist fest verdrahtet |
| 10 | Chat steuert den Player | ✅ | |
| 11 | Widerspruchs-Mixer | ◐ | Zuordnung immer `.differentPremise` ohne Modellprüfung — also nie eine echte Gegenposition |
| 12 | Highlights und Wissen | ◐ | Kein „Merken“-Knopf in der App; einziger Weg ist ein App Intent, der nicht läuft. Highlights überleben keinen Neustart |
| 13 | Breadcrumb Trail | ◐ | `SessionClosureSheet` wird nie gezeigt → `park`/`deepen` unerreichbar |
| 14 | Markdown-Export | ◐ | `exportKnowledge` übergibt leere Belege und Titel → der Export hat eine Überschrift „Quellen“ und nichts darunter |
| 15 | Agent-first: App Intents | ◐ | Kein `AppDependencyManager.shared.add(...)` → jeder `@Dependency`-Zugriff schlägt zur Laufzeit fehl |
| 16 | Systemweite Auffindbarkeit (Spotlight) | ◐ | `index(highlights:evidence:)` hat null Aufrufstellen. Der Schalter existiert nur auf macOS |
| 17 | macOS-MCP-Zugang | ◐ | **Kein Server.** Keine stdio-Schleife, kein JSON-RPC, keine Oberfläche. Nur die Werkzeugklasse |
| 18 | Native App, iOS + macOS | ◐ | Zwei Targets ja. iOS hat keinen Einstellungsbereich und keinen Vollbild-Player |
| 19 | Privacy-first, nur Apple-Modelle | ◐ | Die Regeln stehen im Code, aber es wird nie ein Modell aufgerufen — also auch nie geroutet |
| 20 | Der durchgehende Flow | ✗ | Wegen 4 und 5 nicht begehbar |

## Was nachweislich trägt

Nicht alles ist Behauptung. Diese Aussagen wurden unabhängig geprüft:

1. **`attributeOptions: [.audioTimeRange]`** steht real in `TimedTranscriptionEngine.swift:191`.
   Die zentrale Abgrenzung zu BrainSpeak hält.
2. **`PodcastAICore` hängt nur an Foundation** — deshalb war die Kernlogik ohne
   Apple-SDK prüfbar.
3. **Die Wiedergabefreigabe ist ernsthaft gebaut**: `PlaybackPolicy`,
   `consumedGrants`, `sessionToken`, `forwardPlaybackEndTime`. Regel 3
   („automatisch vorbereiten, bewusst abspielen“) wird eingehalten, nicht nur behauptet.
4. **Die Domänenschicht ist geprüft** — `IntervalSet`, `ListeningLedger`,
   `FocusPlanner`, `PersonalEpisodePublisher`, `MarkdownExporter`. Die
   Referenzmodelle sind echte Brute-Force-Vergleiche.
5. **Der PCC-Status ist als „nicht berechtigt“ hart verdrahtet** und als
   Vorgabe statt Messung ausgewiesen.

## Die eigentliche Lage

Ein **guter, geprüfter Domänenkern** steckt in einer App, in der er
größtenteils **nicht angeschlossen** ist. Das ist keine Compiler- und keine
Gerätefrage: die Befunde sind mit `grep` auffindbar und hätten vor jedem
Häkchen stehen müssen.

Fünf von zehn zentralen Domänentypen haben **keinen Persistenzpfad**:

| Typ | Liegt in | Nach Neustart |
|---|---|---|
| `Highlight` | `AppModel.highlights` | weg |
| `KnowledgeTrail` | `AppModel.trails` | weg |
| `SmartPodcastFeed` | `AppModel.smartFeeds` | weg |
| `PersonalEpisode` | `AppModel.editions` | weg |
| `CoverAsset` | — | wird nie erzeugt |

`StoredHighlight`, `StoredTranscript`, `StoredSegment` und
`StoredMediaVersion` stehen im Schema und werden nirgends geschrieben.

## Grenzen der Verifikation

Die Referenzmodelle sind **Algorithmus-Tests, keine Portierungen im
Wortsinn** — das README hat sie als „Zeile für Zeile portiert“ verkauft,
was zu stark war. Was sie bauartbedingt nicht sehen:

* **Swift-spezifische Reihenfolgen.** `RelevanceScorer` nutzt
  `byInterest.values.flatMap` — Swifts `Dictionary` ist pro Prozess
  zufällig sortiert, Pythons `dict` einfügungsstabil. Das Modell behauptet
  Determinismus, den Swift nicht hat.
* **Rundung.** Swifts `.rounded()` ist kaufmännisch, Pythons `round()`
  rundet zur geraden Zahl.
* **Wiedergaberaten ≠ 1.** `publisher_reference.py` ruft `apply_budget` nur
  mit `rate=1.0`. Im Swift rechnet das Budget mit `listeningDuration`, die
  virtuelle Zeitachse aber mit der ungeteilten `playback.duration` — bei
  1,5-facher Geschwindigkeit laufen beide auseinander.
* **Alles zwischen den portierten Funktionen.** Der
  Veröffentlichungsrhythmus (`PublicationPolicy`, `.belowThreshold`,
  `existingBatchKeys`) ist im Modell gar nicht abgebildet.

`swift_consistency.py` ist eine Regex-Heuristik mit handgepflegter
Namensliste. „0 unaufgelöste Bezeichner“ sagt etwas über die Pflege der
Liste, nicht über den Code. **Keiner** der Befunde in diesem Dokument wäre
damit auffindbar gewesen.

## Widersprüche in der Dokumentation

`plan/01` und `plan/03` sagen weiterhin „Alle 266 Aufgaben sind offen“,
`specs/.../tasks.json` steht 266× auf `not_started`, und
`plan/02-konzept-abdeckung.md` führt Kapitel 16 als Lücke. Diese Dokumente
beschreiben den Planungsstand vor dem Bauen und wurden nie nachgeführt.
Wo sie `STATUS.md` widersprechen, gilt **dieses** Dokument für den Code —
und die Planungsdokumente für den Plan.

`audit/brainspeak-baseline.md` stammt aus dem gelieferten Spec-Kit und sagt
„404, keine Quelle geprüft“. Das ist überholt: der Checkout kam später als
ZIP-Upload und wurde ausgewertet (`plan/04-brainspeak-audit.md`). Er wurde
**bewusst nicht** ins Repository übernommen — was bedeutet, dass die
Angaben in `plan/04` hier nicht nachprüfbar sind.

## Was ein Mac-Build klären muss

Unverändert offen, aber nachrangig gegenüber der fehlenden Verdrahtung:
GATE-SDK (`attributeOptions`), GATE-PCC, GATE-PLAY (exakte Grenzen bei
erhöhter Geschwindigkeit), GATE-TIME (Timecodes gegen eine schneller als
Echtzeit analysierte Datei), D7 (26 gegen 27).
