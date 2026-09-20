# Umsetzungsplan — BrainSpeak, der AI-First Knowledge Podcast Player

**Stand:** 2026-09-20 · **Basis:** Spec-Kit-Paket v1.3 (144 FR · 20 US · 266 Tasks), in diesem Repository eingecheckt
**Gültigkeit:** Dieser Plan ordnet an und priorisiert. Er ändert keine Anforderung. Änderungen am Umfang folgen dem
Änderungsverfahren der [Constitution](../.specify/memory/constitution.md).

---

## 1. Was gebaut wird

Ein klassischer Player beantwortet „Was möchte ich hören?“. BrainSpeak beantwortet zusätzlich
**„Was davon sollte ich wissen?“** — und kann die Antwort als Originalaudio abspielen.

Vier Versprechen, gegen die dieser Plan geschnitten ist:

| # | Versprechen | Ohne das ist das Produkt kein BrainSpeak |
|---|---|---|
| V1 | **Jede Aussage hat eine Herkunft.** Erkenntnis → Folge → Medienfassung → Timecode → Originaltext | Dann ist es ein KI-Zusammenfasser |
| V2 | **Nur relevante Originalstellen hören.** Sprünge statt Vollfolge, ohne KI-Nachsprache | Dann ist es ein normaler Player mit Kapiteln |
| V3 | **Smart Podcast List.** Persönliche Ausgaben aus ungehörten Originalsegmenten über Quellen hinweg | Dann fehlt das stärkste sichtbare Merkmal |
| V4 | **Ein gemeinsamer Hörzustand auf Segmentebene.** Gehört bleibt gehört — feedübergreifend | Dann wiederholt sich das persönliche Update und verliert Vertrauen |

V1 und V2 sind der kritische Pfad. V3 baut vollständig auf ihnen auf. V4 ist die Invariante, die V3 erst glaubwürdig macht.

---

## 2. Ausgangslage

* Das Repository war leer. Das Spec-Kit-Paket v1.3 liegt jetzt unverändert im Wurzelverzeichnis und validiert als Dokumentpaket.
* **Alle 266 Aufgaben sind offen.** Es existiert kein Apple-Build, kein Gerätetest, keine Modellinferenz.
* Drei Nachweise sind ungeklärt und bestimmen alles Weitere — sie sind Meilenstein M0, nicht eine Randnotiz:
  * der **BrainSpeak-Checkout** (bisher 404, siehe [references/research-limitations.md](../references/research-limitations.md)),
  * die **Xcode-27-/Swift-6.4-Toolchain** mit vier echten 27er-SDKs,
  * das **PCC-Entitlement** des konkreten Entwicklerkontos.

---

## 3. Struktur: ein Rückgrat, danach parallele Tracks

Die Abhängigkeiten im Paket sind ausgewertet, nicht geschätzt. Ergebnis:

```
M0 Grundlagen  T001–T010
      │
      ▼   ← RÜCKGRAT: streng seriell, jede Stufe endet auf echter Hardware
M1 US2 Quellen         T011–T020
M2 US3 Originalaudio   T021–T027   ← hier entsteht ListeningHistory (T025), Fundament für V4
M3 US1 Folge verstehen T028–T036
M4 US4 Chat mit Beleg  T037–T046 ──────────────┐
M5 US7 Interessen      T047–T054               │
M6 US5+US6 Fokus       T055–T068               │
M7 US10 Zuverlässigkeit T069–T079              │
      │                                        │
      ├──────────────┬───────────────┬─────────┴──────┐
      ▼              ▼               ▼                ▼
 M8a SMART      M8b US8/US9     M8c US11 Export   (US11 braucht nur T046)
 PODCAST LIST   Plattformen     T093–T098
 T219–T266      T080–T092             │
      │              │                ▼
      │              ▼           M9b US15/US16 Mixer + Breadcrumb
      │         M9a US12/13/14   T159–T218 (braucht T098 + T079)
      │         T111–T158
      └──────────────┴───────────────┴────────────────┘
                     ▼
              M10 Release-Gates T099–T110
```

**Abhängigkeitsbefunde, auf denen diese Struktur beruht** (aus `specs/001-ai-podcast-player/tasks.json`):

