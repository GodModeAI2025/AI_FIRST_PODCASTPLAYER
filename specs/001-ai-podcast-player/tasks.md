# Tasks: Sonar / BrainSpeak — Apple 27

**Version 1.3 · Stand 2026-09-20. Alle Aufgaben sind geplant, keine Implementierung oder Geräteabnahme wird als erledigt bezeichnet.**

Maschinenlesbare Quelle: `tasks.json`. Reihenfolge nach Abhängigkeiten; IDs sind stabil und nicht als strikte Ausführungsreihenfolge zu verstehen.


## 00 Grundlagen

- [ ] T001 [P] BrainSpeak-Checkout read-only inventarisieren: Lizenz, Targets, Persistence, KI, Audio und Tests erfassen. Keine existierenden Klassen erfinden. `audit/brainspeak-baseline.md`
  Voraussetzung: Keine.
- [ ] T002 [P] Xcode-27-/Swift-6.4- und vier SDK-Probes auf Mac ausführen; Buildnummern in toolchain-lock ergänzen. `config/toolchain-lock.json`
  Voraussetzung: Keine.
- [ ] T003 [P] PCC-Account/Entitlement und Gerätefähigkeiten getrennt prüfen; fehlende Freigabe als Capability-Gate erfassen. `audit/pcc-eligibility.md`
  Voraussetzung: Keine.
- [ ] T004 Vorhandene Module auf Zielarchitektur abbilden; wiederverwenden, migrieren oder isolieren mit begründetem ADR. `audit/integration-map.md`
  Voraussetzung: T001, T002.
- [ ] T005 Gemeinsame Domain-IDs, Revisionsmodell und TimeRange-Invarianten test-first anlegen. `Packages/BrainSpeakDomain/Tests/DomainInvariantTests.swift`
  Voraussetzung: T001, T002.
- [ ] T006 Lokale SwiftData-Schemata, ModelActor und transaktionale Outbox-Grundstruktur implementieren. `Packages/BrainSpeakPersistence/Sources/LocalStore.swift`
  Voraussetzung: T001, T002.
- [ ] T007 Test-Doubles für Apple-Modelle, Uhr, Medienresolver, Netzwerk und Player entwickeln, ohne echte API durch Mocktests als getestet auszugeben. `Tests/Support/`
  Voraussetzung: T001, T002.
- [ ] T008 CapabilityRegistry, Zugriffspolicies und ExecutionGate als deterministische Grundbausteine implementieren. `Packages/BrainSpeakDomain/Sources/CapabilityRegistry.swift`
  Voraussetzung: T001, T002.
- [ ] T009 Vier SwiftUI-App-Shells mit Observation, State-Makro und adaptiver Navigation an vorhandene Composition anbinden. `Apps/`
  Voraussetzung: T001, T002.
- [ ] T010 Testkonfiguration für Swift Testing, UI-/Geräteprüfungen, Privacy-Logs und Evaluations-Gate einrichten. `Tests/TestPlans/`
  Voraussetzung: T001, T002.

## 01 US2 — Quellen aufnehmen

- [ ] T011 [P] [US2] Akzeptanztests für US2 zuerst mit Fixtures/Doubles anlegen; rote Tests und fehlende Geräteprüfungen unterscheiden. `Tests/Acceptance/US2Tests.swift`
  Voraussetzung: T005, T007, T008, T010.
- [ ] T012 [US2] RSS-Feeds, kanonische YouTube-Kanal-Atomfeeds und einzelne berechtigt verfügbare Medien aufnehmen; Quellentyp und Fähigkeiten separat darstellen. `Packages/BrainSpeakSources/Sources/SourceResolver.swift` — FR-001
  Voraussetzung: T011, T006.
- [ ] T013 [US2] Abo, Autoanalyse, Autoqueue und dauerhaften Offline-Download unabhängig konfigurieren; Autoanalyse kann temporäre Downloads auslösen und erklärt dies. `Packages/BrainSpeakSources/Sources/SubscriptionPolicy.swift` — FR-002
  Voraussetzung: T011, T006.
- [ ] T014 [US2] Einzelfolgenimport, Share-Import und OPML-Import/-Export ohne implizites Abo unterstützen; Duplikate anhand stabiler Quell-/Folgenidentitäten behandeln. `Packages/BrainSpeakSources/Sources/ImportCoordinator.swift` — FR-003
  Voraussetzung: T011, T006.
- [ ] T015 [US2] RSS enclosure/GUID, Redirects, Feedwechsel, ETag/Last-Modified, Publisher-Kapitel und Transkriptquellen verarbeiten; signierte Medien-URLs nicht durch pauschales Query-Stripping beschädigen. `Packages/BrainSpeakSources/Sources/FeedRepository.swift` — FR-004
  Voraussetzung: T011, T006.
- [ ] T016 [US2] YouTube nur als sichtbare offizielle Wiedergabe oder externes Öffnen anbieten; Vollanalyse nur mit gesondert autorisiertem Text/Audio; keine Audioextraktion aus YouTube-Streams. `Packages/BrainSpeakSources/Sources/YouTubeSourceAdapter.swift` — FR-005
  Voraussetzung: T011, T006.
- [ ] T017 [US2] Bei Quellzugang, Sprache, Format, Account oder Rechten konkrete capability reasons anzeigen; öffentlich erreichbar ist nicht pauschal eine Rechtefreigabe. `Packages/BrainSpeakSources/Sources/CapabilityResolver.swift` — FR-006
  Voraussetzung: T011, T006.
- [ ] T018 [US2] Archivnachladen begrenzen: zunächst gewählte aktuelle Folge, historische Zeiträume nur bewusst; Anzahl, Speicher und Netzwerkbedarf soweit bekannt anzeigen. `Packages/BrainSpeakSources/Sources/ArchiveImportPolicy.swift` — FR-007
  Voraussetzung: T011, T006.
- [ ] T019 [US2] Private Feeds mit Keychain-referenzierten Geheimnissen behandeln; keine Rohcredentials in CloudKit-Fachdaten, KI-Kontext oder Export; neue Geräte können erneute Anmeldung benötigen. `Packages/BrainSpeakSources/Sources/SecretReferenceStore.swift` — FR-008
  Voraussetzung: T011, T006.
- [ ] T020 [US2] US2 Ende-zu-Ende demonstrieren: Akzeptanzfälle ausführen, Fehlzustände nachweisen, Ergebnisse statt Erfolgserwartungen protokollieren. `validation/device/US2.md`
  Voraussetzung: T012, T013, T014, T015, T016, T017, T018, T019.

## 02 US3 — Originalaudio abspielen

- [ ] T021 [P] [US3] Akzeptanztests für US3 zuerst mit Fixtures/Doubles anlegen; rote Tests und fehlende Geräteprüfungen unterscheiden. `Tests/Acceptance/US3Tests.swift`
  Voraussetzung: T005, T007, T008, T010, T020.
- [ ] T022 [US3] Native Audio-Wiedergabe, Pause, Seek, Geschwindigkeit, Sleep Timer, Queue, Kapitel sowie Wiederaufnahme anbieten; Analyse darf Abspielen nicht blockieren. `Packages/BrainSpeakPlayback/Sources/PlaybackCoordinator.swift` — FR-009
  Voraussetzung: T021, T006.
- [ ] T023 [US3] Herausgeberkapitel, in der Datei enthaltene Kapitel und KI-Kapitel mit Herkunft und Konfliktauflösung zeigen; bei Fassungszweifeln nicht blind Zeiten übernehmen. `Packages/BrainSpeakPlayback/Sources/ChapterResolver.swift` — FR-010
  Voraussetzung: T021, T006.
- [ ] T024 [US3] Eine zentrale Wiedergabeinstanz pro Gerät/Prozess mit Now Playing, Remote Commands, Unterbrechungen, Bluetooth/AirPlay und Kopfhörertrennung integrieren, soweit Plattform unterstützt. `Packages/BrainSpeakPlayback/Sources/NowPlayingAdapter.swift` — FR-011
  Voraussetzung: T021, T006.
- [ ] T025 [US3] Hörposition, tatsächlich gehörte Zeitintervalle, KI-Verarbeitung und gelesene Erkenntnisse getrennt speichern; Fokus-Sprünge markieren keine vollständige Folge als gehört. `Packages/BrainSpeakPlayback/Sources/ListeningHistory.swift` — FR-012
  Voraussetzung: T021, T006.
- [ ] T026 [US3] Aus einer Quelle oder Chat-Fundstelle zur bisherigen Queue/Position zurückkehren; Focus Session überschreibt die normale Queue nicht. `Packages/BrainSpeakPlayback/Sources/QueueSnapshotStore.swift` — FR-013
  Voraussetzung: T021, T006.
- [ ] T027 [US3] US3 Ende-zu-Ende demonstrieren: Akzeptanzfälle ausführen, Fehlzustände nachweisen, Ergebnisse statt Erfolgserwartungen protokollieren. `validation/device/US3.md`
  Voraussetzung: T022, T023, T024, T025, T026.

## 03 US1 — Datei zu Wissen

- [ ] T028 [P] [US1] Akzeptanztests für US1 zuerst mit Fixtures/Doubles anlegen; rote Tests und fehlende Geräteprüfungen unterscheiden. `Tests/Acceptance/US1Tests.swift`
  Voraussetzung: T005, T007, T008, T010, T020.
- [ ] T029 [US1] Geeigneten Publisher-Text oder Audio-Dateitranskription verwenden; Titel/Shownotes allein niemals als analysierter Vollinhalt behandeln. `Packages/BrainSpeakIngestion/Sources/ContentAcquisition.swift` — FR-014
  Voraussetzung: T028, T006.
- [ ] T030 [US1] Dateibasierte Apple-Sprachanalyse mit verwalteten Sprachassets, Streaming/Chunk-Verarbeitung, finalisierten zeitbezogenen Segmenten und persistenter Wiederaufnahme durchführen. `Packages/BrainSpeakIngestion/Sources/SpeechAnalysisAdapter.swift` — FR-015
  Voraussetzung: T028, T006.
- [ ] T031 [US1] Medienfassung und Transkriptrevision unveränderlich identifizieren; echte Bytehashes nach vollständigem Download getrennt von schwachen Servermetadaten führen. `Packages/BrainSpeakIngestion/Sources/MediaRevisionStore.swift` — FR-016
  Voraussetzung: T028, T006.
- [ ] T032 [US1] Analyseabdeckung als Vereinigung bearbeiteter Medienintervalle bzw. explizite Textabdeckung berechnen; Fehler, Werbefassungen und fehlende Abschnitte sichtbar halten. `Packages/BrainSpeakIngestion/Sources/CoverageCalculator.swift` — FR-017
  Voraussetzung: T028, T006.
- [ ] T033 [US1] Claims, neutrale Zusammenfassung, persönliche Relevanz, offene Fragen und Evidence-IDs getrennt erzeugen; nur geprüfte strukturierte Ergebnisse persistieren. `Packages/BrainSpeakIngestion/Sources/KnowledgeExtractor.swift` — FR-018
  Voraussetzung: T028, T006.
- [ ] T034 [US1] Transkript ohne Zeitbezug als nutzbares Textwissen zulassen, aber zeitgenaue Wiedergabe dafür deaktivieren; unbestätigte Sprecher nicht benennen. `Packages/BrainSpeakIngestion/Sources/TranscriptCapability.swift` — FR-019
  Voraussetzung: T028, T006.
- [ ] T035 [US1] Verarbeitungsjobs priorisieren, pausieren, abbrechen, fortsetzen und nach Fehlern begrenzt wiederholen; höchstens definierte Parallelität pro Gerät und Arbeitsart. `Packages/BrainSpeakIngestion/Sources/AnalysisJobCoordinator.swift` — FR-020
  Voraussetzung: T028, T006.
