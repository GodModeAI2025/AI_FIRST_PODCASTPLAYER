# Konzeptabdeckung — die 20 Kapitel gegen das Spec-Kit geprüft

**Frage:** Ist das Gesamtkonzept vollständig spezifiziert, oder plant man gerade an Lücken vorbei?
**Methode:** Jedes Konzeptkapitel gegen `requirements.json` (144 FR), `stories.json` (20 US) und `tasks.json` (266 T) geprüft.
**Ergebnis:** 17 von 20 Kapiteln sind vollständig abgedeckt. **Drei Lücken** sind real und unten als FR-145–147 formuliert.

> **Nach dem BrainSpeak-Ist-Audit (2026-09-20):** Die Abdeckungsmatrix bleibt unverändert — sie prüft Konzept gegen
> Spezifikation, nicht gegen Code. Der Audit bestätigt die Lücken aber von der Implementierungsseite:
> `AppIntent`, `AppEntity`, `CoreSpotlight` und `CSSearchable` kommen im gesamten Checkout in **null Dateien** vor.
> Die Lücken 1 und 2 sind also weder spezifiziert noch vorhanden. Siehe [04-brainspeak-audit.md](04-brainspeak-audit.md).

---

## 1. Abdeckungsmatrix

| # | Konzeptkapitel | US | FR | Tasks | Status |
|---|---|---|---|---|---|
| 1 | Die Quellen (RSS, Folge, YouTube, lokal) | US2, US14 | FR-001–008, FR-067–073, FR-086–090 | T011–T020, T111–T158 | ✅ |
| 2 | Jede Folge wird verstanden | US1 | FR-014–020 | T028–T036 | ✅ |
| 3 | Die App weiß, was dich interessiert | US7 | FR-038–043 | T047–T054 | ✅ |
| 4 | Folge sieht für dich anders aus / relevante Stellen | US6, US18 | FR-033–037, FR-128–129 | T062–T068, T233–T250 | ✅ |
| 5 | Smart Podcast List | US17 | FR-121–127 | T219–T232 | ✅ |
| 6 | Persönliche Podcasts existieren dauerhaft | US17 | FR-121, FR-126 | T220, T230 | ⚠️ **Lücke 3: Kadenz** |
| 7 | Sieht aus wie ein eigener Podcast (Titel, Shownotes, Kapitel, Cover) | US17, US20 | FR-125, FR-136, FR-139–141 | T227–T228, T255–T260 | ✅ |
| 8 | Gehört wird auf Segmentebene | US19 | FR-130–134 | T025, T237–T252 | ✅ |
| 9 | Chat als zweite Bedienoberfläche | US4 | FR-021–027, FR-065 | T037–T046 | ✅ |
| 10 | Chat steuert direkt den Player | US5 | FR-028–032 | T055–T061 | ✅ |
| 11 | Widerspruchs-Mixer | US15 | FR-091–102 | T159–T182 | ✅ |
| 12 | Highlights und Wissen | US12 | FR-074–076 | T125–T142 | ✅ |
| 13 | Breadcrumb Trail | US16 | FR-103–120 | T183–T218 | ✅ |
| 14 | Wissen verlässt BrainSpeak (Markdown) | US11, US12, US17 | FR-058–061, FR-076, FR-143 | T093–T098 | ✅ |
| 15 | Agent-first (App Intents, adressierbare Objekte) | US8, US12 | FR-056, FR-074 | T084, T126 | ⚠️ **Lücke 2: Onscreen-Kontext** |
| 16 | Systemweite Auffindbarkeit (Spotlight, App Entities) | — | — | — | ❌ **Lücke 1** |
| 17 | macOS-Agentenschnittstelle (MCP) | US13 | FR-083–085 | T143–T148 | ✅ |
| 18 | Native Apple-App, vier Plattformen | US8, US9 | FR-050–057, FR-066 | T080–T092 | ✅ |
| 19 | Privacy-first, Transparenz, Korrigierbarkeit | US7, US10 | FR-039–040, FR-044–049, FR-062–064 | T047–T079 | ✅ |
| 20 | Der entscheidende User Flow | alle | — | — | ✅ (als Ganzes) |

---

## 2. Die drei Lücken

### Lücke 1 — Systemweite Auffindbarkeit (Konzeptkapitel 16) ❌