| Block | Braucht von außen | Folgerung |
|---|---|---|
| Smart Podcast List (T219–T266) | nur T006, T010, T025, T043, T061, T068, T079 | **Nichts aus US8, US9, US11, US12–16.** Vorziehbar. |
| US12/13/14 (T111–T158) | nur T010, T086 | Hängt an einer einzigen US8-Aufgabe, sonst frei. |
| US15/US16 (T159–T218) | T010, T054, T061, T068, T079, **T098** | Muss nach dem Export kommen. |
| US11 Export (T093–T098) | T005–T008, T010, **T046** | Direkt nach dem Chat möglich. |
| US9 Watch (T088–T092) | T005–T008, T010, T068, **T087** | Erst nach US8. |
| T099 Release-Builds | 86 Vorgänger | Einziger Big-Bang-Punkt — siehe §7. |

---

## 4. Meilensteine

Jeder Meilenstein endet mit einer **Nachweisdatei**, nicht mit einer Erfolgsbehauptung. Das Paket sieht dafür je
Nutzerablauf bereits eine Abschlussaufgabe vor (`validation/device/USx.md`); dieser Plan macht sie zum Gate.

### M0 — Fundament und Nachweise · T001–T010 · 10 Aufgaben

**Ziel:** Die drei Unbekannten auflösen, bevor Architekturentscheidungen teuer werden.

| Aufgabe | Ergebnis |
|---|---|
| T001 | `audit/brainspeak-baseline.md` — echte Pfade, Targets, Lizenz, Migrationsrisiken. Keine erfundenen Klassen. |
| T002 | `config/toolchain-lock.json` aus echten Ausgaben von `scripts/probe-apple-sdk.sh` |
| T003 | `audit/pcc-eligibility.md` — Konto-Berechtigung und Gerätefähigkeit **getrennt** |
| T004 | `audit/integration-map.md` — Zielmodule ↔ reale BrainSpeak-Module, je Abweichung ein ADR |
| T005–T010 | Domain-Invarianten, SwiftData + Outbox, Test-Doubles, CapabilityRegistry, vier App-Shells, Testkonfiguration |

**Exit-Gates:** GATE-BS, GATE-SDK, GATE-PCC (§6)
**Entscheidungspunkt:** D1 und D2 aus [03-risiken-und-entscheidungen.md](03-risiken-und-entscheidungen.md) müssen hier fallen.
**Wenn M0 scheitert:** Ohne Checkout ist Constitution II nicht erfüllbar — dann braucht es einen ausdrücklichen ADR
„Greenfield statt BrainSpeak-first“, keine stille Neuentwicklung.

### M1 — Quellen aufnehmen · T011–T020 · US2 · 10 Aufgaben

RSS, Einzelfolge, lokale Datei; SourceResolver mit getrennten Rechte-/Fähigkeitsflags; XMLParser gehärtet
(externe Entitäten aus, Größenlimit, Redirect-/Hostprüfung); Download über URLSession in atomaren FileStore;
MediaVersion erst nach Validierung mit Hash finalisiert.

**Exit:** `validation/device/US2.md` — Abo ohne Zwang zum Download, Folge liegt reproduzierbar vor.
**Noch nicht enthalten:** YouTube (das ist US14 in M9a). Bewusst: erst die Rechte- und Identitätsmechanik, dann der Sonderfall.

### M2 — Vollwertig hören · T021–T027 · US3 · 7 Aufgaben

AVFoundation hinter **einem** PlaybackCoordinator, Kapitel, Routenwechsel, Remote Commands.
Die wichtigste Aufgabe ist **T025 `ListeningHistory.swift`**: Hörposition, tatsächlich gehörte Zeitintervalle,
KI-Verarbeitung und gelesene Erkenntnisse getrennt speichern.

> **Warum T025 der Dreh- und Angelpunkt ist:** Versprechen V4 („gehört bleibt gehört, feedübergreifend“) ist später
> nicht nachrüstbar. Wer hier nur einen `played`-Bool schreibt, kann die Smart Podcast List nicht bauen, ohne die
> Historie zu verwerfen — das Paket sieht dafür ausdrücklich `historyQuality=unknown` vor.
> Seek, Download, Analyse, Lesen und Buffering zählen **nie** als gehörte Zeit (FR-130).

**Exit:** `validation/device/US3.md` — erste demonstrierbare App. Hier lohnt der erste interne Release-Zug (R1).

### M3 — Eine ungehörte Folge verstehen · T028–T036 · US1 · 9 Aufgaben

Publisher-Transkript prüfen (Vollständigkeit, Sprache, Fassungsbezug), sonst SpeechAnalyzer/SpeechTranscriber mit
Checkpoint und deduplizierter Überlappung. Danach Segmente → Claims → Evidence-IDs → Coverage-Status.
Ungetakteter Text liefert Wissen, aber **deaktiviert** zeitgenaue Wiedergabe (FR-019).

