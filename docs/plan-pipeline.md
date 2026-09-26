# Verarbeitung als Stufen-Pipeline

Stand 26. September 2026. Grundlage: Durchsicht von integration/0.12, zwei Entwürfe (Ereignisse im Speicher, dauerhafte Auftragsliste), Bewertung und Gegenprüfung.

Ich habe nur gelesen und nichts gebaut. Pfade liegen unter `app/`: `S/` steht für `Apps/Shared/`, `P/` für `Packages/PodcastAIKit/Sources/`. Die Kürzel sind die aus dem Bericht „ablauf“ (AM, AM+K, AM+T, AM+A, AM+Y, AM+S, AM+R, AM+So, BW, BD, TN, CP, AIS, KE, LS). Neu ist LST für LibraryStore+Tags.swift.

## Bewertung

| Kriterium | A | B | Begründung |
|---|---|---|---|
| Flüssigkeit | 4 | 4 | Beide holen die Arbeit vom Hauptakteur und drosseln den Fortschritt je Folge. Keiner entlastet die eine Queue des `LibraryStore` (StoreExecutor.swift:28-75). |
| Beenden und Neustart | 3 | 5 | A verliert alles, was sich nicht ableiten lässt: `factsRequested`, die Karenz, angefangenes Aufräumen und Fehler je Folge. B hält jeden Auftrag auf der Platte und fängt Abstürze über Prozessgenerationen ab. |
| iCloud-Abgleich | 3 | 4 | Beide prüfen vor Start und Übernahme im Store. A rechnet die Karenz aber ab `createdAt` des Transkripts, und die ist bei einem Tage alten Import sofort abgelaufen. |
| Regel 5 | 3 | 5 | A setzt den Wächter im Store erst in Schritt 4 ein. Die Stufen aus Schritt 1 bis 3 sehen `removalCount` (AM+K:2578-2588) dann nicht mehr, und angefangenes Aufräumen stirbt mit dem Prozess. B baut den Wächter zuerst und speichert `purge(episode)` als Auftrag. |
| Einfachheit für ein kleines Team | 4 | 2 | B bringt einen zweiten SwiftData-Container mit eigener Migration, Leases, Herzschlag und `waitsFor`. Dazu kommen zwei Wahrheiten ohne gemeinsame Transaktion. |
| Testbarkeit | 4 | 4 | A braucht je Stufe einen Test für `reconcile()`, B je Stufe einen Absturztest für (I). B hat mit `JobPlan` eine reine Funktion für Tabellentests. |
| Migrationsrisiko | 3 | 3 | A trennt Fakten und Tags über eine Release hinweg und schützt spät. B riskiert einen neuen Container beim Start im Hintergrund vor dem ersten Entsperren. |
| Passung zu AIScheduler und Bestand | 4 | 3 | A behält `AnalysisQueueSnapshot`, `AnalysisQueueControl` und `AutomaticWorkBudget`. B ersetzt die Warteschlange und erbt dafür den Vorrang sauber aus dem Auftrag. |
| **Summe** | **28** | **30** | Korrektheit steht bewusst in zwei Zeilen, weil Beenden und Abgleich verschieden ausgehen. |

**Ergebnis: Mischform.** Das Gerüst kommt aus A: Ereignisse im Speicher, `reconcile()`, der Bestand bleibt. Aus B kommen vier Teile:
1. Invariante (I) wird zum Vertrag jeder Stufe.
2. Der Wächter im Store kommt vor der ersten Stufe.
3. Fakten und Kapitel-Tags bilden eine Stufe mit einem Platz.
4. Eine reine Routing-Funktion ersetzt den offenen Verteiler.

Den zweiten Container übernehme ich nicht. Was sich nicht ableiten lässt, kommt in `DeviceState`. Das schreibt schon gebündelt und leert beim Wechsel in den Hintergrund (DeviceState.swift:100-121).

## Zielbild

- **Der Store ist die Wahrheit, ein Ereignis ist ein Hinweis.** Verlorene oder doppelte Ereignisse schaden nicht.
- **Vertrag (I):** Eine Stufe prüft vor dem Start im `LibraryStore`, ob ihr Ergebnis für diese Eingangsfassung schon da ist. Sie schreibt über den Wächter und sendet ihr Ereignis erst, wenn das Schreiben zurückgekehrt ist. Einzige Ausnahme ist `episodesRemoved`: Der Abbruch soll beginnen, bevor der Store gelöscht hat.
- **Die Stufenakteure liegen im Paket** unter `P/PodcastAIKit/Pipeline/`, damit `swift test` sie prüft. UIKit, `BackgroundContinuation` und `BGTaskScheduler` bleiben in `S/`.
- **Nachrichten:**
  - Ereignisse laufen über den Router zu den Stufen.
  - Zustände (`WorkGate`, `ModelAvailabilityMonitor`) liefern immer den letzten Wert.
  - Befehle eines Menschen gehen direkt an eine Stufe, mit `origin: .user`.
- **AppModel bleibt Fassade** mit denselben Methoden und beobachtbaren Feldern. Keine Ansicht abonniert Ereignisse.
- **Keine neuen Auslöser.** Ein Ereignis entsteht dort, wo heute ein Direktaufruf steht. OPML-Import und „20 ältere Videos“ bleiben still (SubscriptionImport.swift:92-97, AM+So:156-189).