- [ ] T036 [US1] US1 Ende-zu-Ende demonstrieren: Akzeptanzfälle ausführen, Fehlzustände nachweisen, Ergebnisse statt Erfolgserwartungen protokollieren. `validation/device/US1.md`
  Voraussetzung: T029, T030, T031, T032, T033, T034, T035.

## 04 US4 — Beleggebundener Chat

- [ ] T037 [P] [US4] Akzeptanztests für US4 zuerst mit Fixtures/Doubles anlegen; rote Tests und fehlende Geräteprüfungen unterscheiden. `Tests/Acceptance/US4Tests.swift`
  Voraussetzung: T005, T007, T008, T010, T036.
- [ ] T038 [US4] Chat-Scope explizit auf Folge, Auswahl, Sammlung oder alle analysierten Folgen setzen; Anzahl verfügbarer, ausgewählter und verwendeter Quellen unterscheiden. `Packages/BrainSpeakIntelligence/Sources/ChatScope.swift` — FR-021
  Voraussetzung: T037, T006.
- [ ] T039 [US4] Antworten nur aus erlaubten Evidence-IDs des gewählten Scopes erzeugen; Toolergebnisse nochmals gegen Scope, Löschstand, Revisionsstand und Zugriffsrechte prüfen. `Packages/BrainSpeakIntelligence/Sources/EvidenceResolver.swift` — FR-022
  Voraussetzung: T037, T006.
- [ ] T040 [US4] Aussagen, Ableitungen und eigene Notizen visuell und im Export unterscheiden; Vollständigkeit und Unsicherheit ohne unkalibrierte Prozent-Konfidenz darstellen. `Packages/BrainSpeakIntelligence/Sources/AnswerPresentation.swift` — FR-023
  Voraussetzung: T037, T006.
- [ ] T041 [US4] Explizit umfassende Fragen über einen Coverage-Lauf aller ausgewählten analysierten Dokumente abarbeiten; Top-k-Suche allein darf keine Vollständigkeit behaupten. `Packages/BrainSpeakIntelligence/Sources/ExhaustiveQueryCoordinator.swift` — FR-024
  Voraussetzung: T037, T006.
- [ ] T042 [US4] Auf keine Evidenz, widersprüchliche Quellen, unvollständige Analyse und Modellfehler mit unterscheidbaren Ergebniszuständen reagieren. `Packages/BrainSpeakIntelligence/Sources/AnswerState.swift` — FR-025
  Voraussetzung: T037, T006.
- [ ] T043 [US4] Nur Apple-Modelle benutzen; lokale und PCC-Verfügbarkeit, Nutzereinwilligung, Kontingent und Kontextgrenzen vor und während einer Anfrage berücksichtigen. `Packages/BrainSpeakIntelligence/Sources/AppleModelRouter.swift` — FR-026
  Voraussetzung: T037, T006.
- [ ] T044 [US4] Gesprächsverlauf versionieren und verdichten; konkrete Evidence-Verweise außerhalb der bloßen Chat-Historie speichern; Modellwechsel ändert den Scope nicht. `Packages/BrainSpeakIntelligence/Sources/ConversationMemory.swift` — FR-027
  Voraussetzung: T037, T006.
- [ ] T045 [US4] Modell-/Prompt-/Indexversionen dokumentieren und Apple Evaluations plus deterministische Referenz-/Policy-Tests vor Freigabe ausführen; Ergebnisse nicht nur visuell beurteilen. `Packages/BrainSpeakIntelligence/Sources/QualityEvaluationSuite.swift` — FR-065
  Voraussetzung: T037, T006.
- [ ] T046 [US4] US4 Ende-zu-Ende demonstrieren: Akzeptanzfälle ausführen, Fehlzustände nachweisen, Ergebnisse statt Erfolgserwartungen protokollieren. `validation/device/US4.md`
  Voraussetzung: T038, T039, T040, T041, T042, T043, T044, T045.

## 05 US7 — Kontrolliertes Interesse

- [ ] T047 [P] [US7] Akzeptanztests für US7 zuerst mit Fixtures/Doubles anlegen; rote Tests und fehlende Geräteprüfungen unterscheiden. `Tests/Acceptance/US7Tests.swift`
  Voraussetzung: T005, T007, T008, T010.
- [ ] T048 [US7] Bestätigte Interessen, automatisch vorgeschlagene Interessen, aktuelle Vorhaben und offene Fragen getrennt bearbeiten und anzeigen. `Packages/BrainSpeakInterests/Sources/InterestProfile.swift` — FR-038
  Voraussetzung: T047, T006.
- [ ] T049 [US7] Personalisierung opt-in anbieten; explizites Feedback stärker als indirekte Signale werten; Nicht gehört nicht mit Nicht relevant gleichsetzen. `Packages/BrainSpeakInterests/Sources/LearningConsent.swift` — FR-039
  Voraussetzung: T047, T006.
- [ ] T050 [US7] Warum empfohlen mit konkreter Interessen-/Fragezuordnung darstellen; Bereits bekannt, Mehr davon, Nicht relevant und Nicht aus dieser Quelle getrennt behandeln. `Packages/BrainSpeakInterests/Sources/RecommendationExplanation.swift` — FR-040
  Voraussetzung: T047, T006.
- [ ] T051 [US7] Vorschläge zur Profiländerung prüfen lassen; keine sensiblen Persönlichkeits-, Gesundheits- oder politischen Präferenzprofile aus Inhalten ableiten. `Packages/BrainSpeakInterests/Sources/ProfileChangeReview.swift` — FR-041
  Voraussetzung: T047, T006.
- [ ] T052 [US7] Neuigkeitswert ausschließlich relativ zu gespeichertem bzw. ausdrücklich bekanntem Wissen bezeichnen; neutrale chronologische Ansicht und relevante Gegenpositionen erhalten. `Packages/BrainSpeakInterests/Sources/NoveltyResolver.swift` — FR-042
  Voraussetzung: T047, T006.
- [ ] T053 [US7] Profil, Verlauf und Lernsignale separat löschbar machen; Reset-Epoch/Tombstones verhindern unbemerkten Wiederaufbau durch verspätete Sync-Events. `Packages/BrainSpeakInterests/Sources/ProfileResetPolicy.swift` — FR-043
  Voraussetzung: T047, T006.
- [ ] T054 [US7] US7 Ende-zu-Ende demonstrieren: Akzeptanzfälle ausführen, Fehlzustände nachweisen, Ergebnisse statt Erfolgserwartungen protokollieren. `validation/device/US7.md`
  Voraussetzung: T048, T049, T050, T051, T052, T053.

## 06 US5 — Chat zu Hörplan

- [ ] T055 [P] [US5] Akzeptanztests für US5 zuerst mit Fixtures/Doubles anlegen; rote Tests und fehlende Geräteprüfungen unterscheiden. `Tests/Acceptance/US5Tests.swift`
  Voraussetzung: T005, T007, T008, T010, T027, T046.
- [ ] T056 [US5] Aus explizitem Chat-Wiedergabewunsch ein PlaylistProposal aus bestehenden Evidence-IDs erzeugen; keine vom Modell erfundenen Originalzeiten oder Medien-URLs akzeptieren. `Packages/BrainSpeakFocus/Sources/FocusProposal.swift` — FR-028
  Voraussetzung: T055, T006.
- [ ] T057 [US5] Evidence-IDs deterministisch zu Start/Ende und Kontextintervallen derselben Medienfassung auflösen; ungültige, unzeitgestempelte und veraltete Belege sperren. `Packages/BrainSpeakFocus/Sources/PlaybackGrant.swift` — FR-029
  Voraussetzung: T055, T006.
- [ ] T058 [US5] Fokus-Vorschau mit Originalquelle, Zeitspanne, Relevanzgrund, Kontextzugabe, Reihenfolge, Medien-/Wandzeit und fehlenden Inhalten anzeigen. `Packages/BrainSpeakFocus/Sources/ResolvedPlaybackPlan.swift` — FR-030
  Voraussetzung: T055, T006.
- [ ] T059 [US5] Vor Start einen kurzlebigen geräte-/sessionspezifischen PlaybackGrant prüfen; explizites Spiele ... kann den Start autorisieren, eine Wissensfrage allein nicht. `Packages/BrainSpeakFocus/Sources/SegmentBoundaryController.swift` — FR-031
  Voraussetzung: T055, T006.
- [ ] T060 [US5] Segmentwiedergabe am geprüften Ende begrenzen und den nächsten Start nur nach erfolgreichem Seek/Load und gültigem Grant auslösen; Race Conditions idempotent behandeln. `Packages/BrainSpeakFocus/Sources/ContextBoundaryResolver.swift` — FR-032
  Voraussetzung: T055, T006.
- [ ] T061 [US5] US5 Ende-zu-Ende demonstrieren: Akzeptanzfälle ausführen, Fehlzustände nachweisen, Ergebnisse statt Erfolgserwartungen protokollieren. `validation/device/US5.md`
  Voraussetzung: T056, T057, T058, T059, T060.

## 07 US6 — Persönlicher Fokus

- [ ] T062 [P] [US6] Akzeptanztests für US6 zuerst mit Fixtures/Doubles anlegen; rote Tests und fehlende Geräteprüfungen unterscheiden. `Tests/Acceptance/US6Tests.swift`
  Voraussetzung: T005, T007, T008, T010, T061, T054.
- [ ] T063 [US6] Relevante Segmente mit Nutzerbudget, Themenbezug, Neuigkeitswert, Quellenvielfalt und Kontextbedarf auswählen; überlappende Stellen zusammenführen und Wiederholungen vermeiden. `Packages/BrainSpeakFocus/Sources/PersonalFocusPlanner.swift` — FR-033
  Voraussetzung: T062, T006.
- [ ] T064 [US6] Autofortsetzung nur innerhalb einer bewusst aktivierten Focus Session zulassen; neue Hintergrundempfehlungen, Boot, Sync oder Push dürfen niemals unaufgefordert Ton starten. `Packages/BrainSpeakFocus/Sources/FocusAutoplayPolicy.swift` — FR-034
  Voraussetzung: T062, T006.
- [ ] T065 [US6] Explizite Grenze aktiver Hörzeit einschließlich Kontext, geplanter Übergangspausen und gewählter Geschwindigkeit berücksichtigen; Nutzerpause und Buffering zählen nicht; bei unzureichendem Budget weniger liefern statt Semantik abzuschneiden. `Packages/BrainSpeakFocus/Sources/ListeningBudget.swift` — FR-035
  Voraussetzung: T062, T006.
- [ ] T066 [US6] Jederzeit ganze Folge, mehr Kontext, Skip, Stop, Zurück und Gründe anbieten; ein Quellenwechsel ist sichtbar und optional kurz haptisch, kein irreführender nahtloser Sprecherzusammenschnitt. `Packages/BrainSpeakFocus/Sources/FocusSessionControls.swift` — FR-036
  Voraussetzung: T062, T006.
- [ ] T067 [US6] Fokuslisten als referenzielle Wiedergabepläne speichern, nicht neue urheberrechtlich unklare Audio-Mashups exportieren; lokale Watch-Kopien nur im erlaubten Medienumfang. `Packages/BrainSpeakFocus/Sources/FocusPlanStore.swift` — FR-037
  Voraussetzung: T062, T006.
- [ ] T068 [US6] US6 Ende-zu-Ende demonstrieren: Akzeptanzfälle ausführen, Fehlzustände nachweisen, Ergebnisse statt Erfolgserwartungen protokollieren. `validation/device/US6.md`
  Voraussetzung: T063, T064, T065, T066, T067.

## 08 US10 — Zuverlässigkeit und Datenschutz

- [ ] T069 [P] [US10] Akzeptanztests für US10 zuerst mit Fixtures/Doubles anlegen; rote Tests und fehlende Geräteprüfungen unterscheiden. `Tests/Acceptance/US10Tests.swift`
  Voraussetzung: T005, T007, T008, T010.