**Exit:** GATE-BG (Hintergrundanalyse-Realität), `validation/device/US1.md`, plus **T100 vorgezogen**: eine lange
reale Audiofolge auf zwei Vollclients transkribieren und Timing, Abdeckung und Abbrüche messen.

### M4 — Beleggebundener Chat · T037–T046 · US4 · 10 Aufgaben

AppleModelRouter (ausschließlich SystemLanguageModel und PCC), RetrievalService mit unveränderlichem
ChatScopeSnapshot, EvidenceSweep für Vollständigkeitsfragen mit eigenem CoverageLedger.
Das Modell wählt **IDs**, Swift löst Zeiten, Rechte, Scope und Fassung auf.

**Exit:** GATE-PCC zur Laufzeit, `validation/device/US4.md`, **T101 vorgezogen**: Apple Evaluations lokal und auf PCC
getrennt, inklusive Kontingent-, Offline- und Modellwechselpfad.

### M5 — Interessen verstehen und korrigieren · T047–T054 · US7 · 8 Aufgaben

Bestätigte Interessen, vorgeschlagene Interessen, aktuelle Vorhaben und offene Fragen bleiben **vier getrennte
Kategorien** (FR-038). „Warum empfohlen“ nennt die konkrete Zuordnung; „Bereits bekannt“, „Mehr davon“,
„Nicht relevant“ und „Nicht aus dieser Quelle“ wirken unterschiedlich (FR-040). Personalisierung ist opt-in.

### M6 — Fokuswiedergabe · T055–T068 · US5 + US6 · 14 Aufgaben

**Der technisch riskanteste Meilenstein.** `PlaylistProposal` ist untrusted Modelloutput; `FocusPlanner` löst auf,
prüft Edition/Scope/Rechte/Timing, erweitert auf Satzkontext, vereinigt Überlappungen und budgetiert echte Medienzeit;
Ergebnis ist ein unveränderlicher `ValidatedPlaybackPlan` mit Hash. `PlaybackPolicy` erzeugt einen kurzlebigen,
gerätegebundenen Grant **nur** aus ausdrücklicher Nutzeraktion.

Bekannte Fallen, die hier explizit getestet werden: Zeitbeobachter sind kein Sicherheitsendanschlag
(`forwardPlaybackEndTime` plus Lifecycle-Token), nicht seekbare Streams dürfen nicht als exakt verkauft werden,
Quellenwechsel ist sichtbar und darf kein nahtloser Sprecherzusammenschnitt sein (FR-036).

**Exit:** GATE-PLAY (§6) — Fokusgrenzen und veraltete Callbacks an realen Audioausgängen bei verschiedenen
Wiedergaberaten messen (**T102 vorgezogen**), `validation/device/US5.md` + `US6.md`.
**Hier ist V1 und V2 erfüllt.** Release-Zug R2.

### M7 — Zuverlässigkeit, Persistenz, Sync · T069–T079 · US10 · 11 Aufgaben

CKSyncEngine als **einziger** Sync-Writer der definierten Recordtypen, Outbox und Tombstones im selben Commit,
ConflictCopy statt Textverlust, append-only Lernsignale mit ResetEpoch, Abspielposition mit SessionID und monotoner
Sequenz (größte Sekunde ist bei Rewind falsch).

**Exit:** GATE-SYNC (**T103 vorgezogen**: zwei echte Geräte, Offline-Rückkehr, Reset-Epoch), `validation/device/US10.md`.

### M8a — Smart Podcast List · T219–T266 · US17–US20 · 48 Aufgaben ← **vorgezogen**

`BrainSpeakSmartFeeds` mit FeedStore, FeedScope, UnheardSegmentResolver, PersonalEpisodePublisher,
EpisodeSnapshotStore, ShownotesBuilder, NativeCoverRenderer, CoverArtworkCoordinator.

Publisher-Reihenfolge, transaktional gegen Absturz und wiederholtes Scheduling abgesichert:

```
Scope prüfen → finale Evidence wählen → globales Ledger / Reservierung prüfen
  → unveränderliches Manifest committen → Shownotes + natives Fallback-Cover
  → Ausgabe publizieren → optionale Benachrichtigung
```