## Ereignisse

```swift
public enum Origin: Int, Sendable, Codable, Comparable { case backlog, automatic, user }

public enum PipelineEvent: Sendable {
    case episodesAdded([EpisodeID], Origin)
    case audioAvailable(EpisodeID, MediaVersionID)
    case audioRemoved([EpisodeID])
    case transcriptSaved(EpisodeID, InputVersion, Origin)
    case transcriptFailed(EpisodeID, TranscriptFailure, Origin)
    case evidenceReady(EpisodeID, InputVersion, Origin)
    case transcriptsIdle
    case factsDone(EpisodeID, InputVersion, FactsOutcome, Origin)
    case tagsDone(EpisodeID, InputVersion, ChapterTagsOutcome, Origin)
    case feedsRefreshed(byUser: Bool)
    case editionPublished(SmartFeedID, [PersonalEpisodeID])
    case episodesRemoved([EpisodeID], RemovalScope)   // .episode, .source(SourceID), .elsewhere
    case changedElsewhere(ChangeSet)                  // anfangs nur .all
}
```

`InputVersion` ist `MediaVersionID` plus Fingerabdruck des Transkripts. `Revision` taugt dafür nicht, sie ist immer `.initial` (TranscriptAssembler.swift:155-161).

| Ereignis | sendet | empfängt | ersetzt |
|---|---|---|---|
| `episodesAdded` | Refresh, Abo, Einzelfolge, Neu laden | Vorbereiten, Download (Vorhalten, heute AM:1241-1244) | `prepareNewEpisodes` an AM:1162, AM:1233, AM+S:73, AM+R:67. `RefreshResult.newEpisodes` wird von der Zahl zur Liste (Services.swift:25, 398) |
| `audioAvailable` | Download | Transkript | `backgroundDownloadArrived` (BD:161) |
| `transcriptSaved` | Transkript | Senke (Stadium `.transcribed`) | `onProgress` in AM:1894-1915 |
| `evidenceReady` | Transkript | Wissen, Download (Ton aufräumen), Senke | Kette AM:1943-1966 |
| `transcriptFailed` | Transkript | Vorbereiten, Download | AM:1983-2023 |
| `transcriptsIdle` | Transkript | Ausgaben | AM:1825 |
| `factsDone` | Wissen | Wissen (Tags derselben Folge) | AM+K:1868-1872 |
| `tagsDone` | Wissen | Senke (`chapterTagsRevision`) | fehlt heute (ablauf 2) |
| `feedsRefreshed` | Refresh | Ausgaben | AM:1168 |
| `editionPublished` | Ausgaben | Ausgaben (Cover, Zahlen) | AM:2739-2741, AM:3023 |
| `audioRemoved` | `removeAudio`, `tidyLocalAudio` | Download. Transkript rechnet nur den Wartezustand neu und ändert keine Daten | `queueConditionsChanged` (AM:1419) |
| `episodesRemoved` | Löschdienst, Sync | alle Stufen, Pflege, Caches | `prepareRemoval`, `applyRemoval` |
| `changedElsewhere` | Sync | alle Stufen (`reconcile`) | `reloadAfterSync` |

## Stufen

| Stufe | Eingang | Vorprüfung im Store | Ausgang | gespeichert |
|---|---|---|---|---|
| **Vorbereiten** (mit Supadata-Metadaten) | `episodesAdded`, Schalter, `transcriptFailed`, `evidenceReady` (Archiv rückt nach) | `analyzedEpisodeIDs()` (LS:1151) statt Speicher (AM:1302-1308) | Befehl an Transkript | `restingPreparation`, `failedInPreparation`, `backCatalog` wie heute |
| **Download** (Laden, Vorhalten, Vorausladen, Ton aufräumen) | Befehle, `evidenceReady`, `transcriptFailed`, `audioRemoved` | `downloader.existing` (CP:260) | `audioAvailable` | `DownloadResumeData`, Systemsitzung |
| **Transkript** (Ton, Podcast-Transkript, Zwilling, Supadata-Untertitel, ein Platz) | Befehl, `audioAvailable`, Gate | Transkript zur Fassung, vor dem Start **und** vor der Übernahme | `transcriptSaved`, `evidenceReady`, `transcriptFailed`, `transcriptsIdle` | `AnalysisQueueSnapshot`, `TranscriptCheckpoints` |
| **Wissen** (Fakten und Kapitel-Tags, ein Platz) | `evidenceReady`, Befehl „Jetzt ermitteln“, `ModelStatus` | Fakten ohne Lücken oder settled, `chapterTagBacklog` (LST:531) | `factsDone`, `tagsDone` | Lücken, Ablehnungen, settled, `ChapterTaggingProgress`, `PipelineIntents` |
| **Ausgaben** (Ausgaben, Zahlen, Cover) | `feedsRefreshed`, `transcriptsIdle`, Befehl (Knopf, Siri, `createSmartFeed`), BG-Aufgabe | `.alreadyPublished`, Cover-Rezept | `editionPublished` | Store, Cover-Dateien |
| **Pflege** | `episodesRemoved`, Start | nichts zu tun | keins | `pendingPurges` |