- [ ] T070 [US10] Jobs/Teilresultate vor Systemende atomar sichern und beim Neustart fortsetzen; keine endlose Retry-Schleife bei Rechte-/Modell-/Sprachfehlern. `Packages/BrainSpeakPersistence/Sources/DurableJobStore.swift` — FR-044
  Voraussetzung: T069, T006.
- [ ] T071 [US10] Refresh, Hintergrunddownload, Audiowiedergabe und KI-Verarbeitung getrennt planen; iOS/iPadOS-Background-Gates und echte Ressourcenzustände beachten. `Packages/BrainSpeakPersistence/Sources/BackgroundPolicy.swift` — FR-045
  Voraussetzung: T069, T006.
- [ ] T072 [US10] Optionalen privaten CloudKit-Sync für Bibliothek, Wissen, bestätigte Profile und Fokuslisten bereitstellen; lokaler Modus bleibt ohne iCloud nutzbar. `Packages/BrainSpeakPersistence/Sources/CloudKitSyncAdapter.swift` — FR-046
  Voraussetzung: T069, T006.
- [ ] T073 [US10] Konflikte für Hörposition, Annotationen, Reihenfolge, Löschung und generierte Artefakte explizit behandeln; LWW allein und größte Hörsekunde sind kein universeller Konfliktlöser. `Packages/BrainSpeakPersistence/Sources/MergePolicy.swift` — FR-047
  Voraussetzung: T069, T006.
- [ ] T074 [US10] Keinen permanenten Master benötigen; größere Analysen auf jedem geeigneten Vollclient erlauben; CloudKit nicht als exakt-einmal Jobbroker oder Instant-RPC darstellen. `Packages/BrainSpeakPersistence/Sources/DistributedAnalysisRequests.swift` — FR-048
  Voraussetzung: T069, T006.
- [ ] T075 [US10] App-Daten, Mediencache, Analysecache und Nutzer-Exporte getrennt verwalten; Medien löschen kann Wissen erhalten; Gesamtlöschung entfernt auch Index, Artefakte und synchronisierte Daten gemäß Scope. `Packages/BrainSpeakPersistence/Sources/RetentionCoordinator.swift` — FR-049
  Voraussetzung: T069, T006.
- [ ] T076 [US10] Externe Texte und Metadaten als untrusted data behandeln; keine daraus stammenden Anweisungen für Tools, Netzwerk, Profiländerungen, Sync oder Exporte ausführen. `Packages/BrainSpeakPersistence/Sources/UntrustedContentBoundary.swift` — FR-062
  Voraussetzung: T069, T006.
- [ ] T077 [US10] Logs lokal, datensparsam und mit Privacy-Redaktion erzeugen; keine Audio-/Transkript-/Promptinhalte in Telemetrie, kein Third-Party-Analytics-SDK. `Packages/BrainSpeakPersistence/Sources/PrivacyLogger.swift` — FR-063
  Voraussetzung: T069, T006.
- [ ] T078 [US10] Parser-, URL-, Redirect-, Dateigrößen-, MIME-, Archiv- und Dekodiergrenzen erzwingen; keine automatischen Zugriffe auf lokale Netze/Loopback aus fremden Feeds. `Packages/BrainSpeakPersistence/Sources/InputValidation.swift` — FR-064
  Voraussetzung: T069, T006.
- [ ] T079 [US10] US10 Ende-zu-Ende demonstrieren: Akzeptanzfälle ausführen, Fehlzustände nachweisen, Ergebnisse statt Erfolgserwartungen protokollieren. `validation/device/US10.md`
  Voraussetzung: T070, T071, T072, T073, T074, T075, T076, T077, T078.

## 09 US8 — Native Plattformen

- [ ] T080 [P] [US8] Akzeptanztests für US8 zuerst mit Fixtures/Doubles anlegen; rote Tests und fehlende Geräteprüfungen unterscheiden. `Tests/Acceptance/US8Tests.swift`
  Voraussetzung: T005, T007, T008, T010.
- [ ] T081 [US8] iOS/iPadOS/watchOS/macOS als native 27er-Targets liefern; gemeinsame Domain und plattformspezifische Shells statt Catalyst oder skaliertem Telefonlayout. `Apps/BrainSpeak/AppComposition.swift` — FR-050
  Voraussetzung: T080, T006.
- [ ] T082 [US8] iPad mit adaptiver Mehrspaltenansicht, Inspector, Drag/Drop, Tastatur und fensterbreitenabhängiger Navigation ausstatten. `Apps/BrainSpeak/IPadWorkspace.swift` — FR-051
  Voraussetzung: T080, T006.
- [ ] T083 [US8] Mac mit Sidebar, Table/List, Inspector, Menübefehlen, mehreren Fenstern, Dateiimport/-export und einem prozessweiten Player ausstatten. `Apps/BrainSpeak/MacWorkspace.swift` — FR-052
  Voraussetzung: T080, T006.
- [ ] T084 [US8] App Intents für Folge/Fokus starten, Stelle merken, Frage vorbereiten und Wissen öffnen bereitstellen; stabile IDs, Intent-Policies und entitlements prüfen. `Apps/BrainSpeak/BrainSpeakIntents.swift` — FR-056
  Voraussetzung: T080, T006.
- [ ] T085 [US8] Dynamic Type, VoiceOver, Reduce Motion/Transparency, hohen Kontrast, Tastaturbedienung und barrierefreie Zeitcodes auf jeder Plattform prüfen. `Apps/BrainSpeak/AccessibilityContract.swift` — FR-057
  Voraussetzung: T080, T006.
- [ ] T086 [US8] BrainSpeak-Ist-Audit und Apple-SDK-Compile-Probes vor Integration abschließen; neue Framework-Symbole nicht aus unbestätigten Erinnerungen implementieren. `Apps/BrainSpeak/SDKAndBaselineAudit.swift` — FR-066
  Voraussetzung: T080, T006.
- [ ] T087 [US8] US8 Ende-zu-Ende demonstrieren: Akzeptanzfälle ausführen, Fehlzustände nachweisen, Ergebnisse statt Erfolgserwartungen protokollieren. `validation/device/US8.md`
  Voraussetzung: T081, T082, T083, T084, T085, T086.

## 10 US9 — Watch-Erlebnis

- [ ] T088 [P] [US9] Akzeptanztests für US9 zuerst mit Fixtures/Doubles anlegen; rote Tests und fehlende Geräteprüfungen unterscheiden. `Tests/Acceptance/US9Tests.swift`
  Voraussetzung: T005, T007, T008, T010, T068, T087.
- [ ] T089 [US9] Watch mit Tagesfokus, Segmentplayer, kurzen Erkenntnissen, Interesse-Feedback, Widget/Smart-Stack-Einstieg und gespeichertem Offline-Pack ausstatten. `Apps/BrainSpeakWatch/WatchFocusView.swift` — FR-053
  Voraussetzung: T088, T006.
- [ ] T090 [US9] Kurze Watch-Fragen über freigegebenes PCC mit lokalem Evidence-Pack oder sichtbaren Companion-Auftrag unterstützen; keinen lokalen Vollbibliotheksindex oder dauerhafte Watch-Transkription voraussetzen. `Apps/BrainSpeakWatch/WatchQuestionRouter.swift` — FR-054
  Voraussetzung: T088, T006.
- [ ] T091 [US9] WatchConnectivity-Handoff/Dateitransfer mit Zustand und Wiederaufnahme implementieren; unerreichbares iPhone und unvollständige Packs sind sichtbare Zustände. `Apps/BrainSpeakWatch/WatchTransferCoordinator.swift` — FR-055
  Voraussetzung: T088, T006.
- [ ] T092 [US9] US9 Ende-zu-Ende demonstrieren: Akzeptanzfälle ausführen, Fehlzustände nachweisen, Ergebnisse statt Erfolgserwartungen protokollieren. `validation/device/US9.md`
  Voraussetzung: T089, T090, T091.

## 11 US11 — Wissen exportieren

- [ ] T093 [P] [US11] Akzeptanztests für US11 zuerst mit Fixtures/Doubles anlegen; rote Tests und fehlende Geräteprüfungen unterscheiden. `Tests/Acceptance/US11Tests.swift`
  Voraussetzung: T005, T007, T008, T010, T046.
- [ ] T094 [US11] Markdown für Folge, Claim, Chatantwort, Vergleich und Sammlung mit YAML-Metadaten, Analyseumfang, Quellen, Originalzeiten und eigenen Notizen erzeugen. `Packages/BrainSpeakExport/Sources/MarkdownExporter.swift` — FR-058
  Voraussetzung: T093, T006.
- [ ] T095 [US11] Geheimnisse auch in URL-Pfaden entfernen; nur allowlist-basierte kanonische öffentliche Quellen ausgeben, andernfalls sichere interne Referenz mit lesbarer Quellenbezeichnung. `Packages/BrainSpeakExport/Sources/PublicSourceLinkPolicy.swift` — FR-059
  Voraussetzung: T093, T006.
- [ ] T096 [US11] Exportvorschau, sicheren Dateinamen, stabile UTF-8-Kodierung, atomisches Schreiben, überschaubare Einzeldatei oder Asset-freies ZIP für Sammlungen bieten; Volltranskripte nicht standardmäßig exportieren. `Packages/BrainSpeakExport/Sources/ExportTransaction.swift` — FR-060
  Voraussetzung: T093, T006.
- [ ] T097 [US11] Von der Watch einen nachvollziehbaren Export-/Save-Auftrag an Vollclients vermitteln; fertige Dateien erst nach Bestätigung der Erstellung anzeigen. `Packages/BrainSpeakExport/Sources/WatchExportRequest.swift` — FR-061
  Voraussetzung: T093, T006.
- [ ] T098 [US11] US11 Ende-zu-Ende demonstrieren: Akzeptanzfälle ausführen, Fehlzustände nachweisen, Ergebnisse statt Erfolgserwartungen protokollieren. `validation/device/US11.md`
  Voraussetzung: T094, T095, T096, T097.

## 12 Release-Gates

- [ ] T099 Vier 27er-Targets im Release-Toolchainkanal bauen; Compiler-/SDK-Build und sämtliche Warnungen erfassen. `validation/apple-builds.md`
  Voraussetzung: T020, T027, T036, T046, T054, T061, T068, T079, T087, T092, T098, T112, T114, T116, T118, T120, T122, T124, T126, T128, T130, T132, T134, T136, T138, T140, T142, T144, T146, T148, T150, T152, T154, T156, T158, T160, T162, T164, T166, T168, T170, T172, T174, T176, T178, T180, T182, T184, T186, T188, T190, T192, T194, T196, T198, T200, T202, T204, T206, T208, T210, T212, T214, T216, T218, T220, T222, T224, T226, T228, T230, T232, T234, T236, T238, T240, T242, T244, T246, T248, T250, T252, T254, T256, T258, T260, T262, T264, T266.
- [ ] T100 [P] Lange reale, berechtigt nutzbare Audiofolge auf zwei Vollclients transkribieren; Timing/Abdeckung/Abbrüche messen. `validation/long-audio.md`
  Voraussetzung: T099.
- [ ] T101 [P] PCC-Evaluations auf berechtigtem Account und lokalen Apple-Modellen getrennt durchführen; Kontingent-/Offline-/Modellwechselpfade prüfen. `validation/model-evaluations.md`
  Voraussetzung: T099.
- [ ] T102 [P] Fokusgrenzen und veraltete Callback-Races an realen Audioausgängen und verschiedenen Wiedergaberaten messen. `validation/playback-boundaries.md`
  Voraussetzung: T099.
- [ ] T103 [P] CloudKit-Konflikte und Löschungen mit zwei Geräten, Offline-Rückkehr und reset epoch unter realem Container prüfen. `validation/cloudkit.md`
  Voraussetzung: T099.
- [ ] T104 [P] Watch-Offlinepack, PCC, iPhone-Nichterreichbarkeit, Audio-Routing und Handoff auf echter Watch validieren. `validation/watch.md`
  Voraussetzung: T099.