**Das Konzept sagt:** „App Entities und Spotlight machen beispielsweise eine Erkenntnis auffindbar. Neue persönliche
Ausgaben können dem System außerdem als relevante Inhalte angeboten werden.“

**Das Paket sagt:** Core Spotlight taucht ausschließlich in `plan.md` §3 auf — als **app-interner, wiederaufbaubarer
Index** hinter einem Scope-Gate, für das eigene Retrieval. FR-077/078 beschreiben die Suche *innerhalb* von BrainSpeak.
In `spec.md` kommt „Spotlight“ nicht vor. Es gibt keine Anforderung, Erkenntnisse oder persönliche Ausgaben als
`IndexedEntity` an die **Systemsuche** zu spenden.

**Warum das mehr als eine Feinheit ist:** Der app-interne Index und der Systemindex haben unterschiedliche
Datenschutzkonsequenzen. Ein Inhalt in der Systemsuche verlässt den app-internen Scope — genau die Grenze, die
Constitution VII zieht. Das gehört als ausdrückliche, abschaltbare Entscheidung spezifiziert, nicht als Nebeneffekt
einer Implementierung.

> **Vorschlag FR-145** [US8]: Die App MUSS Erkenntnisse, Highlights und persönliche Ausgaben optional und
> standardmäßig ausgeschaltet als App Entities im Systemindex auffindbar machen; app-interner Index und Systemindex
> bleiben getrennte Einwilligungen; gelöschte, widerrufene oder scopeveränderte Inhalte werden aus beiden entfernt.
> BrainSpeak stellt Relevanz bereit — über tatsächliche Systemvorschläge entscheidet das Betriebssystem; eine
> Platzierung wird nicht zugesagt.

### Lücke 2 — Onscreen-Kontext für App Intents (Konzeptkapitel 15) ⚠️

**Das Konzept sagt:** „wenn gerade ein Abschnitt auf dem Bildschirm sichtbar ist: ‚Spiel diese Stelle.‘ beziehungsweise
‚Merke diese Aussage.‘ Der Nutzer muss also Podcastname und Timecode nicht diktieren.“

**Das Paket sagt:** FR-056 listet App Intents für „Folge/Fokus starten, Stelle merken, Frage vorbereiten und Wissen
öffnen“. FR-074 nennt Highlight-Erfassung „aus Player, Transkript, Watch oder App Intent“. Beide setzen voraus, dass
das Ziel **benannt** wird. Die Auflösung von „diese Stelle“ aus dem sichtbaren Kontext ist nirgends gefordert.

**Warum das wichtig ist:** Genau dieser Schritt unterscheidet „Agent-first“ von „hat halt Shortcuts“. Er berührt aber
die Freigabemechanik: Der sichtbare Kontext darf die Auflösung liefern, nicht die Startfreigabe. Der Grant aus
`focus-playback.md` muss weiterhin aus einer ausdrücklichen Nutzeraktion stammen.

> **Vorschlag FR-146** [US8]: Die App MUSS Segment, Erkenntnis und persönliche Ausgabe als adressierbare Entitäten
> im sichtbaren Kontext bereitstellen, sodass „diese Stelle“ oder „diese Aussage“ ohne Diktat von Titel und Timecode
> aufgelöst wird; die Auflösung erfolgt deterministisch in Swift aus dem angezeigten Zustand. Sichtbarkeit allein ist
> keine Wiedergabefreigabe: der Grant entsteht unverändert nur aus ausdrücklicher Nutzeraktion.

### Lücke 3 — Veröffentlichungsrhythmus persönlicher Ausgaben (Konzeptkapitel 6) ⚠️

**Das Konzept sagt:** „Morning Knowledge — 20 Minuten, nur Neues seit gestern“ und „BrainSpeak erstellt daraus
**regelmäßig** neue persönliche Ausgaben, **sobald genügend** relevante, noch nicht gehörte Inhalte vorhanden sind.“

**Das Paket sagt:** FR-124 regelt, *woraus* publiziert werden darf. FR-126 trennt „alles Ungehörte“ vom budgetierten
Modus. FR-142 fordert atomaren Commit vor optionaler Benachrichtigung. **Wann** und **wie oft** publiziert wird,
regelt keine Anforderung. In `smart-podcast-list.md` kommt kein Zeitplanbegriff vor.