- **Transkript:** Die Stufe ruft `ContentPipeline` und `CaptionPipeline` auf. Belege sind ihr letzter Schritt, der Zwischenstand wird erst danach gelöscht (CP:384 kommt hinter CP:392). `reconcile()` findet „Transkript ohne Belege“ und bildet dann nur die Belege.
- **Wissen:** Nach den Fakten einer Folge kommen ihre Tags, dann weitere Fakten. Tags aus dem Rückstand laufen nur, wenn keine Fakten bereit sind (AM+T:280). Folge, Kapitel und Belege liest die Stufe beim Start frisch aus dem Store, nie aus dem `Episode`-Wert der Warteschlange.
- **Karenz:** Sieht die Stufe fremde Belege ohne Fakten zum ersten Mal, schreibt sie `firstSeen` in `PipelineIntents` und wartet bis `firstSeen + 20 min` (AM+K:1556). A rechnet ab `createdAt`, das übernehme ich nicht. Eigene `evidenceReady` warten nicht.
- **Unverändert ziehen mit:** `AutomaticWorkBudget`, `AnalysisQueueControl`, `newestCandidates`, die Reihenfolge aus `insertIntoQueue` (AM:1556) und die Regeln fürs Wiederholen (3 s, einmal hinten anstellen, 60 s Pause).
- **Keine Stufen:** Satz je Kapitel, Nennungen, Übersetzungen und Chat. Sie laufen auf Abruf mit `.user` und prüfen den `RemovalLedger`.

## Transport und Wiederaufnahme

**Router.** `PipelineRouter.deliveries(for: PipelineEvent, context: RoutingContext) -> [StageInput]` ist eine reine Funktion mit erschöpfendem `switch`. `RoutingContext` trägt Schalter wie `automaticFacts`. Die Verdrahtung steht nur hier. Ein neues Ereignis baut erst, wenn es geroutet ist.

**Host.**
- `PipelineHost` entsteht einmal in `AppBootstrap.start` (AppBootstrap.swift:46). Das `.task` je Szene (PodcastAIApp.swift:56-66) ist dafür der falsche Ort, es läuft auf dem iPad je Fenster.
- `emit(_:)` ist `nonisolated` und synchron. Es fragt den Router und legt die Eingänge ins Postfach jeder Stufe. Das Postfach ist ein `AsyncStream` mit `.unbounded`.
- `handle` sortiert nur in die Inbox ein und wartet nie. Die Inbox fasst je Folge zusammen, die höchste `Origin` gewinnt.

**Zustellung.** Zwischen einem Sender und einem Empfänger gilt FIFO. Die Reihenfolge über Stufen hinweg stellt der serielle Store her. Ein Ereignis kommt höchstens einmal an. Dass die Arbeit genau einmal wirkt, sichern (I) und `reconcile()`.

**`reconcile()`** läuft beim Start, bei `didBecomeActive`, nach `changedElsewhere` und zu Beginn jeder BG-Aufgabe. Beim Start gilt die Reihenfolge: abonnieren, `reconcile()`, Gate öffnen. Offen ist je Stufe:
- Transkript: Snapshot ohne die Folgen, die schon ein Transkript haben
- Belege: Transkript ohne Belege
- Wissen: Belege ohne Fakten und nicht settled, dazu Lücken und `chapterTagBacklog`
- Ausgaben: `earliestAutomaticEdition` (AM:3034)
- Pflege: `pendingPurges`

**Gespeicherte Absicht.**
- `AnalysisQueueSnapshot` bleibt im Format und bringt künftig auch Untertitel-Folgen zurück. Heute fallen sie an der Bedingung `audioURL != nil` heraus (AM:1617).
- Neu ist `PipelineIntents` in `DeviceState`: `factsRequested` samt Origin, `firstSeen` je Folge, `pendingPurges` und optional `lastFailure`.

**Gate.**
- `WorkGate` liefert einen Stream mit `.bufferingNewest(1)` und zusätzlich `current` über `Mutex`.
- Träger sind Leases: `hold(.continued | .analysisTask | .taggingTask | .uikit | .siri)`.
- `mayRun(stage, origin)` rechnet genau `mayStart`, `factsMayRun` und `tagsMayRun` nach (AnalysisQueueControl.swift:17, AM+K:1762, AM+T:55). Auf dem Mac gilt immer „vorn“.
- Entzieht das Gate den Träger, gibt der Auftrag zurück, ohne dass es als Fehlschlag zählt. Zwischenstand und Lücken bleiben.
- Der `expirationHandler` der BG-Aufgaben entzieht den Träger und ruft `setTaskCompleted` selbst auf (BW:156-197).

## KI-Anbindung

- **Scheduler hineinreichen:** `protocol AIScheduling { run(kind, priority, operation) }`. `AIScheduler` erfüllt es, die Stufen bekommen es übergeben.
- **Eine Tabelle** `AIPriorityPolicy.priority(kind:origin:force:)` ersetzt die verstreuten Werte:
  - Fakten `.user` bei `force` (AM+K:1155)
  - Tags erben die Origin des Faktenlaufs, heute fest `.background` (TagSelection.swift:253)
  - Relevanz einer angeforderten Ausgabe `.user`, heute `.background` (CP:782)
  - Antwort und Satz je Kapitel `.user`, alles Automatische `.background`