- [ ] T105 [P] Alle Hauptflows nach Accessibility-/Lokalisierungscheckliste auf iPhone, iPad, Mac und Watch prüfen. `validation/accessibility.md`
  Voraussetzung: T099.
- [ ] T106 [P] Memory-, Akku-, thermische und Background-Messungen einschließlich Nutzerabbruch/OS-Ende durchführen. `validation/performance.md`
  Voraussetzung: T099.
- [ ] T107 [P] GPL-Abgrenzung, Drittinhalte/YouTube-Fähigkeiten, PrivacyInfo und benötigte Nutzereinwilligungen final prüfen. `validation/compliance.md`
  Voraussetzung: T099.
- [ ] T108 [P] Markdown-/OPML-Dateien mit Sonderzeichen, privaten Quellen und teilweisem Wissen gegen Fixtures prüfen. `validation/export.md`
  Voraussetzung: T099.
- [ ] T109 Spec–Plan–Tasks–Code–Tests-Konvergenz durchführen; jede FR mit Ergebnisdatei schließen oder explizit blockieren. `validation/convergence.md`
  Voraussetzung: T100, T101, T102, T103, T104, T105, T106, T107, T108.
- [ ] T110 Releaseentscheidung als nachvollziehbares Protokoll mit geprüften Gates, bekannten Grenzen und keiner ungeprüften Erfolgsbehauptung erstellen. `validation/release-decision.md`
  Voraussetzung: T109.

## 13 Ergänzungen aus Nutzerfeedback

- [ ] T111 [P] [US14] Abnahme FR-067 vorbereiten: Alle URL-Fixtures liefern ihre kanonische Art; ein fremder Host mit youtube.com im Pfad wird abgewiesen. `Tests/Acceptance/US14_67Tests.swift` — FR-067
  Voraussetzung: T010.
- [ ] T112 [US14] Eine einzige YouTube-URL aus Video, youtu.be, Shorts, Live, Kanal-ID, Handle oder Share Sheet erkennen; Kanal-ID autoritativ auflösen, Zeitmarke für den Einzelimport erhalten. `Packages/BrainSpeakSources/Sources/YouTubeURLResolver.swift` — FR-067
  Voraussetzung: T111, T086.
- [ ] T113 [P] [US14] Abnahme FR-068 vorbereiten: Videolink öffnet Dreiwegeauswahl mit korrektem Kanal; Abbrechen erzeugt kein Abo und keinen Analysejob. `Tests/Acceptance/US14_68Tests.swift` — FR-068
  Voraussetzung: T010.
- [ ] T114 [US14] Nach Auflösung eine Vorschau mit „Nur diese Folge“, „Kanal abonnieren“ und „Frühere Folgen analysieren“ anbieten; keine Aktion allein durch Einfügen ausführen. `Packages/BrainSpeakSources/Sources/ResolvedSourceSheet.swift` — FR-068
  Voraussetzung: T113, T086.
- [ ] T115 [P] [US14] Abnahme FR-069 vorbereiten: Handle und Videolink desselben Kanals ergeben denselben validierten Feed; widersprüchliche Feed-ID wird blockiert. `Tests/Acceptance/US14_69Tests.swift` — FR-069
  Voraussetzung: T010.
- [ ] T116 [US14] Den Kanal-Atomfeed aus der verifizierten channelID automatisch ermitteln und prüfen; Nutzer müssen im Normalfall keine RSS-URL kennen oder manuell suchen. `Packages/BrainSpeakSources/Sources/ChannelFeedDiscovery.swift` — FR-069
  Voraussetzung: T115, T086.
- [ ] T117 [P] [US14] Abnahme FR-070 vorbereiten: Drei Katalogseiten mit überlappenden Einträgen werden vollständig dedupliziert; ein RSS-Fenster begrenzt nicht den historischen Import. `Tests/Acceptance/US14_70Tests.swift` — FR-070
  Voraussetzung: T010.
- [ ] T118 [US14] Ältere YouTube-Folgen über den verfügbaren Kanal-Uploads-Katalog mit offizieller Pagination erschließen; Auswahl letzte N, Zeitraum, manuell oder gesamtes verfügbares Archiv, auch über den aktuellen Atomfeed hinaus. `Packages/BrainSpeakSources/Sources/YouTubeArchiveEnumerator.swift` — FR-070
  Voraussetzung: T117, T086.
- [ ] T119 [P] [US14] Abnahme FR-071 vorbereiten: Von 120 synthetischen Einträgen sind 75 analysierbar; Fortschritt zeigt beide Mengen und blockierte Gründe getrennt. `Tests/Acceptance/US14_71Tests.swift` — FR-071
  Voraussetzung: T010.
- [ ] T120 [US14] Archivauffindbarkeit, Inhaltszugang und Analyseabdeckung getrennt zählen; gefundene Videos ohne autorisierte Text-/Audioquelle niemals als inhaltlich analysiert ausweisen. `Packages/BrainSpeakSources/Sources/ArchiveCoverageLedger.swift` — FR-071
  Voraussetzung: T119, T086.
- [ ] T121 [P] [US14] Abnahme FR-072 vorbereiten: Kill nach Seite zwei, Neustart und neue Folge: keine verlorenen/gedoppelten Einträge, interaktive Arbeit hat Vorrang. `Tests/Acceptance/US14_72Tests.swift` — FR-072
  Voraussetzung: T010.
- [ ] T122 [US14] Historische Batchjobs pausieren, fortsetzen, abbrechen, priorisieren und selektiv wiederholen; Cursor und Seiten-Commit atomar sichern, aktuelle Folgen nicht durch das Archiv blockieren. `Packages/BrainSpeakSources/Sources/BackfillCoordinator.swift` — FR-072
  Voraussetzung: T121, T086.
- [ ] T123 [P] [US14] Abnahme FR-073 vorbereiten: Gekürzter Feed ohne Archivlink zeigt eingeschränkten Bestand; bestätigter Archiveintrag wird importiert, nicht blind geraten. `Tests/Acceptance/US14_73Tests.swift` — FR-073
  Voraussetzung: T010.
- [ ] T124 [US14] Auch Podcast-RSS rückwirkend über alle tatsächlich verfügbaren Feed-/Publisher-Archivquellen erschließen; gekürzte Feeds als unvollständig kennzeichnen, keine nicht vorhandenen Archivendpunkte erfinden. `Packages/BrainSpeakSources/Sources/RSSArchiveResolver.swift` — FR-073
  Voraussetzung: T123, T086.
- [ ] T125 [P] [US12] Abnahme FR-074 vorbereiten: Watch-Aktion sichert laufende Originalstelle; nicht unterstützte Headset-Geste bleibt unerreichbar und Standard-Play/Pause unverändert. `Tests/Acceptance/US12_74Tests.swift` — FR-074
  Voraussetzung: T010.
- [ ] T126 [US12] Eine relevante Stelle mit einer nativen Aktion aus Player, Transkript, Watch oder App Intent als Highlight sichern; Headset-Aktion nur bei tatsächlich öffentlicher unterstützter API und ausdrücklichem Mapping. `Packages/BrainSpeakKnowledge/Sources/HighlightCapture.swift` — FR-074
  Voraussetzung: T125, T086.
- [ ] T127 [P] [US12] Abnahme FR-075 vorbereiten: Bearbeiten der eigenen Notiz verändert weder Originalauszug noch Timecode; Quelle löschen zeigt verwaisten Beleg statt Ersatz. `Tests/Acceptance/US12_75Tests.swift` — FR-075
  Voraussetzung: T010.
- [ ] T128 [US12] Highlights als eigenständige versionierte Wissensobjekte mit Originalauszug, Evidence-IDs, eigener Notiz, separater KI-Kurzfassung, Tags und Herkunft verwalten. `Packages/BrainSpeakKnowledge/Sources/HighlightStore.swift` — FR-075
  Voraussetzung: T127, T086.
- [ ] T129 [P] [US12] Abnahme FR-076 vorbereiten: Text-only-Fixture exportiert TXT, aber kein erfundenes SRT; SRT/VTT-Roundtrip bewahrt vorhandene Zeitbereiche. `Tests/Acceptance/US12_76Tests.swift` — FR-076
  Voraussetzung: T010.
- [ ] T130 [US12] Finale Transkripte als SRT, WebVTT, TXT und strukturiertes JSON exportieren; Sprecher- und Wortzeitdaten nur mit vorhandenem belegtem Alignment, sonst explizit unbekannt. `Packages/BrainSpeakKnowledge/Sources/TranscriptExportService.swift` — FR-076
  Voraussetzung: T129, T086.
- [ ] T131 [P] [US12] Abnahme FR-077 vorbereiten: Eine ungehörte analysierte Folge wird semantisch gefunden; Scopefilter schließen fremde Folgen aus, lexical-only bleibt erkennbar. `Tests/Acceptance/US12_77Tests.swift` — FR-077
  Voraussetzung: T010.
- [ ] T132 [US12] Semantische und exakte Suche über den freigegebenen erschlossenen Bestand einschließlich ungehörter Folgen anbieten; indexiert, analysiert und gehört bleiben getrennte Zähler. `Packages/BrainSpeakKnowledge/Sources/LibrarySearchService.swift` — FR-077
  Voraussetzung: T131, T086.
- [ ] T133 [P] [US12] Abnahme FR-078 vorbereiten: Nach Löschung/Indexneubau sind private Inhalte weder Spotlight noch intern über Cache abrufbar; eingeschränkte Quellen bleiben aus dem OS-Index. `Tests/Acceptance/US12_78Tests.swift` — FR-078
  Voraussetzung: T010.
- [ ] T134 [US12] Suchindex als erneuerbares Derivat behandeln; Revisionen, Löschungen, Zugangsänderungen und Privatsphäreeinstellungen invalidieren Treffer und verhindern obsolete Evidence-IDs. `Packages/BrainSpeakKnowledge/Sources/SearchIndexLifecycle.swift` — FR-078
  Voraussetzung: T133, T086.
- [ ] T135 [P] [US12] Abnahme FR-079 vorbereiten: Bei unsicherer Werbung kein Autosprung; Undo spielt übersprungenen Abschnitt; YouTube-Autoskip bleibt deaktiviert. `Tests/Acceptance/US12_79Tests.swift` — FR-079
  Voraussetzung: T010.
- [ ] T136 [US12] Smart Skip für zulässiges Originalaudio nur ausdrücklich pro Quelle aktivieren; Werbung/Intro/Outro mit Herkunft und Unsicherheit markieren, Skip rückgängig machen und Originalzeitachse erhalten. `Packages/BrainSpeakKnowledge/Sources/SmartSkipPolicy.swift` — FR-079
  Voraussetzung: T135, T086.
- [ ] T137 [P] [US12] Abnahme FR-080 vorbereiten: Nur Summary-Prompt ändern: ASR und Audio bleiben unverändert; gezielte Neuverarbeitung behält alte Belege und eigene Notizen. `Tests/Acceptance/US12_80Tests.swift` — FR-080
  Voraussetzung: T010.
- [ ] T138 [US12] Erwerb, Transkription, Alignment, Kapitel, Zusammenfassung, Index und Relevanz separat wiederholbar und versioniert cachen; Änderung eines Prompts löst nicht automatisch neuen Audiodownload aus. `Packages/BrainSpeakKnowledge/Sources/PipelineArtifactGraph.swift` — FR-080
  Voraussetzung: T137, T086.
- [ ] T139 [P] [US12] Abnahme FR-081 vorbereiten: Nicht nativ unterstützte Datei wird mit Ursache abgewiesen; keine automatische Installation oder Umwandlung durch Dritttools. `Tests/Acceptance/US12_81Tests.swift` — FR-081
  Voraussetzung: T010.
