# Implementation Plan: BrainSpeak Podcasts / Apple 27

**Branch:** `001-ai-podcast-player` · **Date:** 2026-09-19 · **Input:** `spec.md`

## Summary
BrainSpeak um einen quellenfähigen Medien-/Wissenskern und native Plattform-Shells erweitern. Audio wird unabhängig vom Hören zu versionierten Belegen verarbeitet. Apple Intelligence erzeugt strukturierte Aussagen und Vorschläge; reine Swift-Policy entscheidet über Datenzugriff, Export und Wiedergabe. Fokuslisten referenzieren Originalmedien statt generierter Zusammenschnitte.

## Technical Context

| Bereich | Beschluss |
|---|---|
| Sprache/Toolchain | Swift-6.4-Compiler, Swift-6-Modus, Xcode 27; tatsächliche Builds im Lockfile. [A01, A02] |
| Ziele | iOS/iPadOS/watchOS/macOS mindestens 27.0; Mac als native macOS-App, nicht Catalyst. |
| UI | SwiftUI, neue State-Semantik und ContentBuilder, Observation, plattformnative Navigation und aktuelle Systemmaterialien. [A03, A04, A24] |
| Nebenläufigkeit | async/await, AsyncSequence, strukturierte Tasks, actors; MainActor nur UI/Player-adaptergebunden. |
| Persistenz | SwiftData lokal; expliziter, alleiniger CKSyncEngine-Owner für ausgewählte Sync-Records. [A12–A14] |
| Audio | AVFoundation/AVKit; AVPlayer bzw. AVQueuePlayer hinter einem PlaybackCoordinator; nicht zwei Audioengines. [A17] |
| Analyse | SpeechAnalyzer/SpeechTranscriber für zugängliche Audiodateien auf geeigneten Vollclients; Sprache/Assets getrennt prüfen. [A11] |
| Wissen | SwiftData als Wahrheit; Core Spotlight als rebuildbarer App-Index, SpotlightSearchTool hinter Scope-Gate. [A10] |
| Modelle | SystemLanguageModel und PCC; neue DynamicProfiles nur innerhalb einer expliziten App-State-Machine. [A05–A09] |
| Watch | eigenständige SwiftUI-Shell, lokale Audio-/Wissenspacks, direkter kurzer PCC-Weg bei Verfügbarkeit, Companion nur sichtbar. [A06, A21, A23] |
| Qualität | Swift Testing, XCUITest für Plattformintegration, Apple Evaluations für Modellverhalten. [A19, A20] |
| Laufzeitabhängigkeiten | ausschließlich Apple-SDKs; keine Drittanbieter-Laufzeitpackages ohne geänderten Beschluss. |

## Constitution Check
Alle zehn Prinzipien berücksichtigt. Offene Nachweise sind Gates, keine Ausnahmen: GATE-BS (Baseline), GATE-SDK (27-Compile), GATE-PCC (Account/Runtime), GATE-BG (Hintergrundinferenz), GATE-YT (sichtbare Wiedergabe), GATE-SYNC (CloudKit-Konflikte), GATE-DEVICE (vier echte Plattformen).

## Zielstruktur — erst nach Audit auf echte Pfade abbilden

```text
Apps/
  BrainSpeakMobile/          # iOS + iPadOS shell
  BrainSpeakMac/             # native macOS shell
  BrainSpeakWatch/           # native watchOS shell
  BrainSpeakWidgets/        # target-specific widgets
  BrainSpeakShare/          # import handoff; no long AI jobs
Packages/
  BrainSpeakDomain/          # IDs, versioned values, scope, policies
  BrainSpeakPersistence/     # SwiftData, migrations, outbox, tombstones
  BrainSpeakSources/         # RSS, Atom, OPML, auth references
  BrainSpeakMedia/           # downloads, media versions, chapters
  BrainSpeakIntelligence/    # Speech, retrieval, Apple models, evidence checks
  BrainSpeakPlayback/        # coordinator, focus plans, media adapters
  BrainSpeakSync/            # CKSyncEngine, merge, WatchConnectivity
  BrainSpeakFeatures/        # shared presentation models, native views
  BrainSpeakExport/          # safe Markdown and portable manifests
Tests/
  Unit/ Integration/ UI/ Evaluations/
```