- **Parameter:** `TagSelector.select`, `selectRelevant` und `ContentPipeline.editionChapters` bekommen den Vorrang als Parameter.
- **Die Sitzung entsteht in der Operation**, nicht davor (KE:705-708, TagSelection.swift:253-256). Eine wiederholte Anfrage trägt dann keinen alten Verlauf mit. `transcriptErrorHandlingPolicy` ist gegen das installierte SDK zu prüfen. Die vorgewärmte Sitzung (KE:857-884) holt sich die Operation aus dem Vorrat.
- **Abbruch:** `job.task.cancel()` erreicht die laufende Anfrage (AIS:175-179, `withTaskCancellationHandler` ruft `task.cancel()`). Eine wartende Anfrage fällt über `dropWaiter` heraus. Eine abgebrochene Anfrage wird nicht wiederholt (AIS:183-186).
- **`ModelAvailabilityMonitor`** (Actor) liefert `ModelStatus` als Zustand. Die Nebenwirkungen von `refreshModelStatus` (AM+K:173-189) entfallen dabei.
- **Cover:** `.cover` kommt in `AIWorkKind` (AIS:33-35) und läuft nur vorn. SpeechAnalyzer bleibt draußen: Im einen Platz hielte er die Fakten für die Dauer jedes Transkripts auf.
- **Drei Ebenen bleiben getrennt:** Die Inbox regelt die Reihenfolge, der Scheduler den Vorrang je Aufruf, das Gate die Erlaubnis.

## Löschen und Sync

**Löschprotokoll.** `RemovalLedger` (nonisolated, `Mutex`, je Prozess) ersetzt `removalCount` und `removalTickets` (AM+K:2578-2588). Er ersetzt auch die Tickets von `MentionCache`, `ChapterSummaryCache` und `TranslationCache`.

**„Folge löschen“** läuft in dieser Reihenfolge:
1. Im Ledger markieren (synchron).
2. `pendingPurges` ergänzen.
3. `episodesRemoved` senden. Jede Stufe streicht die Folge aus ihrer Inbox und bricht einen passenden Auftrag ab, auch bei Fakten und Tags. Heute trifft der Abbruch nur `pipelineRun` (AM+K:2581).
4. `store.removeEpisode` (LS:1183).
5. Die Pflege räumt Dateien, Caches und die DeviceState-Einträge der Folge (`factsSettled`, `tagsSettled`, `rejectedFactSlices`, `failedInPreparation`, `captionFailures`, `audioTwinRecords`). Danach streicht sie den Eintrag aus `pendingPurges`.

Das Aufräumen lässt sich beliebig oft wiederholen, ein Neustart setzt es fort. `removeSource` geht denselben Weg mit `.source`.

**Wächter im Store.**
- `CommitGuard` prüft im selben ModelActor-Schritt wie das Schreiben: Die Folgenzeile ist da, sie trägt kein Merkzeichen, die Fassung ist aktuell, die Quelle besteht und die Folge steht nicht im Ledger.
- Er gilt für `save(transcript:)`, `store(evidence:)`, `save(facts:)` und `save(chapterTags:)`. Damit schließt sich auch die Lücke bei fehlenden Zeilen (LST:349).
- Ausgaben werden je Zeile geschrieben, ihre Segmente prüft der Wächter mit.
- Ergebnis ist `.stale` oder ein `WriteReceipt` mit den geschriebenen Kennungen. Späte Schreibvorgänge räumt die Stufe nach diesen Kennungen weg. So trifft das Aufräumen auch YouTube-Folgen, die heute durchfallen (AM+K:2609-2611, CaptionPipeline.swift:27-29).

**Audio entfernen** erreicht nur den Download. `markAudioRemoved` (LS:1309) bleibt in dieser Release, wie es ist.

**Sync.** Ein `SyncObserver` (Actor) ersetzt `observeRemoteChanges` (AM+K:35-55).
- **Phase 1:** `reloadAfterSync` ruft `load()` wie heute, danach folgen `changedElsewhere(.all)` und `reconcile()` aller Stufen. Ein Merkzeichen wird zu `episodesRemoved(.elsewhere)`. Damit transkribiert kein Gerät mehr eine Folge, deren Transkript schon angekommen ist (ablauf 1), und Wissen vergisst `tagsCurrent` (ablauf 4).
- **Phase 2:** Das `ChangeSet` kommt aus der History (LS:55-73), neu geladen wird nur das Betroffene. `removeDuplicatesWithReport` (LS:299-359) wird ein Pflege-Auftrag, beschränkt auf das `ChangeSet`. Ob gelöschte Zeilen ihre Kennung behalten (`preserveValueOnDeletion`), ist gegen das SDK und auf CloudKit-Tauglichkeit zu prüfen.
- **Zwei Geräte an derselben Folge:** Die Prüfungen vor Start und Übernahme verkleinern das Fenster, schließen es aber nicht. Eine abgeglichene Sperre gibt es in dieser Release nicht.