- [ ] T140 [US12] Container/Codec-Kombinationen nativ pro Plattform prüfen; MP3/AAC/ALAC/FLAC/OGG als konkrete Capability-Testfälle statt pauschaler Formatgarantie behandeln; keine FFmpeg-/Drittcodec-Laufzeit hinzufügen. `Packages/BrainSpeakKnowledge/Sources/NativeMediaCapabilities.swift` — FR-081
  Voraussetzung: T139, T086.
- [ ] T141 [P] [US12] Abnahme FR-082 vorbereiten: Nicht verfügbares Sprachpaar erzeugt unavailable; Übersetzung verändert keine Originalevidence oder gesprochenen Zeitcodes. `Tests/Acceptance/US12_82Tests.swift` — FR-082
  Voraussetzung: T010.
- [ ] T142 [US12] Optionale native Übersetzung separat vom Original speichern und als Übersetzung markieren; Zeitbelege bleiben am Original, Sprachpaare und Modellassets werden geprüft. `Packages/BrainSpeakKnowledge/Sources/NativeTranslationAdapter.swift` — FR-082
  Voraussetzung: T141, T086.
- [ ] T143 [P] [US13] Abnahme FR-083 vorbereiten: Ohne Nutzerfreigabe keine Datenausgabe; aktivierter lokaler Client nutzt nur explizit geteilte Collections und zeigt Verbindung an. `Tests/Acceptance/US13_83Tests.swift` — FR-083
  Voraussetzung: T010.
- [ ] T144 [US13] Auf macOS einen standardmäßig ausgeschalteten nativen Swift-MCP-Zugang anbieten; zunächst lokaler stdio-Helfer, keine automatisch öffentliche Netzwerkfreigabe oder iOS-Daemon-Fiktion. `Apps/BrainSpeakMCP/LocalMCPBridge.swift` — FR-083
  Voraussetzung: T143, T086.
- [ ] T145 [P] [US13] Abnahme FR-084 vorbereiten: Toolaufruf mit Pfadtraversal, fremder Evidence-ID oder unfreigegebenem Scope scheitert; prepare_focus startet keinen Ton. `Tests/Acceptance/US13_84Tests.swift` — FR-084
  Voraussetzung: T010.
- [ ] T146 [US13] MCP-Verträge für Bibliothekssuche, Evidence-Abruf, Highlightliste, Exportvorschau und Fokusplan-Vorbereitung definieren; keine freie SQL-, Datei-, Shell- oder URL-Ausführung und keine Tonwiedergabe durch Suchtools. `Apps/BrainSpeakMCP/PodcastToolCatalog.swift` — FR-084
  Voraussetzung: T145, T086.
- [ ] T147 [P] [US13] Abnahme FR-085 vorbereiten: Widerruf sperrt nächsten Abruf und Export; Warnung erklärt, dass ein externer Client Inhalte anders verarbeiten kann. `Tests/Acceptance/US13_85Tests.swift` — FR-085
  Voraussetzung: T010.
- [ ] T148 [US13] MCP-Datenweitergabe als eigene Einwilligung mit Client-/Scopebindung, Widerruf und Redaction behandeln; externe Agenten können eigene Modelle verwenden, ohne dadurch Modellanbieter der App zu werden. `Apps/BrainSpeakMCP/AgentDisclosurePolicy.swift` — FR-085
  Voraussetzung: T147, T086.
- [ ] T149 [P] [US14] Abnahme FR-086 vorbereiten: Interessenänderung erneuert Relevanz, nicht ASR; explizite Neu-ASR erzeugt neue Revision und lässt vorherige Notiz erhalten. `Tests/Acceptance/US14_86Tests.swift` — FR-086
  Voraussetzung: T010.
- [ ] T150 [US14] Bereits bekannte alte Folgen nachträglich gezielt neu analysieren, etwa nach Änderung von Interessen, Modell oder Pipeline; Umfang und betroffene Stufen vorher anzeigen, menschliche Notizen nie überschreiben. `Packages/BrainSpeakSources/Sources/ReanalysisPlanner.swift` — FR-086
  Voraussetzung: T149, T086.
- [ ] T151 [P] [US14] Abnahme FR-087 vorbereiten: 403 quota, 404 und offline bleiben unterscheidbar; fehlgeschlagene Auflösung legt keinen erfundenen Kanal an. `Tests/Acceptance/US14_87Tests.swift` — FR-087
  Voraussetzung: T010.
- [ ] T152 [US14] Offline-, API-Quota-, Zugangs-, gelöschte Video- und uneindeutige URL-Zustände mit Wiederholen oder kanonischem Link-Import behandeln; keinen Erfolg oder manuell zu suchenden RSS als normalen Ablauf vortäuschen. `Packages/BrainSpeakSources/Sources/DiscoveryFailureState.swift` — FR-087
  Voraussetzung: T151, T086.
- [ ] T153 [P] [US14] Abnahme FR-088 vorbereiten: Metadatenpriorität verbessert Reihenfolge, verändert nicht den angeforderten Gesamtumfang oder Vollständigkeitszähler. `Tests/Acceptance/US14_88Tests.swift` — FR-088
  Voraussetzung: T010.
- [ ] T154 [US14] Archivjobs auf Wunsch nach Interessen priorisieren; eine nur aus Titel/Beschreibung geschätzte Priorität ausdrücklich als vorläufig kennzeichnen und keinen unbeachteten Rest als irrelevant verwerfen. `Packages/BrainSpeakSources/Sources/ArchivePriorityPolicy.swift` — FR-088
  Voraussetzung: T153, T086.
- [ ] T155 [P] [US14] Abnahme FR-089 vorbereiten: Handlewechsel plus nochmaliger Videoimport erhält ein Abo; Archivabbruch deaktiviert nicht neue Folgen und umgekehrt. `Tests/Acceptance/US14_89Tests.swift` — FR-089
  Voraussetzung: T010.
- [ ] T156 [US14] Abo anhand stabiler Kanal-/Quell-ID deduplizieren; Handlewechsel darf kein zweites Abo erzeugen, historische Analyse und Autoanalyse neuer Folgen bleiben unabhängig schaltbar. `Packages/BrainSpeakSources/Sources/SubscriptionIdentity.swift` — FR-089
  Voraussetzung: T155, T086.
- [ ] T157 [P] [US14] Abnahme FR-090 vorbereiten: Unbekannte Größen werden unbekannt genannt; neue Katalogeinträge nach Snapshot werden nicht still dem genehmigten Batch hinzugefügt. `Tests/Acceptance/US14_90Tests.swift` — FR-090
  Voraussetzung: T010.
- [ ] T158 [US14] Vor Batchstart gewählten Umfang, verfügbare/gesperrte Inhalte, Daten-/Speicherbedarf soweit bekannt und Analysepolicy anzeigen; „alle“ bedeutet alle zugänglichen Einträge im bestätigten Snapshot, nicht private oder gelöschte Videos. `Packages/BrainSpeakSources/Sources/ArchiveReviewSheet.swift` — FR-090
  Voraussetzung: T157, T086.

## 14 Widerspruchs-Mixer und Breadcrumb-Trail

- [ ] T159 [P] [US15] Abnahme FR-091 vorbereiten: Nur drei gespeicherte Local-first-Folgen erzeugen keinen bestätigten Nutzerstandpunkt; eine explizite Bestätigung erzeugt einen versionierten Standpunkt. `Tests/Acceptance/US15_91Tests.swift` — FR-091
  Voraussetzung: T010.
- [ ] T160 [US15] Bestätigte Standpunkte, vermutete Interessen, Quellenpositionen und bloßes Hör-/Speicherverhalten getrennt halten; Hören oder Highlight allein darf niemals als Zustimmung gelten. `Packages/BrainSpeakPerspective/Sources/StanceStore.swift` — FR-091
  Voraussetzung: T159, T054, T061, T068.
- [ ] T161 [P] [US15] Abnahme FR-092 vorbereiten: Ohne Opt-in kein Profiling für Gegenpositionen und kein Mixerjob; aktivierte Vorbereitung startet keinen Ton. `Tests/Acceptance/US15_92Tests.swift` — FR-092
  Voraussetzung: T010.
- [ ] T162 [US15] Den Widerspruchs-Mixer standardmäßig ausschalten; Nutzer wählt These oder Thema, zulässige Quellen, Zeitbudget und ob Vorschläge künftig vorbereitet werden dürfen. `Packages/BrainSpeakPerspective/Sources/PerspectiveConsent.swift` — FR-092
  Voraussetzung: T161, T054, T061, T068.
- [ ] T163 [P] [US15] Abnahme FR-093 vorbereiten: Gleiche Aussage mit anderem Beispiel wird nicht als Gegenbeweis markiert; echte Gegenposition bekommt eine prüfbare Relation und Belege. `Tests/Acceptance/US15_93Tests.swift` — FR-093
  Voraussetzung: T010.
- [ ] T164 [US15] Gegenpositionen gegen eine konkrete These samt Bedingungen vergleichen; starker fairer Gegenstandpunkt statt Karikatur, bloße Themenähnlichkeit ist kein Widerspruch. `Packages/BrainSpeakPerspective/Sources/CounterpointMatcher.swift` — FR-093
  Voraussetzung: T163, T054, T061, T068.
- [ ] T165 [P] [US15] Abnahme FR-094 vorbereiten: Eine geschnittene Negation oder fehlende Einschränkung blockiert den Clip; keine synthetische Sprecherstimme ersetzt das Original. `Tests/Acceptance/US15_94Tests.swift` — FR-094
  Voraussetzung: T010.
- [ ] T166 [US15] Jede Gegenposition mit vollständigem Kontext, Evidence-ID, Quelle, Datum und konkreter Medienfassung ausgeben; Audio bleibt Original, Einordnung bleibt getrennt. `Packages/BrainSpeakPerspective/Sources/CounterpointEvidence.swift` — FR-094
  Voraussetzung: T165, T054, T061, T068.
- [ ] T167 [P] [US15] Abnahme FR-095 vorbereiten: Dasselbe Gespräch in RSS und YouTube zählt einmal; die App erfindet keine Unabhängigkeit unbekannter Herausgeber. `Tests/Acceptance/US15_95Tests.swift` — FR-095
  Voraussetzung: T010.
- [ ] T168 [US15] Verschiedene Perspektiven nach nachgewiesener Passung und Quellenvielfalt auswählen; Syndikation und inhaltliche Duplikate nicht als unabhängige Bestätigung zählen. `Packages/BrainSpeakPerspective/Sources/PerspectiveDiversity.swift` — FR-095
  Voraussetzung: T167, T054, T061, T068.
- [ ] T169 [P] [US15] Abnahme FR-096 vorbereiten: Cloudvorteile bei stabiler Verbindung widerlegen keinen Offline-Bedarf; Relation lautet andere Bedingung oder Einschränkung, nicht bewiesen falsch. `Tests/Acceptance/US15_96Tests.swift` — FR-096
  Voraussetzung: T010.
- [ ] T170 [US15] Direkten Widerspruch, Einschränkung, andere Annahme und bloße Ergänzung unterscheiden; Interpretationen als vorgeschlagen kennzeichnen und korrigierbar machen. `Packages/BrainSpeakPerspective/Sources/ArgumentRelationClassifier.swift` — FR-096
  Voraussetzung: T169, T054, T061, T068.
- [ ] T171 [P] [US15] Abnahme FR-097 vorbereiten: Sechs Minuten enthalten Kontext und Übergänge; überlanges Material wird nicht sinnentstellend gekürzt, sondern weniger Inhalt oder Budgetwahl angeboten. `Tests/Acceptance/US15_97Tests.swift` — FR-097
  Voraussetzung: T010.
- [ ] T172 [US15] Mixer als budgetgebundenen Original-Hörplan mit Vorschau, Quellenwechsel, Stop und Rückkehr aufbauen; gleicher PlaybackGrant wie anderer Fokusmodus. `Packages/BrainSpeakPerspective/Sources/CounterpointPlanBuilder.swift` — FR-097
  Voraussetzung: T171, T054, T061, T068.