Keine Behauptung, diese Pfade existierten bereits in BrainSpeak. `audit/brainspeak-baseline.md` erstellt die reale Mappingtabelle. Domain-Werte sind Codable/Sendable-Structs; keine SwiftData-ModelContext-Objekte über Actor-Grenzen schicken. Adapter implementieren schmale Protokolle. Ein DI-Composition-Root pro App injiziert Dienste; keine globalen Singleton-Netze.

## 1. Quellen und Netzwerk
SourceResolver klassifiziert RSS, Atom, Episodenlink und lokale Datei. Rechte-/Fähigkeitsprofil enthält unabhängige Flags und Gründe. Feedidentität, Episode und Medienfassung werden nicht verwechselt. Private URLs bleiben intern; Share-/Exportpfad ist ein anderer Datentyp.

Foundation-XMLParser wird mit deaktivierter externer Entitätsauflösung, Größenlimits und Namespace-Behandlung eingesetzt. Downloads nutzen URLSession und atomaren FileStore. HTTP-Validatoren optimieren Traffic, beweisen aber keine Audioidentität. Redirects prüfen Schema, Hostwechsel und Credentialweitergabe. Keine pauschale ATS-Ausnahme, kein beliebiger localhost/private-IP-Fetch aus einem Feed.

Der YouTube-Adapter übernimmt Kanal-Atomhinweise und Video-IDs. Unaufgelöste Handles werden nicht durch unsichere Scraping-Dienste ergänzt. Bei fehlendem kanonischem Feed ist eine verständliche Korrektur möglich. Auf Vollclients kann ein sichtbarer, isolierter offizieller Player über natives WebKit eingebettet werden; keine Web-App-Shell. Auf Watch Übergabe/Öffnen auf Vollclient. Nur unterstützte offizielle Playerparameter, keine Manipulation von Werbung oder DOM-Audioextraktion. [Y01–Y03, A22]

## 2. Medien und Transkription
Download-Job schreibt in eine temporäre Datei; erst nach Validierung wird eine MediaVersion mit Hash abgeschlossen. Bytehash ist verfügbar, sobald die gesamte Variante vorliegt; vorher ist Identität provisional. Große Audiofiles werden nicht vollständig als Data in RAM gehalten. PCM-Konvertierung erfolgt chunkweise per Apple-Audio-APIs.

Publisher-Transkript zuerst auf Vollständigkeit, Sprache, Format und Fassungsbezug prüfen. Nicht getakteter Text kann Wissen liefern, aber keinen exakten Fokus. Bei Audioanalyse liefert Speech die finalen Textbereiche mit Medienzeit. Der Checkpoint umfasst Sampleposition/Segmentcommit, Asset-ID, Locale, Analysekonfiguration und Textrevision. Modellinterner Zustand wird nicht als dauerhaft serialisierbar vorausgesetzt; Wiederaufnahme kann einen kleinen konfigurierten Überlappungsbereich neu transkribieren, der dedupliziert wird. [A11]

## 3. Wissensmodell und Retrieval
SwiftData speichert finalisierte Segmente, Claims und Relations. Rebuildbare Spotlight-Items sind kurze eigenständige Abschnitte mit stabilen IDs, Quell-/Folgen-/Revisionsmetadaten und Datum. Umfangreicher Fließtext bleibt im Store. Aktualisierung über explizite Outbox bzw. History; Indexverzug wird im Coverage-Status sichtbar. [A10, A12]

`RetrievalService` bekommt einen unveränderlichen ChatScopeSnapshot. Ein Modell darf eigene Suchbegriffe vorschlagen; jede zurückgegebene ID wird danach deterministisch gefiltert. SpotlightSearchTool erschließt nur den eigenen App-Index. Direkte unbeschränkte Tools erhalten nie Zugriff auf die gesamte Fremd-App-Suche. Bei fehlendem Index kann eine lokale strukturierte Textsuche verfügbare Inhalte bedienen; dies ist kein alter OS-Fallback.

Für „alle“ / „sämtliche“ / Vollständigkeitsfragen wird eine EvidenceSweep-Pipeline benutzt: alle gewählten erschlossenen Dokumente in begrenzten Batches prüfen, explizites CoverageLedger führen, Zusammenführung mit Quellen. Normales Top-k-Retrieval und Vollständigkeitsmodus haben getrennte Result-Typen.