## Oberfläche

- **Senke:** `PipelineSink` (`@MainActor`) schreibt in `EpisodeProgressBoard` (EpisodeProgress.swift:23-78) und in die AppModel-Felder mit ihren heutigen Namen: `stages`, `stageDetails`, `factsProgress`, `analysisQueue`, `analyzing`, `factsQueue`, `gatheringFacts`, `chapterTagsRevision`, `downloadProgress`. Meldungen je Folge kommen höchstens alle 250 ms.
- **Befehle:** Anfordern, Verschieben, Entfernen, Pause, Fortsetzen, Abbrechen und `buildEdition` gehen über AppModel an die Stufe (ListeningViews.swift:2206-2214, ActivityStatus.swift:131-153).
- **Zähler:** `runnableQueueCount` rechnet die Transkript-Stufe. Die Ansicht prüft keine Dateien mehr (AM:1478).
- **Mobilfunk:** Die Stufe meldet „wartet auf Zustimmung“, `askBeforeMobileData` fragt, und die Antwort geht ans Gate.
- `AIPipelineStatus` bleibt (AIPipelineStatus.swift:34-39). Keine Ansicht ändert sich.

## Migrationsschritte

Nach jedem Schritt laufen `swift test`, beide Schemata und die UI-Tests, dazu `ScrollUnderLoadUITests` und `ProcessingBenchmark` vorher und nachher. Schritte, die den Hintergrund berühren, werden einmal auf dem Gerät geprüft. Je Stufe gibt es einen Schalter alt/neu für eine TestFlight-Runde. Eine Stufe hat nie zwei Besitzer.

0. **Grundlage (M).**
   - Neu: `P/PodcastAIKit/Pipeline/` mit `PipelineEvent`, `Origin`, `PipelineRouter`, `PipelineHost`, `WorkGate`, `RemovalLedger`, in der App `PipelineSink`.
   - Der alte Code sendet an seinen heutigen Stellen, zuhören tut nur ein Test-Rekorder.
   - Geändert: AppBootstrap.swift:46-64, Services.swift:25/398, AM+K:2578-2588, ChapterSummaries.swift:61-100, EpisodeMentions.swift:62-118, OnDeviceTranslation.swift:106-150.
1. **Wächter im Store (M).**
   - `CommitGuard`, `WriteReceipt`, `pendingPurges`. CP:384 kommt hinter CP:392.
   - Die heutigen Wege nutzen den Wächter, `purgeLateWrites` räumt nach dem Receipt.
   - Geändert: LS:1014-1114, LS:1581-1600, LST:343-391, LibraryStore+LateWrites.swift, AM+K:2550-2659, DeviceState.swift.
2. **Naht zur KI (M).**
   - `AIScheduling`, `AIPriorityPolicy` mit den heutigen Werten, Sitzung in der Operation, Parameter für den Vorrang, `ModelAvailabilityMonitor`.
   - Geändert: AIS:33-35, KE:151-170/683-741/857-884, TagSelection.swift:246-262, CP:760-808, AM+K:159-208.
3. **Wissen.**
   - 3a (M): `KnowledgeStage` übernimmt Warteschlange, Reihenfolge, Gate und `PipelineIntents`. Der Auftrag ruft `prepareFacts` und `prepareChapterTags` noch über eine `@MainActor`-Closure auf. `runAnalysis` sendet `evidenceReady`. `factsGrants` und `tagGrants` werden Leases.
   - 3b (L): Der Code zieht in den Actor, `facts[id]` und `lastError` laufen über die Senke.
   - Geändert: AM+K:1071-1371, AM+K:1589-1935, AM+T:55-335, AM:481-544, BW:162-198.
4. **Ausgaben, Zahlen, Cover (M).**
   - Schreiben je Zeile, Segmente beim Übernehmen prüfen, Cover unter `.cover`.
   - Geändert: LS:1807, AM:2458-3040, CoverView.swift:380-716, AutoRefresh.swift:33-53, Intents.swift:108-179.
5. **Erschließen.**
   - 5a (M): Vorbereiten und Download. Der Download meldet Fortschritt an die fortgesetzte Verarbeitung.
   - 5b (L): Transkript samt `runCaptionAnalysis`. Der alte Weg bleibt eine Runde per Startargument erreichbar, der Snapshot bleibt lesbar.
   - Geändert: AM:1233-1380, AM:1488-2160, AM+A, AM+Y:268-380, BD, TN, BackgroundContinuation.swift, BW:138-160.
6. **Abgleich über die History (L).**
   - `SyncObserver`, `ChangeSet`, Bereinigen als Pflege.
   - Geändert: LS:44-73, LS:299-359, AM+K:35-147, AM:751-835.
7. **Abbau (M).**
   - Alte Warteschlangen, Grants, Tickets und Schalter entfallen.
   - docs/architektur.md wird nachgezogen, auch Zeile 23: `backCatalog` liegt in DeviceState, nicht in den Benutzereinstellungen.

## Teststrategie