- [ ] T173 [P] [US15] Abnahme FR-098 vorbereiten: Leerer Gegenpositionsindex erzeugt noEvidence, keine zufälligen kontroversen Clips und keinen leeren startbaren Plan. `Tests/Acceptance/US15_98Tests.swift` — FR-098
  Voraussetzung: T010.
- [ ] T174 [US15] Ohne belastbare Gegenposition offen fehlende Evidenz zeigen; keine Quellen, Gegenargumente, Zeitcodes oder künstliche Ausgewogenheit erfinden. `Packages/BrainSpeakPerspective/Sources/CounterpointAvailability.swift` — FR-098
  Voraussetzung: T173, T054, T061, T068.
- [ ] T175 [P] [US15] Abnahme FR-099 vorbereiten: These ändern macht alten Plan stale; laufende Wiedergabe bleibt stoppbar und setzt nicht mit ungeprüften neuen Clips fort. `Tests/Acceptance/US15_99Tests.swift` — FR-099
  Voraussetzung: T010.
- [ ] T176 [US15] Eigene These, Quelleninterpretation und Modus jederzeit ändern, pausieren oder widerrufen; Änderungen invalidieren noch nicht gestartete darauf basierende Pläne. `Packages/BrainSpeakPerspective/Sources/StanceRevisionPolicy.swift` — FR-099
  Voraussetzung: T175, T054, T061, T068.
- [ ] T177 [P] [US15] Abnahme FR-100 vorbereiten: Politischer Verlauf wird kein Überzeugungsprofil; ein ausdrücklicher Sachvergleich bleibt neutral und endet ohne Wahlempfehlung oder Gewinner. `Tests/Acceptance/US15_100Tests.swift` — FR-100
  Voraussetzung: T010.
- [ ] T178 [US15] Politische Inhalte nicht zur Ableitung politischer Nutzerpräferenzen oder individualisierten Überzeugungsänderung nutzen; nur explizit gewünschte neutrale, quellenbasierte Gegenüberstellung ohne Empfehlung oder Ranking politischer Optionen. `Packages/BrainSpeakPerspective/Sources/SensitiveTopicPolicy.swift` — FR-100
  Voraussetzung: T177, T054, T061, T068.
- [ ] T179 [P] [US15] Abnahme FR-101 vorbereiten: Hilfreiches Gegenargument ändert einen bestätigten Standpunkt nicht; Analytics enthalten keine Überzeugungswechsel- oder Empörungsscores. `Tests/Acceptance/US15_101Tests.swift` — FR-101
  Voraussetzung: T010.
- [ ] T180 [US15] Erfolg nicht an Meinungsänderung, Empörung oder Hörzeit optimieren; Nutzer kann Gegenposition als hilfreich, bereits bekannt, unpassend oder fehlerhaft markieren, ohne eigene These ändern zu müssen. `Packages/BrainSpeakPerspective/Sources/PerspectiveFeedback.swift` — FR-101
  Voraussetzung: T179, T054, T061, T068.
- [ ] T181 [P] [US15] Abnahme FR-102 vorbereiten: Reiner Podcast-Export enthält keine private These; MCP-Scope ohne persönliche Notizen liefert keine Standpunktdaten. `Tests/Acceptance/US15_102Tests.swift` — FR-102
  Voraussetzung: T010.
- [ ] T182 [US15] Standpunkte und Gegenpositionsbeziehungen nicht ungefragt exportieren, an Agenten freigeben oder in Systemsuche veröffentlichen; gesonderte Scopeentscheidung für persönliche Inhalte. `Packages/BrainSpeakPerspective/Sources/PerspectiveDisclosure.swift` — FR-102
  Voraussetzung: T181, T054, T061, T068.
- [ ] T183 [P] [US16] Abnahme FR-103 vorbereiten: Zwei Sitzungen zur gleichen Frage bleiben identifizierbar; bloß abgespielte Sekunden erzeugen keine bestätigten Wissensknoten. `Tests/Acceptance/US16_103Tests.swift` — FR-103
  Voraussetzung: T010.
- [ ] T184 [US16] Jede Hör-/Fokus-/Mixer-Session mit stabiler ID, Ausgangsfrage, tatsächlich verwendeten Belegen, Budget und Checkpoint verknüpfen; aus Verlauf wird nur nach Kuration ein Wissenspfad. `Packages/BrainSpeakKnowledgeTrail/Sources/KnowledgeSession.swift` — FR-103
  Voraussetzung: T183, T061, T068, T079, T098.
- [ ] T185 [P] [US16] Abnahme FR-104 vorbereiten: Ende einer Fokusliste zeigt genau eine Abschlusskarte; Pause oder Kopfhörertrennung beendet die Session nicht und zeigt keine Abschlusspflicht. `Tests/Acceptance/US16_104Tests.swift` — FR-104
  Voraussetzung: T010.
- [ ] T186 [US16] Nach natürlichem Ende, Budgetende oder bewusstem Beenden eine kompakte Abschlussfrage mit Vertiefen, Parken und Verwerfen anbieten; Schließen ohne Entscheidung bleibt möglich. `Packages/BrainSpeakKnowledgeTrail/Sources/SessionClosingCard.swift` — FR-104
  Voraussetzung: T185, T061, T068, T079, T098.
- [ ] T187 [P] [US16] Abnahme FR-105 vorbereiten: Vier eindeutige zugängliche Quellen erlauben die Zahl vier; Duplikat oder gesperrter Inhalt reduziert den Zähler, Null zeigt keine erfundene Verfügbarkeit. `Tests/Acceptance/US16_105Tests.swift` — FR-105
  Voraussetzung: T010.
- [ ] T188 [US16] In der Abschlussfrage nur tatsächlich auffindbare und zugängliche Quellen zählen; Anzahl, Scope, Relevanz und Inhaltsstatus sind am Zeitpunkt des Angebots überprüfbar. `Packages/BrainSpeakKnowledgeTrail/Sources/FollowUpSourceCount.swift` — FR-105
  Voraussetzung: T187, T061, T068, T079, T098.
- [ ] T189 [P] [US16] Abnahme FR-106 vorbereiten: Tippen zeigt Folgefrage, Belege und neues Zeitbudget; erst ausdrücklicher Hörstart erzeugt einen neuen PlaybackGrant. `Tests/Acceptance/US16_106Tests.swift` — FR-106
  Voraussetzung: T010.
- [ ] T190 [US16] Vertiefen erzeugt eine neue begrenzte Kindsession aus einer gewählten Folgefrage und geprüften Quellen; kein endloses Autoplay und kein automatischer Scope-/Kostenanstieg. `Packages/BrainSpeakKnowledgeTrail/Sources/DeepenCoordinator.swift` — FR-106
  Voraussetzung: T189, T061, T068, T079, T098.
- [ ] T191 [P] [US16] Abnahme FR-107 vorbereiten: Export enthält stabile IDs, Kanten, Fundstellen und offene Frage; reimportierter Graph bewahrt Knotenidentität und Quellenbezug. `Tests/Acceptance/US16_107Tests.swift` — FR-107
  Voraussetzung: T010.
- [ ] T192 [US16] Parken sichert eine Wissenslandkarte aus Frage, Erkenntnissen, Originalbelegen, eigenen Notizen und offenen Fragen; Markdown, Graph-JSON und Mermaid sind portable Exportziele. `Packages/BrainSpeakKnowledgeTrail/Sources/TrailExportBuilder.swift` — FR-107
  Voraussetzung: T191, T061, T068, T079, T098.
- [ ] T193 [P] [US16] Abnahme FR-108 vorbereiten: Verwerfen entfernt nur den Vorschlag; ursprüngliches Highlight und Quelle bleiben erhalten, Undo stellt den Pfad samt Belegen wieder her. `Tests/Acceptance/US16_108Tests.swift` — FR-108
  Voraussetzung: T010.
- [ ] T194 [US16] Verwerfen verwirft den vorgeschlagenen Wissenspfad, nicht Medien, Abos, existierende Notizen oder Highlights; Undo ist möglich, Desinteresse wird nicht automatisch gelernt. `Packages/BrainSpeakKnowledgeTrail/Sources/TrailDiscardPolicy.swift` — FR-108
  Voraussetzung: T193, T061, T068, T079, T098.
- [ ] T195 [P] [US16] Abnahme FR-109 vorbereiten: Jede Kante referenziert existierende Knoten mit Richtung und Bedeutung; ein Widerspruch kann modelliert werden, ohne als wahr entschieden zu sein. `Tests/Acceptance/US16_109Tests.swift` — FR-109
  Voraussetzung: T010.
- [ ] T196 [US16] Wissensgraph mit typisierten Knoten und Kanten modellieren: Frage, Aussage, Beleg, Notiz, Thema und Session sowie stützt, widerspricht, qualifiziert, folgt aus und vertieft. `Packages/BrainSpeakKnowledgeTrail/Sources/KnowledgeGraphStore.swift` — FR-109
  Voraussetzung: T195, T061, T068, T079, T098.
- [ ] T197 [P] [US16] Abnahme FR-110 vorbereiten: Ein geparkter Gegenstandpunkt bleibt Quellenposition; keine Umwandlung in eigene Meinung oder unabhängig bestätigte Wahrheit. `Tests/Acceptance/US16_110Tests.swift` — FR-110
  Voraussetzung: T010.
- [ ] T198 [US16] Generierte Graphbeziehungen als Vorschläge von bestätigten Kurationen trennen; Parken bestätigt Aufbewahrung, nicht Wahrheit oder Zustimmung zu allen Aussagen. `Packages/BrainSpeakKnowledgeTrail/Sources/GraphCurationPolicy.swift` — FR-110
  Voraussetzung: T197, T061, T068, T079, T098.
- [ ] T199 [P] [US16] Abnahme FR-111 vorbereiten: Neuer Prompt ersetzt nur abgeleitete Versionen; handgeschriebene Notiz und bestätigte Relation bleiben inklusive Änderungsprotokoll erhalten. `Tests/Acceptance/US16_111Tests.swift` — FR-111
  Voraussetzung: T010.
- [ ] T200 [US16] Graphableitungen mit Prompt-/Modell-/Inputrevision speichern und selektiv neu berechnen; menschliche Notizen, manuelle Kanten und bewusste Entscheidungen nicht überschreiben. `Packages/BrainSpeakKnowledgeTrail/Sources/GraphRevisionStore.swift` — FR-111
  Voraussetzung: T199, T061, T068, T079, T098.
- [ ] T201 [P] [US16] Abnahme FR-112 vorbereiten: Nicht freigegebener Ordner wird nicht beschrieben; unterbrochener Export bleibt pending und meldet nicht fälschlich in Obsidian gespeichert. `Tests/Acceptance/US16_112Tests.swift` — FR-112
  Voraussetzung: T010.
- [ ] T202 [US16] Export an ein Wissens-Tool über explizit gewählte Datei-/Ordnerfreigabe oder autorisierten Agent-Scope ausführen; Vorschau, Redaction, transaktionales Schreiben und Retrystatus vorsehen. `Packages/BrainSpeakKnowledgeTrail/Sources/ParkCommitCoordinator.swift` — FR-112
  Voraussetzung: T201, T061, T068, T079, T098.
- [ ] T203 [P] [US16] Abnahme FR-113 vorbereiten: Neustart nach Abbruch stellt Checkpoint wieder her; kein laufender Timer erzeugt Hintergrunddialog oder Sprachprompt. `Tests/Acceptance/US16_113Tests.swift` — FR-113
  Voraussetzung: T010.
- [ ] T204 [US16] Unterbrechung, OS-Beendigung, Netzverlust, Sleep Timer und vorübergehende Pause als fortsetzbare Zustände behandeln; Abschlussangebot erst am passenden bewussten Ende nachholen. `Packages/BrainSpeakKnowledgeTrail/Sources/SessionBoundaryPolicy.swift` — FR-113
  Voraussetzung: T203, T061, T068, T079, T098.