## 4. Apple Intelligence orchestration
`AppleModelRouter` liefert nur zugelassene Apple-Modelle. On-device bereitet kleine Abschnitte/Tags vor; PCC unterstützt größere Synthesen, Vergleich und schwierige Fragen nach Freigabe. Kontextgröße wird aus der tatsächlichen API gelesen bzw. einem lokal bestätigten Adapter entnommen, nie nur aus „32K“ hart einkodiert. Reserven für Antwort/Reasoning/Tools sind Pflicht. [A05–A09]

Profiles `extract`, `answer`, `recommend` und `proposePlayback` besitzen minimal unterschiedliche Tools. Kein Profil besitzt direkten Player-, Keychain-, Dateisystem- oder beliebigen Netzwerkzugriff. Neue DynamicProfile-API nutzt die geprüften SDK-Signaturen; ein Profile-Wechsel ist kein Umgehen der App-State-Machine. Strukturierte Outputs wählen Evidence-IDs. Claims werden erst nach Referenzprüfung committed.

PCC-Ausfall: vorhandenes Wissen bleibt; lokale Fähigkeiten werden nur als solche angeboten. Watch nutzt PCC für kompakte Pakete, nicht einen erfundenen lokalen SystemLanguageModel. Keine stillen Fremdanbieter bei Quotenende. Die Kontobedingungen sind ein Releasegate. [A06–A09]

## 5. Fokuswiedergabe als zweistufige Aktion
`PlaylistProposal` ist untrusted Modelloutput. `FocusPlanner` löst IDs auf, prüft Edition/Scope/Rechte/Timing, expandiert auf Satz-/Dialogkontext, vereinigt Überlappungen derselben Fassung und budgetiert echte Medienzeit plus Transitionen. Output ist `ValidatedPlaybackPlan`, immutable und mit Hash versehen.

`PlaybackPolicy` erzeugt einen kurzlebigen, gerätegebundenen Grant ausschließlich aus explizitem UI-/Chat-/Intent-Start. `PlaybackCoordinator` verbraucht ihn idempotent und besitzt die aktive Session. Snapshot vor Quellenwechsel erhält die normale Queue. Exakte Regeln und Zustandsübergänge in `focus-playback.md` und ADR-004.

AVPlayerItem wird vorbereitet, auf Startposition gesucht, bei erfolgreicher Completion abgespielt und am vorgegebenen Ende beendet. Zeitbeobachter allein sind kein Sicherheitsendanschlag. `forwardPlaybackEndTime` plus Lifecycle-/Session-Token verhindert stale callbacks. Optimierung mit QueuePlayer erst nach derselben Semantik. Anfragen an einen nicht seekbaren oder nur unzuverlässig alignierten Stream werden nicht als exakt verkauft. [A17]

## 6. Persistence und Sync
SwiftData-Container ist lokal konfiguriert. CKSyncEngine ist der einzige Sync-Writer für die definierten Recordtypen. Andere Syncmechanismen werden für diese Daten nicht parallel eingeschaltet. Local Outbox speichert Mutationen und Tombstones im selben Commit wie die Datenänderung. CKSyncEngine-State wird persistent gehalten. [A13, A14]

Episode/MediaVersion-Artefakte sind immutable oder revisioniert. Notizen verwenden optimistic concurrency mit ConflictCopy statt Textverlust. Lernsignale sind append-only mit ResetEpoch. Queue-Reihenfolge ist revisioniert; konkurrierende Reorders werden explizit angeboten statt still gemischt. Abspielposition führt SessionID, monotone lokale Sequenz und absichtliche Seek-Events; größte Sekunde ist falsch bei Rewind. CloudKit synchronisiert nicht die volatile Playerinstanz.

Kein Pflicht-Master. Jobs sind lokal geplant, fertige Artefakte synchronisierbar und per Versionskey dedupliziert. Eventuelle doppelte Analyse ist möglich und wird durch idempotente Artefakte beherrscht; keine unbewiesene Exactly-once-Ausführung über CloudKit. Mac darf Batcharbeit durchführen, bleibt aber optional.

## 7. Hintergrund und Energie
Vier Schedulerpfade: Feedrefresh, URLSession-Download, reguläre Audio-Wiedergabe und rechenintensive Analyse. iOS/iPadOS BGAppRefresh/BGProcessing sind opportunistisch; ContinuedProcessing nur nach Nutzeraktion im Vordergrund. Ressourcen-/Entitlementprüfung für GPU/Neural Engine und echte Tests entscheiden über Hintergrundinferenz. Audio-Background-Mode wird nicht als Schlupfloch für Dauer-KI missbraucht. [A15, A16]