- **Bleiben grün:** ResumeAndQueueTests, QueueControlTests, PipelineTests, FactsTests, RemovalAndSyncTests, LateWriteAndRejectionTests, ForeignChangeTests, SyncMergeTests, AISchedulerTests.
- **Router:** Tabellentest je Ereignis mit Kontext.
- **Je Stufe mit Fakes:** `makeContainer(inMemory:)`, `FakeScheduler` (schreibt den Vorrang mit und kann verdrängen), `FakeGate`, eine aufzeichnende Senke und eine steuerbare Uhr. Geprüft wird:
  - Ein zweiter Lauf ruft weder Modell noch Spracherkennung.
  - Was der Store als offen zeigt, findet die Inbox über `reconcile()`.
  - Die Tabelle der Prioritäten stimmt.
- **Absturz:** Abbruch zwischen Übernahme und Senden, dann ein neuer Host. Es dürfen keine doppelten Belege oder Fakten entstehen und keine zweite Ansage kommen.
- **Löschmatrix:** Gelöscht wird zu fünf Zeitpunkten: eingereiht, wartet im Scheduler, vor der Übernahme, nach der Übernahme, fertig. Jeder Zeitpunkt wird mit `removeEpisode`, `removeSource` und einem fremden Merkzeichen geprüft. Danach bleiben keine Zeilen, Dateien oder DeviceState-Einträge. „Audio entfernen“ lässt an jedem Punkt alle Daten stehen.
- **Sync:** Ein zweiter Kontext schreibt mit fremdem Autor. Die wartende Folge wird nicht transkribiert, und `firstSeen` übersteht einen Neustart.
- **UI:** `-uitest-fresh` leert auch `PipelineIntents`.

## Risiken und Gegenmaßnahmen

| Risiko | Gegenmaßnahme |
|---|---|
| Arbeit bleibt still liegen, weil `reconcile()` einen Fall nicht kennt | Ein Test je Stufe. In Debug-Builds vergleicht die App „offen laut Store“ mit der Inbox |
| Reentrancy: „vormerken vor dem ersten await“ (AM+K:1073-1075) sichert heute der MainActor | Inbox und `job` nur in synchronen Abschnitten ändern. `emit` bleibt nonisolated und synchron, die Übernahme prüft der Ledger |
| Puffer ohne Grenze | `handle` wartet nie, die Inbox fasst je Folge zusammen, Massenereignisse tragen Arrays |
| Eine Queue für den Store | Das löst dieser Umbau nicht. `ProcessingBenchmark` misst jeden Schritt |
| Fortgesetzte Verarbeitung läuft ab, weil der Fortschritt steht (BGTask.h:124-126) | Download und Supadata melden Fortschritt ab Schritt 5a |
| 3b löst `prepareFacts` vom MainActor | 3a zuerst ausliefern, 3b erst nach einer TestFlight-Runde |
| Rückweg auf 0.12 | Der Snapshot bleibt im alten Format, 0.12 ignoriert `PipelineIntents` |

## Offene Entscheidungen für den Product Owner

1. **Vorrang erben:** Tags nach „Jetzt ermitteln“ und die Relevanz einer angeforderten Ausgabe oder einer Siri-Anfrage laufen mit `.user`. *Empfehlung: ja.* Das ist die Regel aus dem Ziel.
2. **Scheduler:** Image Playground kommt als `.cover` hinein, SpeechAnalyzer bleibt draußen, es gibt keine eigene PCC-Spur. *Empfehlung: so.* Über die PCC-Spur nach einer Messung entscheiden.
3. **Pause und „Alle abbrechen“** gelten für alle Stufen, auch für Ausgaben, Vorhalten und Metadaten. *Empfehlung: ja.* So beschreibt es architektur.md schon.
4. **DeviceState beim Löschen räumen** (daten 10). *Empfehlung: ja*, das verlangt Regel 5.
5. **Karenz ab dem ersten Sehen**, auch im ersten Lauf nach dem Start. Nach einer Neuinstallation warten die Fakten einer abgeglichenen Bibliothek dann 20 Minuten. *Empfehlung: ja.*
6. **Ausgaben zusätzlich auf `tagsDone` auslösen.** *Empfehlung: nicht in dieser Release.* `tagsDone` hebt nur `chapterTagsRevision`, der Auslöser für Ausgaben bleibt aus.
7. **Kapitel aus `chaptersURL` vor Fakten und Tags laden.** Das kostet eine Anfrage je Folge (ablauf 5). *Empfehlung: ja, in 3b*, nach den Netzregeln fürs Vorbereiten.
8. **Fehler je Folge** in `lastFailure` speichern. *Empfehlung: speichern ja, anzeigen wie heute.*
9. **Fortgesetzte Verarbeitung nur für Angefordertes** (BGTask.h:121). *Empfehlung: Verhalten behalten* und den Fortschritt nachrüsten. Nach einer Messung neu entscheiden.
10. **Cover-Schlüssel mit der Menge der Segmente** (daten 6), ohne Schemaänderung. *Empfehlung: ja, in Schritt 4.*
11. **Schemaänderungen:** ein Merkmal „Quelle abbestellt“, `localRelativePath` nicht mehr abgleichen, eine feste Sprache für die Kennung des Transkripts, eine Sperre über Geräte hinweg. *Empfehlung: nächste Release.* In dieser Release sucht die App beim Start nur lokal nach verwaisten Dateien.