- [ ] T205 [P] [US16] Abnahme FR-114 vorbereiten: Offline-Watch-Parken und Mac-Verwerfen werden nicht still last-write-wins zusammengeführt; einmal bestätigter Exportjob erzeugt keine doppelten Dateien. `Tests/Acceptance/US16_114Tests.swift` — FR-114
  Voraussetzung: T010.
- [ ] T206 [US16] Parken und Verwerfen geräteübergreifend idempotent und revisionsgebunden synchronisieren; konkurrierende Entscheidungen erhalten beide Varianten oder sichtbaren Konflikt statt Datenverlust. `Packages/BrainSpeakKnowledgeTrail/Sources/TrailSyncPolicy.swift` — FR-114
  Voraussetzung: T205, T061, T068, T079, T098.
- [ ] T207 [P] [US16] Abnahme FR-115 vorbereiten: VoiceOver kann Frage, Beziehungen und Quellen navigieren; Watch kann Parken vormerken und aufs iPhone übergeben, nicht vorzeitigen Exporterfolg behaupten. `Tests/Acceptance/US16_115Tests.swift` — FR-115
  Voraussetzung: T010.
- [ ] T208 [US16] Auf iPhone kompakte Abschlusskarte, iPad/Mac Karte plus Wissensansicht und Watch kurze Auswahl anbieten; Graph besitzt immer zugängliche Listen-/Baumalternative. `Packages/BrainSpeakKnowledgeTrail/Sources/BreadcrumbPlatformPresentation.swift` — FR-115
  Voraussetzung: T207, T061, T068, T079, T098.
- [ ] T209 [P] [US16] Abnahme FR-116 vorbereiten: Credits des Originalmediums bleiben unverändert; App-Abschluss ist klar getrennt und ohne gesonderten Wunsch stumm. `Tests/Acceptance/US16_116Tests.swift` — FR-116
  Voraussetzung: T010.
- [ ] T210 [US16] Abschluss und Übergänge standardmäßig visuell, optional mit nativer Systemstimme darstellen; nie Publisher-Credits verändern oder eine Sprecheridentität imitieren. `Packages/BrainSpeakKnowledgeTrail/Sources/SessionOutroPresentation.swift` — FR-116
  Voraussetzung: T209, T061, T068, T079, T098.
- [ ] T211 [P] [US16] Abnahme FR-117 vorbereiten: Schließen ohne Auswahl bleibt neutral; keine wiederholten Meldungen, Belohnungsverluste oder Hördaueroptimierung. `Tests/Acceptance/US16_117Tests.swift` — FR-117
  Voraussetzung: T010.
- [ ] T212 [US16] Kuration an nützlichen beantworteten/offenen Fragen und nachvollziehbarer Wiederverwendung messen; überspringbare Abschlusskarte, abschaltbarer Modus und kein Streak-/Druckmechanismus. `Packages/BrainSpeakKnowledgeTrail/Sources/KnowledgeOutcomeMetrics.swift` — FR-117
  Voraussetzung: T211, T061, T068, T079, T098.
- [ ] T213 [P] [US16] Abnahme FR-118 vorbereiten: Geparkte Frage erzeugt keinen Timer und keine Pushmeldung; eigene Quellenbeobachtung respektiert Quellen- und Ressourcenpolicy. `Tests/Acceptance/US16_118Tests.swift` — FR-118
  Voraussetzung: T010.
- [ ] T214 [US16] Offene geparkte Fragen nur innerhalb ausdrücklich aktivierter Quellenbeobachtung erneut anbieten; Parken allein aktiviert keine automatischen Benachrichtigungen, Downloads oder Dauersuchen. `Packages/BrainSpeakKnowledgeTrail/Sources/ParkedQuestionPolicy.swift` — FR-118
  Voraussetzung: T213, T061, T068, T079, T098.
- [ ] T215 [P] [US16] Abnahme FR-119 vorbereiten: Quellenlöschung entfernt nicht verwandte Notiz, markiert fehlenden Beleg und löscht privaten Cache; bereits extern kopierte Datei wird als außerhalb Kontrolle benannt. `Tests/Acceptance/US16_119Tests.swift` — FR-119
  Voraussetzung: T010.
- [ ] T216 [US16] Beim Entfernen einer Quelle oder persönlicher Daten abhängige Graph-/Index-/Exportvorschläge markieren oder bereinigen; exportierte Dateien nur innerhalb bestehender Schreibfreigabe verändern und externe Kopien nicht als gelöscht behaupten. `Packages/BrainSpeakKnowledgeTrail/Sources/GraphDeletionPolicy.swift` — FR-119
  Voraussetzung: T215, T061, T068, T079, T098.
- [ ] T217 [P] [US16] Abnahme FR-120 vorbereiten: Prompt-Injection in Transkript oder Knotentitel führt weder Export noch Toolaufruf oder Abonnement aus; Code im Markdown bleibt Text. `Tests/Acceptance/US16_120Tests.swift` — FR-120
  Voraussetzung: T010.
- [ ] T218 [US16] KI-generierte Fragen und Graphlabels als nicht vertrauenswürdige Daten behandeln; sie dürfen keine URL-/Datei-/Tool-Aktion außerhalb des bestätigten Scopes auslösen. `Packages/BrainSpeakKnowledgeTrail/Sources/GraphActionPolicy.swift` — FR-120
  Voraussetzung: T217, T061, T068, T079, T098.

## 15 Smart Podcast List und persönliche Folgen

- [ ] T219 [P] [US17] Abnahme FR-121 vorbereiten: Zwei Themenfeeds und einen gemischten Feed anlegen; nach Neustart bleiben IDs, Themen und Ausgaben erhalten. `Tests/Acceptance/US17_121Tests.swift` — FR-121
  Voraussetzung: T010.
- [ ] T220 [US17] Persistente persönliche Themen-Feeds mit eigenen Ausgaben, Titel, Shownotes, Cover und unveränderlichem Originalsegmentmanifest bereitstellen; getrennte und gemischte Themenlisten ermöglichen. `Packages/BrainSpeakSmartFeeds/Sources/FeedStore.swift` — FR-121
  Voraussetzung: T219, T006, T025, T043, T061, T068, T079.
- [ ] T221 [P] [US17] Abnahme FR-122 vorbereiten: Konfiguriertes Profil ohne Lernfreigabe verwenden; mehrfaches Play fordert kein Profilinterview und ändert das Profil nicht. `Tests/Acceptance/US17_122Tests.swift` — FR-122
  Voraussetzung: T010.
- [ ] T222 [US17] Bestätigte konfigurierte Interessen übernehmen und optional korrigierbar dazulernen; vor jedem Play keine erneute Interessenabfrage verlangen. `Packages/BrainSpeakSmartFeeds/Sources/FeedProfilePolicy.swift` — FR-122
  Voraussetzung: T221, T006, T025, T043, T061, T068, T079, T220.
- [ ] T223 [P] [US17] Abnahme FR-123 vorbereiten: Teilanalysierten Korpus wählen; Coverage und enthaltene Quellen stimmen; nicht erlaubte Quelle bleibt ausgeschlossen. `Tests/Acceptance/US17_123Tests.swift` — FR-123
  Voraussetzung: T010.
- [ ] T224 [US17] Den Quellen-Scope je Feed festhalten; verfügbare, analysierte, passende und enthaltene Inhalte getrennt ausweisen; keine unangekündigte Websuche ausführen. `Packages/BrainSpeakSmartFeeds/Sources/FeedScope.swift` — FR-123
  Voraussetzung: T223, T006, T025, T043, T061, T068, T079, T220.
- [ ] T225 [P] [US17] Abnahme FR-124 vorbereiten: Zweimal denselben Kandidatenlauf ausführen: eine logische Ausgabe; Titelwechsel allein erzeugt keine neue Folge. `Tests/Acceptance/US17_124Tests.swift` — FR-124
  Voraussetzung: T010.
- [ ] T226 [US17] Neue persönliche Folgen nur aus neuen passenden, ungehörten und abspielbaren Kernsegmenten veröffentlichen; wiederholten Refresh und Offline-Doppelentwürfe anhand stabiler Identität deduplizieren. `Packages/BrainSpeakSmartFeeds/Sources/PersonalEpisodePublisher.swift` — FR-124
  Voraussetzung: T225, T006, T025, T043, T061, T068, T079, T220, T238.
- [ ] T227 [P] [US17] Abnahme FR-125 vorbereiten: Alte Originalquelle als neue persönliche Ausgabe bündeln; korrekte Daten und absatzbezogene Evidence-IDs prüfen. `Tests/Acceptance/US17_125Tests.swift` — FR-125
  Voraussetzung: T010.
- [ ] T228 [US17] Titel und textuelle Shownotes nur aus dem finalen Segmentmanifest erzeugen; Originaldatum und persönliche Veröffentlichung unterscheiden; alte Inhalte als neu für dich statt neu veröffentlicht kennzeichnen. `Packages/BrainSpeakSmartFeeds/Sources/EpisodeShownotesBuilder.swift` — FR-125
  Voraussetzung: T227, T006, T025, T043, T061, T068, T079, T220.
- [ ] T229 [P] [US17] Abnahme FR-126 vorbereiten: Mehr Treffer als eine Ausgabeseite bereitstellen; kein Top-k-Verlust, Rest folgt sichtbar; Kurzfassung nennt nicht alles. `Tests/Acceptance/US17_126Tests.swift` — FR-126
  Voraussetzung: T010.
- [ ] T230 [US17] Alles Ungehörte als umfassenden Modus von budgetierter Auswahl unterscheiden; bei Pagination, Limits oder unvollständiger Analyse Restbestand und Abdeckung sichtbar halten. `Packages/BrainSpeakSmartFeeds/Sources/UnheardBacklogPlanner.swift` — FR-126
  Voraussetzung: T229, T006, T025, T043, T061, T068, T079, T220, T238.
- [ ] T231 [P] [US17] Abnahme FR-127 vorbereiten: Während Wiedergabe neue Segmente einspeisen; bestehendes Manifest bleibt byteidentisch, nächste Ausgabe ist separat. `Tests/Acceptance/US17_127Tests.swift` — FR-127
  Voraussetzung: T010.
- [ ] T232 [US17] Publizierte oder gestartete persönliche Ausgaben nicht heimlich neu zusammensetzen; bewusste Restfassungen als neue Revision mit aktualisierten Shownotes und Grant behandeln. `Packages/BrainSpeakSmartFeeds/Sources/EpisodeSnapshotStore.swift` — FR-127
  Voraussetzung: T231, T006, T025, T043, T061, T068, T079, T220.
- [ ] T233 [P] [US18] Abnahme FR-128 vorbereiten: Eine Folge mit drei passenden Abschnitten starten; nur diese werden abgespielt; Ganz hören bleibt erreichbar. `Tests/Acceptance/US18_128Tests.swift` — FR-128
  Voraussetzung: T010.
- [ ] T234 [US18] Pro Originalfolge Ganz hören, Für mich relevante Stellen und einzelne Belegsprünge anbieten; passende Originalabschnitte innerhalb eines bestätigten Plans automatisch nacheinander spielen. `Packages/BrainSpeakSmartFeeds/Sources/EpisodeFocusMode.swift` — FR-128
  Voraussetzung: T233, T006, T025, T043, T061, T068, T079, T220.
- [ ] T235 [P] [US18] Abnahme FR-129 vorbereiten: Play autorisiert genau den Plan; Quellenwechsel läuft weiter; Hintergrundveröffentlichung erzeugt keinen Ton. `Tests/Acceptance/US18_129Tests.swift` — FR-129
  Voraussetzung: T010.
- [ ] T236 [US18] Einmaliges Play oder expliziten Chat-Wiedergabewunsch als begrenzte Startfreigabe verwenden; keine erneute Bestätigung pro Segment und kein Tonstart durch Empfehlungen, Refresh oder Sync. `Packages/BrainSpeakSmartFeeds/Sources/PersonalEpisodePlaybackGate.swift` — FR-129
  Voraussetzung: T235, T006, T025, T043, T061, T068, T079, T220.