Mac arbeitet im laufenden App-Prozess; Schließen des letzten Fensters und Beenden sind verschiedene Zustände. Kein ungefragter Login-Helper. Watch erhält kurze Tasks, vollständige übertragene Packs und begrenzte Downloads; keine Langform-ASR im Hintergrund. Thermal State, Low Power Mode, Netzklasse und Speichergrenzen halten Arbeit an sicheren Checkpoints an.

## 8. Native UI und Systemintegration
Aktuelles Systemdesign nutzen statt das generierte Bild pixelgenau nachzubauen. iPhone: vier fachliche Tabs mit getrenntem Sucheinstieg und systemischem Mini-Player. iPad: adaptiver NavigationSplitView/Inspector. Mac: Multiwindow, Commands, Tabelle, Inspector; gemeinsamer Player und persistente Auswahl pro Fenster. Watch: kompakte Fokusfolge, Karte, Beleg, Play und Feedback; kurze Eingaben statt Transkriptwand. [A03, A04, A21]

SwiftUI State-Migration ist für vorhandene BrainSpeak-Views zu prüfen. Observation ersetzt neue Combine-ObservableObject-Gerüste im Produktcode; bestehender Code wird nur entlang echter Migrationsbedarfe verändert. ContentBuilder und native Reordering-/Toolbar-APIs werden bevorzugt, konkrete SDK-Verfügbarkeit entscheidet. Keine generische DI-/Router-/Redux-Großarchitektur ohne Bedarf.

App Intents führen dieselben Policies aus wie UI. `SyncableEntity` wird dort verwendet, wo die stabile geräteübergreifende Entity-ID real erfüllt ist. Widgets zeigen zuletzt bestätigten Zustand, keine auf Widgetbudget gestartete lange Inferenz. [A18]

## 9. Export
`MarkdownExportService` erhält einen expliziten ExportScope. Ein `SafeSourceLink` wird aus allowlist-geprüfter kanonischer Quelle erzeugt, nicht durch kosmetisches Entfernen von Querystrings. Ohne sicheren externen Link: Titel, Provider, Folge und interner Anchor mit Originalzeit. Private Feedtoken im Pfad bleiben ausgeschlossen. YAML-Skalare und Markdowntexte werden korrekt escaped. Export eines ganzen Vergleichs nennt alle benutzten Belege und tatsächliche Abdeckung.

## 10. Prüfen und freigeben
Unit- und Contracttests vor den Adaptern, dann API-Probes, Geräteintegration und Apple Evaluations. Telemetrie bleibt lokal/datensparsam; OSLog ohne Inhaltspayloads. Qualitätswerte in `spec.md` sind Ziele. Alle Tests dokumentieren Hardware, OS, Modellstand, Prompt-/Indexrevision und Bedingungen. Ein erfolgreiches Dokumentpaket-Validation-Skript ersetzt keinen Apple-App-Build.

## Implementation order
Audit/Gates → Domain/Contracts → Source + Player als vertikaler Grundpfad → Speech + Knowledge → Single/Multi-Chat → Fokus aus Chat → Interessenfokus → Sync → adaptive Mac/iPad/Watch-Shells → Export/Systemintegration → vier Plattformen und Fehlerpfade härten. Plattformadapter werden früh stubbar angelegt, nicht als spätere Produktoption vergessen.



## 11. Ergänzende Architekturverträge
`youtube-discovery-backfill.md` ist verbindlich für URL-Auflösung und historische Kataloge. `knowledge-workflow.md` ergänzt Highlights, native semantische Suche, portable Transkripte, optionale native Übersetzung und Smart Skip. `mcp-agent-access.md` definiert den opt-in Swift-Bridge-Zugang auf Mac. Neue Module bleiben Zielzuständigkeiten; T001/T004 mappt sie auf BrainSpeak. Externe Metadaten-APIs sind erlaubt, Drittanbieter-ASR/LLMs nicht. Historie, neue Folgen und manuell gestartete Analysen verwenden denselben versionierten Artefaktgraphen mit unterschiedlichen Prioritäten.



## 12. Widerspruchs-Mixer und Breadcrumb-Trail
Zielmodule `BrainSpeakPerspective` und `BrainSpeakKnowledgeTrail` werden nach Ist-Audit in vorhandene BrainSpeak-Domänen integriert. Sie sind keine neuen Dienste oder generischen Agentenframeworks.