## Gegenprüfung

# Prüfung des Pipeline-Plans

Ich habe nur gelesen. Die Kürzel sind die aus dem Plan, dazu CPL = CaptionPipeline.swift und DS = DeviceState.swift.

## Falsche Annahmen über den Code

- **`RemovalLedger` liegt im falschen Modul.** `PodcastAIPersistence` hängt nicht von `PodcastAIKit` ab (Package.swift:35-37, 52-55). `CommitGuard` in `LibraryStore` sieht deshalb keinen Ledger unter `PodcastAIKit/Pipeline/`. Er gehört nach Core oder Persistence.
- **`FactsOutcome` (AM+K:1375) und `ChapterTagsOutcome` (AM+T:26) sind Typen der App.** `PipelineEvent` im Paket kann sie nicht tragen. Schritt 0 muss sie ins Paket verschieben, im Plan steht das nicht.
- **„Fassung ist aktuell“ lässt sich an `save(transcript:)` nicht prüfen.** Die Methode setzt `currentMediaVersionIdentifier` selbst (LS:1047). Vergleichen muss der Wächter mit der Fassung aus `audioURL` bzw. aus der Videoadresse (CPL:27-29).
- **`save(transcript:)` kehrt bei vorhandener Kennung still zurück (LS:1058-1062).** Danach speichert CP:386-392 Belege aus dem Transkript im Speicher, die zum gespeicherten Transkript nicht passen. Der Wächter muss „schon da“ melden, und die Belege entstehen dann aus dem gespeicherten Transkript.
- **CP:384 hinter CP:392 zu schieben ist die schwächere Lösung.** `save(captions:)` schreibt Transkript und Belege schon in einem Actor-Schritt (CPL:88-91). Ein `save(transcript:media:evidence:)` für alle drei Wege in CP (367/392, 474, 614) beseitigt den Zustand „Transkript ohne Belege“ ganz.
- **„Die Reihenfolge über Stufen stellt der serielle Store her“ stimmt nicht.** Ereignisse gehen erst nach dem `await` hinaus, `episodesRemoved` kann also vor `evidenceReady` bei Wissen ankommen. Jede Stufe prüft den Ledger beim Entnehmen und vor jedem Schreiben in DeviceState. Sonst legt sie Lücken und Stand nach der Pflege neu an.
- **Ein Ledger als Menge bricht das Neu-Abonnieren im selben Prozess.** Dieselben Kennungen kommen zurück (AM+K:2532, 2605-2606). Nötig ist ein Ticket je Löschung, verglichen mit dem Ticket beim Start des Auftrags.
- **`setTaskCompleted` im `expirationHandler`** kommt zum Aufruf nach `work.result` hinzu (BW:156-159, 177-180, 194-197). Das braucht einen Einmal-Riegel.

## Fehlende Ereignisse und Empfänger

- **`refreshAll` ruft ohne Bedingung** `prepareNewEpisodes`, `queueMissingFacts`, `refreshRelevantToday` und `tidyLocalAudio` auf (AM:1162-1165). Laut Plan geht `feedsRefreshed` nur an Ausgaben. Nach „Alle abbrechen“ und Ziehen reiht dann nichts mehr nach.
- **„Für dich“** (`refreshRelevantToday`, AM:923) ist weder Stufe noch Empfänger. Aufrufer sind AM:829, 1164, 1966, 2115, 2198-2262 sowie AM+K:2616 und 2657.
- **Nicht abgebildet sind:**
  - die Schalter (AM:103-141, 163-169, 331-352, 460-465, 548-559; AM+Y:211-271)
  - das Netz (AM:246, 1378) und die Sprachmodelle (AM:1442)
  - `didBecomeActive` → `queueMissingFacts` (AM+K:1830-1835)
  - `loadFacts` aus der Ansicht (AM+K:1950-1955)
  - die Tag-Haltung (AM:2198-2262)
- **Laden hätte zwei Besitzer:** die Download-Stufe und `ContentPipeline` (CP:258-270). Die Stufe sollte nur Vorhalten, Vorausladen und Aufräumen übernehmen.
- **Die Ansage (AM:1951-1953) hat keinen Besitzer.** Sie gehört in die Senke bei `evidenceReady(.user)` und darf nie bei Arbeit aus `reconcile()` kommen.
- **In `PipelineIntents` fehlen** Supadatas `pendingJobs` und der Schutzschalter.

## Beenden und Abgleich

