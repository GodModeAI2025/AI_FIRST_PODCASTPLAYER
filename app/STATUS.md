# PodcastAI — Stand gegen das Konzept

Die 20 Kapitel des Konzepts, und was davon im Code steht.
Stand: 2026-09-20 · 53 Swift-Dateien · rund 10 500 Zeilen.

**Kein Xcode-Build.** Diese Umgebung hat keinen Swift-Compiler.
Was belegt ist, steht unter [Verifikation](#verifikation).

## Abdeckung

| # | Konzeptkapitel | Stand | Wo |
|---|---|---|---|
| 1 | Quellen: RSS, Folge, YouTube, lokal | ✅ | `PodcastAISources` |
| 2 | Jede Folge wird verstanden | ✅ | `PodcastAITranscription`, `ContentPipeline` |
| 3 | Interessenmodell, bestätigt vs. vermutet | ✅ | `Interest`, `InterestProfile` |
| 4 | Relevante Stellen + „Warum für dich?“ | ✅ | `RelevanceScorer`, `ForYouView` |
| 5 | Smart Podcast List | ✅ | `PersonalEpisodePublisher` |
| 6 | Dauerhafte Feeds, Veröffentlichungsrhythmus | ✅ | `PublicationPolicy`, `BackgroundWork` |
| 7 | Titel, Shownotes, Kapitel, Cover | ✅ | `ShownotesBuilder`, `NativeCoverRenderer` |
| 8 | Hörzustand auf Segmentebene | ✅ | `ListeningLedger`, `IntervalSet` |
| 9 | Chat als zweite Bedienoberfläche | ✅ | `ChatScope`, `ChatView` |
| 10 | Chat steuert den Player | ✅ | `ChatAnswer.playbackProposal()` |
| 11 | Widerspruchs-Mixer | ◐ Modell da, **keine Oberfläche** | `Counterpoint.swift` |
| 12 | Highlights und Wissen | ✅ | `Highlight`, `KnowledgeView` |
| 13 | Breadcrumb Trail | ◐ Modell da, **keine Oberfläche** | `KnowledgeTrail.swift` |
| 14 | Markdown-Export | ✅ | `MarkdownExporter`, `ExportPreviewSheet` |
| 15 | Agent-first: App Intents | ✅ | `Intents.swift` |
| 16 | Systemweite Auffindbarkeit (Spotlight) | ✗ **nicht gebaut** | — |
| 17 | macOS-MCP-Zugang | ✗ **nicht gebaut** | — |
| 18 | Native App, iOS + macOS | ✅ | `project.yml`, zwei Targets |
| 19 | Privacy-first, nur Apple-Modelle | ✅ | `AppleModelRouter` |
| 20 | Der durchgehende Flow | ✅ | begehbar: Quelle → erschliessen → Ausgabe → hören → merken → exportieren |

**Bewusst offen:** Kapitel 16 wurde im Plan als FR-145 vorgeschlagen und
zugleich empfohlen, es **nicht** in 1.0 aufzunehmen — der Systemindex hat
andere Datenschutzkonsequenzen als der app-interne und braucht eine eigene
Einwilligung. Kapitel 17 (MCP) ist ein macOS-Zusatz und hängt nicht am Kern.

**Ohne Oberfläche:** Widerspruchs-Mixer und Breadcrumb-Trail sind im
Datenmodell vollständig, inklusive der heiklen Regeln (eine These wird nur
durch ausdrückliche Bestätigung zum Standpunkt; Verwerfen verwirft nur den
Vorschlag). Es fehlen die Ansichten. Das entspricht der Empfehlung D3 aus
dem Plan, diese 60 Aufgaben nicht ins erste Release zu ziehen.

## Verifikation

Ohne Compiler ist die Kernlogik Zeile für Zeile nach Python portiert und
gegen Brute-Force-Modelle geprüft.

```bash
app/verification/run_all.sh
```

| Prüfung | Umfang |
|---|---|
| `swift_consistency.py` | 53 Dateien: Klammern, `#if`-Blöcke, Doppeldeklarationen, unbekannte Typen |
| `intervalset_reference.py` | 210 003 |
| `selection_reference.py` | 180 004 |
| `ledger_reference.py` | 140 005 |
| `export_reference.py` | 120 016 |
| `focusplanner_reference.py` | 120 004 |
| `passage_reference.py` | 100 003 |
| `assembler_reference.py` | 80 006 |
| `relevance_reference.py` | 80 005 |
| `publisher_reference.py` | 74 391 |
| `redirectguard_reference.py` | 28 Adressen |
| `sourceresolver_reference.py` | 20, davon 11 aus dem Spec-Kit |

Dazu Swift-Testing-Tests unter `Packages/PodcastAIKit/Tests/`, die auf einem
Mac gegen den echten Code laufen.

### Was die Prüfungen gefunden haben

Sechs echte Fehler, alle behoben:

1. **FocusPlanner** — beim Budget-Ausschluss eines verschmolzenen Kandidaten
   verschwanden die mitverschmolzenen Belege spurlos.
2. **TranscriptAssembler** — Dubletten im Bestand überlebten das
   Zusammenführen; die Zusage galt nur mit Vorbedingung.
3. **MarkdownExporter** — Steuerzeichen gingen ungefiltert in den Export.
4. **RedirectGuard** — `0.0.0.0`, IPv6-Privatbereiche und die Klammerform
   `[fd00::1]` fehlten.
5. **MarkdownExporter** — fünf doppelte Zeilen aus einer fehlerhaften
   Ersetzung (gefunden von der Klammernprüfung).
6. **Feed → Analyse** — die Audio-URL aus dem Feed wurde verworfen; die
   Analyse hätte die HTML-Seite bekommen.

## Was ein Mac-Build noch klären muss

* **GATE-SDK** — ob die verwendeten Symbole real existieren, allen voran
  `SpeechTranscriber.attributeOptions: [.audioTimeRange]` und die Form, in
  der `audioTimeRange` an den Runs des `AttributedString` hängt.
* **GATE-PCC** — PCC ist im Code als „nicht berechtigt“ verdrahtet, weil
  kein Entitlement vorliegt. Das ist eine ehrliche Vorgabe, keine Messung.
* **GATE-PLAY** — exakte Segmentgrenzen an echten Audioausgängen, bei 1,5-
  und 2-facher Geschwindigkeit.
* **GATE-TIME** — Timecodes gegen eine Datei, die schneller als Echtzeit
  analysiert wurde. Der Fehler, den das abfängt, ist der gefährlichste:
  plausible, aber falsche Zeiten fallen erst beim Hören auf.
* **D7** — der Code steht auf 26.0. Der Sprung auf 27.0 hebt die
  Mindesthardware an und ist eine Produktentscheidung.