Drei Regeln, die hier nicht verhandelbar sind:
* **Publikation startet nie Ton.** Eine neue Ausgabe ist ein Zustand, kein Ereignis mit Audio (FR-129).
* **Publiziertes wird nicht heimlich umgebaut.** Neue Segmente erzeugen eine neue Revision, nie ein geändertes Manifest (FR-127).
* **Automatisches Layoutcover ≠ Image Playground.** Der native Renderer liefert sofort; Image Playground nur über
  nutzergeführten Systemdialog, Apple-Stile, kein `ImageCreator` (FR-139–141, GATE-COVER).

**Exit:** GATE-LEDGER und GATE-COVER (§6), Abnahmen FR-121–144.
**Hier ist V3 und V4 erfüllt.** Release-Zug R3 — das ist die erste Ausbaustufe, die das Konzept sichtbar macht.

### M8b — Native Plattformen · T080–T092 · US8 + US9 · 13 Aufgaben

iPad als adaptiver NavigationSplitView mit Inspector; Mac als native App mit Multiwindow, Commands, Tabelle;
Watch als eigenständige SwiftUI-Shell mit Offline-Pack und kurzem PCC-Weg — **kein erfundenes lokales Watch-Modell**.
App Intents führen dieselben Policies aus wie die Oberfläche.

**Exit:** GATE-DEVICE je Plattform, `validation/device/US8.md` + `US9.md`, **T104/T105 vorgezogen**.

### M8c — Wissen exportieren · T093–T098 · US11 · 6 Aufgaben

`MarkdownExportService` mit explizitem ExportScope. `SafeSourceLink` entsteht aus allowlist-geprüfter kanonischer
Quelle — **nicht** durch kosmetisches Entfernen von Querystrings. Private Feedtoken gelangen nie in Exporte, Logs
oder den KI-Kontext. Ohne sicheren externen Link: Titel, Provider, Folge, interner Anker mit Originalzeit.

### M9a — YouTube, Highlights, Suche, MCP · T111–T158 · US12 + US13 + US14 · 48 Aufgaben

Ein normaler YouTube-Link genügt: Video → Kanal → Feed automatisch auflösen, danach Abo, Einzelimport oder
rückwirkende Kataloganalyse als **drei getrennte Entscheidungen**. Feedfenster und Gesamtarchiv sind nicht dasselbe;
gefundene und inhaltlich analysierbare Folgen werden getrennt gezählt.
Dazu Highlights, native semantische Suche, SRT/VTT/TXT/JSON, Smart Skip und der opt-in MCP-Zugang auf dem Mac
(lesen/suchen/Quellen abrufen ist etwas anderes als Interessen ändern oder Wiedergabe starten).

**Exit:** GATE-YT — sichtbare, offizielle Wiedergabe; keine DOM-Audioextraktion, kein Hintergrund-IFrame,
kein Scraping geschützter Captions.

### M9b — Widerspruchs-Mixer und Breadcrumb-Trail · T159–T218 · US15 + US16 · 60 Aufgaben

`CounterpointMatcher` über denselben scopegebundenen Retrieval-Layer; Quelle, Standpunkt und Zustimmung sind
**verschiedene Typen** — ein Highlight erzeugt keine Zustimmung. SensitiveTopicPolicy verhindert individualisierte
politische Überzeugungsprofile. `SessionBoundaryPolicy` erkennt nur bewusste Enden; die Abschlusskarte
Vertiefen/Parken/Verwerfen erscheint einmalig und ist überspringbar. `ParkCommitCoordinator` schreibt einen
gefrorenen Graph-/Markdown-Snapshot mit eigenem Exportstatus — nicht direkt aus dem Modell.

**Exit:** Abnahmen FR-091–120, `validation/device/US15.md` + `US16.md`. Release-Zug R4 (Beta).

### M10 — Release-Gates · T099–T110 · 12 Aufgaben

Vier 27er-Release-Builds (T099), danach die Nachweise, die nicht schon vorgezogen wurden, dann T109
Spec–Plan–Tasks–Code–Tests-Konvergenz und T110 Releaseentscheidung als Protokoll — mit bekannten Grenzen,
ohne ungeprüfte Erfolgsbehauptung. Release-Zug R5.

---

## 5. Release-Züge

| Zug | Nach | Was ein Mensch damit tun kann | Publikum |
|---|---|---|---|
| R1 | M2 | Abonnieren und eine Folge vollständig hören | Team intern |
| R2 | M6 | Fragen stellen, Belege sehen, **nur die relevanten Originalstellen hören** | Interne Alpha |
| R3 | M8a | **Eigene Themen-Podcasts abonnieren und abspielen** | Geschlossene Alpha |
| R4 | M9b | Vier Plattformen, YouTube-Historie, Mixer, Breadcrumb, Export | Beta |
| R5 | M10 | Vollständiger Umfang mit geprüften Gates | Release-Entscheidung |