- **`DeviceState.set` schreibt asynchron** (DS:100-115). `pendingPurges` braucht `flush()` (DS:119) vor `store.removeEpisode`. Sonst bleibt nach einem Absturz bei `removeSource` Verwaistes liegen, denn dort gibt es kein Merkzeichen.
- **Vor dem ersten Entsperren liefert das Lesen `nil`,** und das nächste `set` überschreibt die Datei (DS:62-67). `isProtectedDataAvailable` kommt im Code nicht vor (grep leer). `reconcile()` und Pflege sollten daran hängen, die Absichten als getrennte Schlüssel.
- **Die Vorprüfung läuft über `transcript(forMedia:)`** (LS:1088), nicht über die Kennung des Transkripts, denn die Sprache unterscheidet sich je Gerät.
- **Die Karenz wird ein Rückschritt.** Heute wartet nach dem Start nichts (AM+K:1638). Mit `firstSeen` warten auch eigene, abgebrochene Folgen 20 Minuten. Automatisch Wartendes sollte mit gespeichert werden, oder die App merkt sich ihre eigenen Transkripte.
- **`reconcile()` bei jedem `changedElsewhere` und `didBecomeActive`** durchsucht die ganze Bibliothek auf der einen Store-Queue. Das gehört gebündelt und auf die Warteschlangen für Transkript und Wissen beschränkt.
- **BGAppRefresh:** `load()` plus `reconcile()` in etwa 30 Sekunden, obwohl dort keine Stufe läuft (AM:1161). Dort `reconcile()` weglassen.

## Migration bricht Tests oder App

- **Der Wächter auf den bestehenden Methoden (Schritt 1) bricht Tests:**
  - ChapterClassificationTests.swift:393-401 (Kapitel-Tags ohne Folgenzeile)
  - SyncRepairTests.swift:133 (absichtlich verwaiste Belege)
  - DemoContent.swift:103-117 und DemoBacklog.swift:128-141 sind zu prüfen.

  Besser neue `commit…`-Methoden einführen und die alten stehen lassen.
- **`newEpisodes` als Liste** (Services.swift:25, 391, 398) verlangt Kennungen aus `upsert(episodes:)`. SyncRepairTests.swift:156 erwartet dort aber `== 0`.
- **`.cover` bricht den `switch`** in AIPipelineStatus.swift:55-62, dazu fehlen Texte auf Deutsch und Englisch. Der Vorrang ist offen: Mit `.user` laufen Fakten-Abschnitte neu (AIS:183-187), mit `.background` wartet das Cover hinter den Fakten.
- **`Origin: Int, Comparable` bekommt kein synthetisiertes `<`,** denn Enums mit Rohwert sind davon ausgenommen.

## Swift 6

- **`RoutingContext` mit `automaticFacts`** ist im synchronen, nonisolated `emit` nicht lesbar, weil der Wert dem MainActor gehört. Der Router sollte nur die Wege kennen, die Schalter liest die Stufe beim Start.
- **Die Empfangsschleife startet den Auftrag als `Task`** und wartet nicht darauf. `placeFacts`, `ChapterClassifier` und `PassageBuilder` laufen losgelöst, sonst steht die Inbox.
- **Gegen iPhoneOS27.0.sdk geprüft:** `LanguageModelSession` ist `@unchecked Sendable`, und `transcriptErrorHandlingPolicy` lässt sich setzen (`.revertTranscript`).

## Regeln und CloudKit

- **Regel 5:**
  - `addDetectedTag` mitten im Lauf (AT:181) lässt Tags nach dem Löschen stehen. Das Anlegen gehört in den geschützten Commit.
  - Der Pflege-Liste fehlen `dismissedFromPreparation`, `restingPreparation`, die Supadata-Metadaten, die Übersetzungen und die Einträge in `PipelineIntents` selbst.
  - Chat, Pfade, `pruneEditions`, Spotlight und PassageIndex aus `applyRemoval` gehören ebenfalls in `pendingPurges`.
- **Der Wächter darf nie lokalen Ton verlangen.** `markAudioRemoved` leert nur `localRelativePath` (LS:1309-1318).
- **Die Frage nach Mobilfunk bleibt beim Tippen** (AM:1510-1519). Keine Stufe fragt später (architektur.md:192).
- **Regel 2:** `origin` setzt nur der Code am Befehl. Weder Feed noch Supadata noch abgeglichene Zeilen heben ihn an. `lastFailure` wird nur angezeigt.
- **CloudKit:** `preserveValueOnDeletion` (Schritt 6) ändert den Modell-Hash. Das vorher gegen das CloudKit-Schema prüfen.
- **iPad:** `.task` und `.autoRefresh()` laufen weiter je Szene (PodcastAI/PodcastAIApp.swift:56-66, 162). Der Plan verlegt nur den Host.

## Korrekturen zum Anhängen

- Ledger mit Tickets nach Core. Die Stufe liest ihn beim Entnehmen und vor jedem Schreiben in DeviceState.
- Die Outcome-Typen in Schritt 0 ins Paket verschieben.
- Transkript und Belege in einem Store-Schritt speichern, den Wächter als neue `commit…`-Methoden bauen.
- Die Fassung gegen `audioURL` bzw. die Videoadresse prüfen, die Vorprüfung läuft über die Fassung.
- `feedsRefreshed` geht an Vorbereiten, Wissen, Download, „Für dich“ und Ausgaben.
- „Für dich“ empfängt `evidenceReady`, `feedsRefreshed` und `episodesRemoved`.
- `flush()` vor dem Löschen. Pflege und Absichten laufen nur, wenn die geschützten Daten lesbar sind.
- Einmal-Riegel für `setTaskCompleted`.
- Für den Product Owner: Vorrang für `.cover` festlegen.