- [ ] T237 [P] [US19] Abnahme FR-130 vorbereiten: Spielen 10–20 s, Springen auf 60 s und Spielen 60–65 s erzeugt genau diese zwei Intervalle, nicht 10–65 s. `Tests/Acceptance/US19_130Tests.swift` — FR-130
  Voraussetzung: T010.
- [ ] T238 [US19] Abgespielte Originalzeitintervalle pro MediaVersion global vereinigen; Seek, Download, Analyse, Lesen und Buffering niemals als gehörte Zeit erfassen. `Packages/BrainSpeakSmartFeeds/Sources/ListeningLedger.swift` — FR-130
  Voraussetzung: T237, T006, T025, T043, T061, T068, T079, T220.
- [ ] T239 [P] [US19] Abnahme FR-131 vorbereiten: Abschnitt im Themenfeed hören; derselbe Abschnitt gilt beim Original und zweiten Feed als abgespielt, übrige Folge nicht. `Tests/Acceptance/US19_131Tests.swift` — FR-131
  Voraussetzung: T010.
- [ ] T240 [US19] Gemeinsamen Hörverlauf zwischen Originalfolgen, Chat-Fokus, Themenfeeds und Geräten anwenden; Fokuswiedergabe markiert nicht die komplette Originalfolge als gehört. `Packages/BrainSpeakSmartFeeds/Sources/CrossFeedConsumptionPolicy.swift` — FR-131
  Voraussetzung: T239, T006, T025, T043, T061, T068, T079, T220, T238.
- [ ] T241 [P] [US19] Abnahme FR-132 vorbereiten: Teilgehörte Aussage mit Kontext prüfen; neue Restbelege erhalten gültige Grenzen, Kontext als Wiederholung markieren. `Tests/Acceptance/US19_132Tests.swift` — FR-132
  Voraussetzung: T010.
- [ ] T242 [US19] Noch ungehörte Kernbereiche von nötiger Kontextwiederholung trennen; bereits geplante Dubletten und explizite Ausschlüsse gesondert führen; semantische Ähnlichkeit allein ist keine Dublette. `Packages/BrainSpeakSmartFeeds/Sources/UnheardSegmentResolver.swift` — FR-132
  Voraussetzung: T241, T006, T025, T043, T061, T068, T079, T220, T238.
- [ ] T243 [P] [US19] Abnahme FR-133 vorbereiten: Teils gehörte Folge bleibt im Restfilter; fehlt im Nie-gestartet-Filter; manuell erledigt erzeugt keine Hörintervalle. `Tests/Acceptance/US19_133Tests.swift` — FR-133
  Voraussetzung: T010.
- [ ] T244 [US19] Ungehörte Abschnitte auch aus angefangenen Folgen und Nur noch nicht gestartete Originalfolgen als zwei Filter anbieten; unbekannte Historie und manuell erledigte Inhalte separat kennzeichnen. `Packages/BrainSpeakSmartFeeds/Sources/HistoryFilterPolicy.swift` — FR-133
  Voraussetzung: T243, T006, T025, T043, T061, T068, T079, T220, T238.
- [ ] T245 [P] [US18] Abnahme FR-134 vorbereiten: Persönliche Position in Segment 2 auf Originalzeit abbilden; 1,5-fache Rate verändert Quellenzeitmapping nicht. `Tests/Acceptance/US18_134Tests.swift` — FR-134
  Voraussetzung: T010.
- [ ] T246 [US18] Persönliche und originale Zeitachsen deterministisch aus dem Manifest abbilden; Resume, Kapitel, Fernsteuerung und Watch verwenden denselben bestätigten Plan. `Packages/BrainSpeakSmartFeeds/Sources/VirtualTimeline.swift` — FR-134
  Voraussetzung: T245, T006, T025, T043, T061, T068, T079, T220, T234.
- [ ] T247 [P] [US18] Abnahme FR-135 vorbereiten: Kein TTS-Aufruf im Ausgabepfad; Sourcewechsel sichtbar, Originalclip und dessen geprüfte Grenzen unverändert. `Tests/Acceptance/US18_135Tests.swift` — FR-135
  Voraussetzung: T010.
- [ ] T248 [US18] Audio in Originalstimmen ohne KI-Nachsprache oder gesprochene KI-Überleitungen wiedergeben; Quellenwechsel kenntlich machen, Kontext und Qualifikationen erhalten. `Packages/BrainSpeakSmartFeeds/Sources/OriginalAudioPolicy.swift` — FR-135
  Voraussetzung: T247, T006, T025, T043, T061, T068, T079, T220.
- [ ] T249 [P] [US18] Abnahme FR-136 vorbereiten: Ausgabefrage darf nur Manifestbelege verwenden; unbekannter Sprecher wird nicht benannt; Sprung ins Original funktioniert. `Tests/Acceptance/US18_136Tests.swift` — FR-136
  Voraussetzung: T010.
- [ ] T250 [US18] Kapitel, Quellen, belegte Sprechernamen, Originalzeitcodes, persönliche Zeit und Original-Weiterhören anbieten; Fragen zur persönlichen Ausgabe auf deren Originalbelege begrenzen. `Packages/BrainSpeakSmartFeeds/Sources/PersonalEpisodeInspector.swift` — FR-136
  Voraussetzung: T249, T006, T025, T043, T061, T068, T079, T220, T234.
- [ ] T251 [P] [US19] Abnahme FR-137 vorbereiten: Zwei Offlinegeräte mit gleichen Kandidaten und überlappenden Hörintervallen mergen ohne doppelte neue Segmente; Watch zeigt nur vollständig geladene Pakete offline-bereit. `Tests/Acceptance/US19_137Tests.swift` — FR-137
  Voraussetzung: T010.
- [ ] T252 [US19] Feedkonfigurationen, Manifestrevisionen, Ledger-Events und Coverreferenzen optional über vorhandenen privaten Sync übertragen; Epochs, Deduplizierung und vollständige Watch-Packs prüfen. `Packages/BrainSpeakSmartFeeds/Sources/SmartFeedSync.swift` — FR-137
  Voraussetzung: T251, T006, T025, T043, T061, T068, T079, T220, T238.
- [ ] T253 [P] [US17] Abnahme FR-138 vorbereiten: Audiofassung austauschen bzw. Quelle löschen; betroffene Segmente sichtbar nicht verfügbar, kein Zeittransfer auf fremde Fassung. `Tests/Acceptance/US17_138Tests.swift` — FR-138
  Voraussetzung: T010.
- [ ] T254 [US17] Quellenverlust, geänderte Medienfassung, Löschung und Profilreset in abhängigen persönlichen Folgen und Reservierungen berücksichtigen; veraltete Belege nicht abspielen. `Packages/BrainSpeakSmartFeeds/Sources/PersonalEpisodeInvalidation.swift` — FR-138
  Voraussetzung: T253, T006, T025, T043, T061, T068, T079, T220.
- [ ] T255 [P] [US20] Abnahme FR-139 vorbereiten: ImageCreator ist im neuen Featurecode abwesend; native Sheet-Integration prüfen; externe Provider nicht in erlaubten Stilen. `Tests/Acceptance/US20_139Tests.swift` — FR-139
  Voraussetzung: T010.
- [ ] T256 [US20] Image-Playground-Cover ausschließlich über unterstützten nutzergeführten Systemdialog auf Vollclients anbieten; Apple-Stile begrenzen und externe Provider ausschließen; ImageCreator nicht verwenden. `Packages/BrainSpeakSmartFeeds/Sources/CoverArtworkCoordinator.swift` — FR-139
  Voraussetzung: T255, T006, T025, T043, T061, T068, T079, T220.
- [ ] T257 [P] [US20] Abnahme FR-140 vorbereiten: Ohne Modell, offline und bei Cover-Abbruch erscheint ein eigenes natives Cover; Audioausgabe bleibt nutzbar. `Tests/Acceptance/US20_140Tests.swift` — FR-140
  Voraussetzung: T010.
- [ ] T258 [US20] Sofort ein automatisches natives Titel-/Themen-Cover bereitstellen; optional bestätigtes Feedmotiv wiederverwenden; dies nicht als neue automatische Image-Playground-Generierung bezeichnen. `Packages/BrainSpeakSmartFeeds/Sources/NativeCoverRenderer.swift` — FR-140
  Voraussetzung: T257, T006, T025, T043, T061, T068, T079, T220.
- [ ] T259 [P] [US20] Abnahme FR-141 vorbereiten: Temporärdatei nach Kopie entfernen; gespeichertes Cover bleibt; abgebrochene Auswahl ersetzt kein bisheriges Asset. `Tests/Acceptance/US20_141Tests.swift` — FR-141
  Voraussetzung: T010.
- [ ] T260 [US20] Bestätigtes Image-Playground-Ergebnis vor Ablauf temporärer Datei atomar speichern, prüfen und versionieren; Cover-Provenienz und Motivdatensparsamkeit beachten; Watch zeigt synchronisiertes Asset. `Packages/BrainSpeakSmartFeeds/Sources/CoverAssetStore.swift` — FR-141
  Voraussetzung: T259, T006, T025, T043, T061, T068, T079, T220, T256, T258.
- [ ] T261 [P] [US17] Abnahme FR-142 vorbereiten: Nichts-Neues-Fall erzeugt keine leere Folge; Screenreader liest Thema, Quellenzahl und Coveraktion; Notification ohne Autorisierung bleibt aus. `Tests/Acceptance/US17_142Tests.swift` — FR-142
  Voraussetzung: T010.
- [ ] T262 [US17] Keine neuen Segmente, unvollständige Analyse und nicht verfügbare Quellen als eigene Zustände zeigen; Veröffentlichung atomar vor optionaler Benachrichtigung committen; Accessibility und Datenschutz auf allen vier Plattformen berücksichtigen. `Packages/BrainSpeakSmartFeeds/Sources/SmartFeedPresentation.swift` — FR-142
  Voraussetzung: T261, T006, T025, T043, T061, T068, T079, T220.
- [ ] T263 [P] [US17] Abnahme FR-143 vorbereiten: Manifest und Markdown gegen aktuelle Revision prüfen; private URLs redigiert, Original-/persönliche Zeiten stimmen. `Tests/Acceptance/US17_143Tests.swift` — FR-143
  Voraussetzung: T010.
- [ ] T264 [US17] Persönliche Folge und Feedkonfiguration als Markdown bzw. sicheres Manifest exportieren: Originalquellen, Zeitmapping, Shownotes, Analyseumfang und Coverherkunft; keine implizite öffentliche Audioveröffentlichung. `Packages/BrainSpeakSmartFeeds/Sources/PersonalEpisodeExporter.swift` — FR-143
  Voraussetzung: T263, T006, T025, T043, T061, T068, T079, T220.
- [ ] T265 [P] [US17] Abnahme FR-144 vorbereiten: Synthetische Themen iOS, Google/KI, EnBW und Datenschutz verwenden; vollständigen Ablauf einschließlich Re-Refresh, Queue-Ende und Cover-Abbruch testen. `Tests/Acceptance/US17_144Tests.swift` — FR-144
  Voraussetzung: T010.
- [ ] T266 [US17] Den gesamten Themenfeed-Ablauf von Konfiguration über ungehörte Originalsegmente, Publikation, Play, erneute Aktualisierung und Cover-Fallback mit plattformbezogenen Abnahmen belegen. `Packages/BrainSpeakSmartFeeds/Sources/SmartFeedEndToEnd.swift` — FR-144
  Voraussetzung: T265, T006, T025, T043, T061, T068, T079, T220, T222, T224, T226, T228, T230, T232, T234, T236, T238, T240, T242, T244, T246, T248, T250, T252, T254, T256, T258, T260, T262, T264.