R2 und R3 sind die beiden Punkte, an denen sich das Produktversprechen bestätigt oder widerlegt. Alles davor ist
Infrastruktur, alles danach ist Breite.

---

## 6. Gates

`plan.md` benennt Gates in Prosa, `tasks.md` vergibt dafür aber keine IDs. Diese Tabelle schließt die Lücke und
ordnet jedem Gate Meilenstein, prüfende Aufgabe und Nachweisdatei zu.

| Gate | Prüft | M | Aufgabe | Nachweis | Blockiert bei Fehlschlag |
|---|---|---|---|---|---|
| GATE-BS | BrainSpeak-Checkout lesbar, Lizenz, Targets | M0 | T001, T004 | `audit/brainspeak-baseline.md` | Integration (nicht: Spezifikation) → ADR nötig |
| GATE-SDK | Xcode 27 / Swift 6.4, vier 27er-SDKs, Symbole vorhanden | M0 | T002, T086 | `config/toolchain-lock.json` | Jede neue API-Verwendung |
| GATE-PCC | Konto-Entitlement **und** Gerätefähigkeit getrennt | M0/M4 | T003, T101 | `audit/pcc-eligibility.md` | Große Synthesen, Mehrfolgenvergleich |
| GATE-BG | Hintergrundinferenz unter echten OS-Ressourcenregeln | M3 | T106 | `validation/performance.md` | Zusage „analysiert über Nacht“ |
| GATE-PLAY | Fokusgrenzen, stale Callbacks, Wiedergaberaten | M6 | T102 | `validation/playback-boundaries.md` | V2 — Kernversprechen |
| GATE-SYNC | CloudKit-Konflikte, Löschung, Offline, Reset-Epoch | M7 | T103 | `validation/cloudkit.md` | Mehrgerätebetrieb |
| GATE-LEDGER | Globale Intervallvereinigung, keine Dubletten über Feeds | M8a | T237–T252 | `validation/device/US19.md` | V4 — Vertrauen in persönliche Ausgaben |
| GATE-COVER | Image-Playground-Systemdialog, atomare Übernahme vor Ablauf | M8a | T255–T260 | `validation/device/US20.md` | Nur Cover, nicht die Ausgabe |
| GATE-YT | Sichtbare offizielle Wiedergabe, keine Extraktion | M9a | T107 | `validation/compliance.md` | YouTube als Quelle |
| GATE-DEVICE | Vier echte Plattformen, Accessibility, Lokalisierung | M8b/M10 | T104, T105 | `validation/accessibility.md`, `validation/watch.md` | Release |

**Regel für alle Gates:** Ein nicht ausgeführter Test bleibt offen. Ein bestandenes Dokumentpaket-Skript ersetzt
keinen Apple-Build. Jeder Nachweis dokumentiert Hardware, OS, Modellstand, Prompt-/Indexrevision und Bedingungen.

---

## 7. Bewusste Abweichungen von der Task-Nummerierung des Pakets

Die Task-IDs des Pakets sind stabil und werden **nicht** umnummeriert. Abweichend ist nur die Ausführungsreihenfolge —
`tasks.md` sagt dazu selbst: „IDs sind stabil und nicht als strikte Ausführungsreihenfolge zu verstehen.“

| # | Abweichung | Begründung |
|---|---|---|
| A1 | **Smart Podcast List (T219–T266) vor** US8/US9, US11, US12–16 | Externe Abhängigkeiten sind vollständig ≤ T079. Es ist das stärkste Produktmerkmal; es zuletzt zu bauen hieße, das Konzept zuletzt zu validieren. |
| A2 | **Gerätenachweise T100–T106 werden auf die Meilensteine verteilt**, statt gesammelt nach T099 zu laufen | T099 hat 86 Vorgänger. Ein Big-Bang-Gate am Ende verschiebt genau die Erkenntnisse nach hinten, die früh billig zu korrigieren wären. T099 bleibt als Release-Build bestehen. |
| A3 | **US11 Export (T093–T098) direkt nach US4** möglich | Braucht extern nur T046. Zieht das Markdown-Sicherheitsmodell (SafeSourceLink, Tokenausschluss) früh ins Licht. |
| A4 | **US14 YouTube nicht in M1** | T111–T158 hängt an T086. Erst die Rechte-/Identitätsmechanik am unstrittigen RSS-Fall, dann der Sonderfall mit eigener Rechtslage. |