**Warum das nicht nachrüstbar ist:** iOS-Hintergrundintervalle sind ausdrücklich nicht garantiert (Constitution IX).
Ein Produktversprechen „morgens um sieben“ kollidiert mit opportunistischem BGAppRefresh. Das muss vorne entschieden
werden — als ehrlicher Zustand („bereit seit …“) statt als unhaltbare Zusage.

> **Vorschlag FR-147** [US17]: Die App MUSS je Feed einen Veröffentlichungsauslöser konfigurierbar machen —
> Mindestmaterial, Zeitfenster oder manuell — und dessen tatsächliche Erfüllung als eigenen Zustand anzeigen
> („bereit seit …“, „wartet auf Material“, „Analyse unvollständig“). Feste Hintergrundzeitpunkte werden nicht
> zugesagt; ein verpasstes Fenster erzeugt keine stille Doppelausgabe. Publikation und Benachrichtigung starten
> weiterhin nie Ton (FR-129).

---

## 3. Was aus dem Konzept ausdrücklich **gut** abgedeckt ist

Diese Punkte sind im Paket präziser geregelt, als das Konzept sie formuliert — hier ist keine Nacharbeit nötig:

* **„Vom Nutzer bestätigt ≠ von BrainSpeak vermutet“** (Kap. 3) → vier getrennte Kategorien in FR-038, und in
  `contradiction-mixer.md` ein eigener Typ `Stance` mit Status `proposed|confirmed|rejected|withdrawn`. Nur
  `confirmed` mit Herkunft `explicitUser` darf Nutzerposition heißen.
* **„Dazwischen werden keine künstlichen Aussagen erzeugt“** (Kap. 4) → FR-135 verbietet KI-Nachsprache und gesprochene
  Überleitungen; FR-036 verlangt, dass ein Quellenwechsel sichtbar ist und kein nahtloser Sprecherzusammenschnitt entsteht.
* **Gemeinsamer Hörzustand** (Kap. 8) → FR-130 vereinigt abgespielte Intervalle je MediaVersion global und schließt
  Seek, Download, Analyse, Lesen und Buffering ausdrücklich aus. FR-131 lässt Fokuswiedergabe nicht die ganze Folge
  als gehört markieren.
* **„Widerspruchs-Mixer darf vermutete Standpunkte nicht als Tatsachen darstellen“** (Kap. 11) → FR-101 verbietet
  zusätzlich, auf Meinungsänderung, Empörung oder Hörzeit zu optimieren.
* **Eigenes Cover** (Kap. 7) → FR-139–141 trennen sauber: natives Layoutcover sofort und automatisch,
  Image Playground **nur** über nutzergeführten Systemdialog, `ImageCreator` ab 27 ausgeschlossen.
* **Sprecherzuordnung** (Kap. 2, „Sprecher/Abschnitte“) → FR-019 und FR-076 benennen unbestätigte Sprecher nicht;
  Sprechercluster sind ausdrücklich keine Personenidentifikation. Das Konzept verspricht hier mehr, als
  SpeechAnalyzer liefert — das Paket korrigiert das bereits in die richtige Richtung.

---

## 4. Wenn die Lücken aufgenommen werden

FR-145–147 sind **Vorschläge**, keine beschlossenen Anforderungen. Das Änderungsverfahren der Constitution verlangt,
Version, Änderungsgrund, `spec.md`, `plan.md`, `contracts/`, `tasks.md` und Tests **gemeinsam** zu aktualisieren.
Konkret wären das:

| FR | Meilenstein | Grober Umfang | Neue Artefakte |
|---|---|---|---|
| FR-145 Systemindex | M8b (US8) | 4–6 Aufgaben | Einwilligungsschalter, Donation/Widerruf, Löschpfad, Abnahmefall |
| FR-146 Onscreen-Kontext | M8b (US8) | 3–4 Aufgaben | Entity-Exposition je Ansicht, Auflöser, Grant-Abgrenzungstest |
| FR-147 Kadenz | M8a (US17) | 4–5 Aufgaben | Auslöserkonfiguration, Zustandsanzeige, Doppelausgaben-Test |

Damit stiege das Paket auf 147 FR und rund 277 Aufgaben. Alternativ schließt ein ADR die drei Punkte ausdrücklich
aus — dann steht im Konzepttext, was die App bewusst **nicht** tut. Beides ist vertretbar; unentschieden bleiben ist es nicht.