`CounterpointMatcher` verwendet denselben scopegebundenen EvidenceStore/Retrieval-Layer wie der Chat. Quelle, Standpunkt und Nutzerzustimmung sind verschiedene Typen. Der Matcher produziert vorgeschlagene Beziehungen; `CounterpointPlanBuilder` liefert einen gewöhnlichen geprüften PlaybackPlan. SensitiveTopicPolicy verhindert individualisierte politische Überzeugungsprofile; explizite Sachvergleiche bleiben neutral. Details: `contradiction-mixer.md`.

`KnowledgeSession` speichert nur kurationsrelevante Referenzen. `SessionBoundaryPolicy` übersetzt echte Playerereignisse in running/paused/closing/closed; nur bewusste Enden erzeugen eine einmalige Abschlusskarte. `FollowUpResolver` liefert belegte Quellenzahlen. `GraphStore` nutzt lokale SwiftData-Entitäten und typisierte Kanten, kein Neo4j-/Cloud-Graph-Dienst. Verwendete SwiftData-27-APIs und Schemaänderungen bleiben Bestandteil des SDK-/Migrationsspikes. [A12]

`ParkCommitCoordinator` schreibt einen gefrorenen Graph-/Markdown-Snapshot mit eigenem Exportstatus, nicht direkt aus dem LLM. Eine autorisierte Dateienaktion gibt das Ziel vor. Native SwiftUI-Listen plus optionaler Canvas/Shapes stellen den Graphen dar; die semantische Listenalternative bleibt primär zugänglich. Keine Webview als Graph-App-Shell. Watch überträgt kompakte Entscheidungen und Referenzen, keine beliebige graphgroße Cloudoperation im Hintergrund.

Graph- und Entscheidungsereignisse integrieren sich in die vorhandene explizite CloudKit-Sync-Domäne; genau ein Syncbesitzer pro Record. Keine automatische SwiftData-Cloud-Synchronisierung zusätzlich für dieselben Entitäten. Konflikte zwischen Parken/Verwerfen bewahren menschliche Entscheidungen, Reanalyse überschreibt sie nicht. Details: `breadcrumb-trail.md` und neue Contracts.

## Erweiterung 1.3: Smart Podcast List als persistierter persönlicher Feed
`BrainSpeakSmartFeeds` ergänzt die vorhandenen Fokus-/Playback-/Interessenmodule, ersetzt sie nicht. FeedStore, UnheardSegmentResolver, PersonalEpisodePublisher und EpisodeSnapshotStore sind actor-isolierte Dienste mit Sendable-Snapshots. Der zentrale PlaybackCoordinator bleibt einziger Tonpfad. Native persönliche Ausgaben referenzieren Originalsegmente; sie sind keine synthetisierten MP3-Dateien.

Publisher: Scope prüfen → finale Evidence auswählen → globale Ledger/Reservierung prüfen → immutable Manifest committen → Shownotes/Fallback-Cover → Ausgabe publizieren → optionale Notification. Die Reihenfolge wird transaktional gegen Absturz und wiederholtes Scheduling abgesichert. KI wählt aus echten IDs; Swift-Policies bestimmen Quellenzeiten, Vollständigkeit, Tonfreigabe und Epochs.

Schemaergänzungen: SmartPodcastFeed, PersonalEpisode, ListeningLedger-Snapshot und CoverAsset. SwiftData-Schemamigrationen ergänzen diese additiv; historische Original-/Fokusdaten werden nicht stillschweigend umgedeutet. Ein Import alter Played-Bools ohne Intervalle erhält `historyQuality=unknown`.

Cover: `NativeCoverRenderer` erzeugt sofort ein Layout. `CoverArtworkCoordinator` präsentiert nur auf Nutzeraktion Image Playground. Kein `ImageCreator` auf 27er-Zielen, keine privaten API-/Shortcut-Umgehungen. Apple-Stile ohne externalProvider, nicht benötigte Personenpersonalisierung aus. SDK-Signaturen sowie das Kopieren der temporären Ergebnisdatei werden in GATE-COVER auf iOS/iPadOS/macOS getestet; Watch prüft synchronisierte Assets. [A27–A30]

Neu hinzugefügte Aufgaben T219–T266 müssen vor T099 (Release-Builds) liegen. Detail- und Zustandsregeln: [smart-podcast-list.md](smart-podcast-list.md). Die Paketprüfung ist kein Nachweis einer ausgeführten Apple-Implementierung.