Wird A1 oder A2 verworfen, bleibt der Plan gültig — die Meilensteine M8a und M10 tauschen dann die Position.

---

## 8. Aufwand — Szenario, keine Zusage

Ohne M0 gibt es keine belastbare Schätzung: der Anteil wiederverwendbarer BrainSpeak-Bausteine ist unbekannt.
Was ohne M0 sagbar ist, ist die **Struktur** des Aufwands.

| Meilenstein | Aufgaben | davon Abnahmevorbereitung | Anteil |
|---|---|---|---|
| M0 Grundlagen | 10 | 0 | 4 % |
| M1–M7 Rückgrat | 69 | 28 | 26 % |
| M8a Smart Podcast List | 48 | 17 | 18 % |
| M8b Plattformen + M8c Export | 19 | 7 | 7 % |
| M9a YouTube/Highlights/MCP | 48 | 16 | 18 % |
| M9b Mixer + Breadcrumb | 60 | 21 | 23 % |
| M10 Release-Gates | 12 | 0 | 5 % |
| **Summe** | **266** | **89** | |

Ein Drittel aller Aufgaben (89 von 266) ist Abnahmevorbereitung **vor** der Implementierung. Das ist Absicht und
sollte nicht als Puffer missverstanden werden.

*Illustratives Kalenderszenario unter ausdrücklichen Annahmen* — drei Apple-Entwickelnde in Vollzeit, eine Person
Design/Produkt zur Hälfte, Hardware für vier Plattformen vorhanden, PCC-Entitlement erteilt, BrainSpeak zu etwa
einem Drittel wiederverwendbar: **R2 nach rund vier Monaten, R3 nach rund sechs, R5 nach neun bis zwölf.**
Jede dieser Annahmen ist heute unbelegt. Die Spanne verengt sich mit M0, nicht mit mehr Planung.

---

## 9. Arbeitsweise

**Schleife je Aufgabe** — so ist das Paket geschnitten, das ist keine zusätzliche Zeremonie:
Abnahmefall zuerst schreiben (`Tests/Acceptance/...`) → implementieren (`Packages/...`) → Nachweis ausführen →
erst dann `[x]` in `tasks.md` und `status` in `tasks.json`.

**Definition of Done für eine Aufgabe**
1. Abnahmefall aus `acceptance-cases.json` läuft grün, inklusive der Fehlzustände.
2. Keine erfundene API: jedes neue Framework-Symbol ist durch eine Compile-Probe belegt.
3. Rechte-, Scope- und Freigabeentscheidungen liegen in Swift-Policy, nicht in einem Prompt.
4. Unbekanntes ist ein sichtbarer Zustand, kein stiller Fallback auf einen anderen Anbieter.

**Definition of Done für einen Meilenstein**
Alle Aufgaben erledigt, das zugehörige Gate aus §6 mit Nachweisdatei geschlossen **oder** ausdrücklich als blockiert
protokolliert, `traceability.csv` aktualisiert, und jede in diesem Meilenstein berührte FR hat eine Ergebnisdatei.

**Vier Leitplanken, die jede Abkürzung überstimmen**
* Nur Apple-Modelle. Kontingentende, fehlende Hardware und Offline sind ehrliche Zustände, keine Erlaubnis für einen fremden Anbieter.
* Das Modell wählt IDs. Zeiten, Rechte, Scope und Fassung löst Code auf.
* Automatisch vorbereiten, bewusst abspielen. Eine Empfehlung allein startet niemals Ton.
* Gespeichert oder gehört heißt nicht zugestimmt.

---

## 10. Nächste konkrete Schritte

1. **D1 und D2 entscheiden** (Checkout-Zugang, PCC-Antrag) — beides hat Vorlaufzeit und blockiert M0.
2. **Mac mit Xcode 27 bereitstellen** und `bash scripts/probe-apple-sdk.sh` laufen lassen; Ausgabe nach `validation/apple-sdk/`.
3. **T001 starten**: BrainSpeak read-only inventarisieren, `audit/brainspeak-baseline.md` füllen.
4. **D6 entscheiden**: die drei Konzeptlücken (§ [02-konzept-abdeckung.md](02-konzept-abdeckung.md)) als FR-145–147 aufnehmen oder per ADR ausschließen.
5. Erst danach Code in `Packages/BrainSpeakDomain`.
