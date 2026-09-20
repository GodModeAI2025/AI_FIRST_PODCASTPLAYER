# BrainSpeak-Ist-Audit — durchgeführt am echten Checkout

**Quelle:** `BrainSpeak-main` (ZIP-Lieferung vom 2026-09-20) · **Art:** read-only Lesung, keine Änderung
**Verhältnis zum Paket:** Dies ist die inhaltliche Antwort auf T001 und T004. Solange das Paket hashgesichert
bleibt, liegt das Ergebnis hier; bei formaler Ausführung von T001 wandert es nach `audit/brainspeak-baseline.md`
und `audit/integration-map.md` mit neu erzeugtem `PACKAGE_MANIFEST.json`.

---

## 0. Das zentrale Ergebnis in drei Sätzen

**BrainSpeak ist kein Podcast-Player.** Es ist eine On-Device-Diktier- und Aufnahme-App: Hotkey halten, sprechen,
loslassen — der Text erscheint an der Cursorposition, lokal verarbeitet über SpeechAnalyzer und Foundation Models.
Die Annahme des Spec-Kit-Pakets, man erweitere „BrainSpeak um einen quellenfähigen Medien-/Wissenskern“, trifft
**nicht** zu: es gibt keine Zeile Podcast-Domäne. Was es gibt, ist eine sehr brauchbare Sprach-, KI-, Persistenz- und
Mehrplattform-Schicht — der Wiederverwendungswert ist real, liegt aber eine Ebene tiefer als angenommen.

---

## 1. Harte Fakten

| Merkmal | Befund |
|---|---|
| Umfang | 115 Swift-Dateien, **11 145 Zeilen** Produktivcode; 22 Testdateien, 1 123 Zeilen (≈ 10 %) |
| Lizenz | **MIT** — löst die GPL-Sorge aus T107 auf |
| Projektdefinition | XcodeGen (`project.yml`), kein eingecheckter `.xcodeproj` |
| Targets | `BrainSpeak` (macOS), `BrainSpeakiOS` (iOS/iPadOS), `BrainSpeakKeyboard` (App-Extension), `BrainSpeakWatch` (watchOS), `BrainSpeakTests` |
| Shared Package | `Packages/BrainSpeakKit` — Audio, Intelligence, Models, Persistence, Preferences, Transcription |
| Deployment | **macOS 26.0 · iOS 26.0 · watchOS 11.0** |
| Toolchain | **Xcode 26.0, Swift 6.2**, `swift-tools-version: 6.2`, `enableExperimentalFeature("StrictConcurrency")` |
| Signing | `DEVELOPMENT_TEAM` gesetzt, Automatic; macOS **ohne App Sandbox** (Direct Download, notarisiert) |
| Persistenz | SwiftData, ein `@Model Recording`, App-Group-Container `group.com.brainspeak.shared` |
| Sync | **SwiftData-eigene CloudKit-Spiegelung** (`RecordingStore.makeContainer(cloudKit: true)`), Container `iCloud.com.brainspeak.app` |
| Tests | 22 Dateien, **ausschließlich XCTest**, 0× Swift Testing; keine UI-Tests |
| UI-Stand | 9 Dateien `@Observable`, 6 Dateien `ObservableObject` — Migration unvollständig |

---

## 2. Was BrainSpeak kann — und was es nicht kann

### Vorhanden und für BrainSpeak-als-Wissensplayer wertvoll

| Baustein | Pfad | Warum relevant |
|---|---|---|
| **On-Device-STT** | `BrainSpeakKit/Transcription/TranscriptionEngine.swift` (223 Z.) | `SpeechAnalyzer` + `SpeechTranscriber`, volatile und finale Ergebnisse, saubere Lifecycle- und Fehlerpfade. Genau der Kern von US1. |
| **Datei → PCM-Strom** | `BrainSpeakKit/Audio/AudioFileReader.swift` | Liest eine lokale Audiodatei **lazy in 4096-Frame-Blöcken** in die Engine. Erfüllt wörtlich, was `plan.md` §2 fordert: „Große Audiofiles werden nicht vollständig als Data in RAM gehalten.“ |
| **Formatkonvertierung** | `BrainSpeakKit/Audio/BufferConverter.swift` | Beliebiges Eingabeformat → Analyzer-Format |
| **Sprachmodell-Assets** | `BrainSpeakKit/Transcription/LocaleManager.swift` | Locale-Prüfung und Modell-Download (~300 MB) |
| **Apple-Intelligence-Client** | `BrainSpeakKit/Intelligence/FoundationModelsClient.swift` | `SystemLanguageModel.default`, saubere Availability-Behandlung, **frische Session pro Anfrage** — verhindert Kontextleckage zwischen Aufnahmen. Diese Eigenschaft ist exakt das, was der `ChatScopeSnapshot` braucht. |
| **Modus-Engine** | `BrainSpeakKit/Intelligence/ModeEngine.swift` + `Modes/` | Sechs Modi mit eigenen Instructions und `@Generable`-Ausgabetypen. Das Muster „Profil besitzt eigene Instruktion und typisierte Ausgabe“ ist die Vorlage für `extract`/`answer`/`recommend`/`proposePlayback`. |
| **SwiftData + App Group** | `BrainSpeakKit/Persistence/RecordingStore.swift` | Container wird korrekt aus dem App-Group-Container gebaut, inkl. macOS-Sonderfall (Entitlement-Prüfung vor Gruppen-URL) |
| **Now Playing / Fernsteuerung** | `Sources/iOS/Detail/AudioPlayerView.swift` | `MPNowPlayingInfoCenter` und `MPRemoteCommandCenter` sind verdrahtet — wiederverwendbar |
| **Watch-Transfer** | `Sources/watchOS/`, `Sources/iOS/Watch/`, `WatchAudioArchive.swift` | WatchConnectivity mit dauerhaftem lokalem Archiv, Retry nach Reconnect |
| **Vier Plattformen existieren bereits** | `project.yml` | Die Shells sind da, nicht nur geplant |

### Nicht vorhanden — hier ist es Neubau, keine Erweiterung

| Fehlt | Nachweis | Betroffener Meilenstein |
|---|---|---|
| **Jegliche Podcast-Domäne** | `grep -riE "RSS\|XMLParser\|OPML\|Atom\|podcast"` über alle `.swift` → **0 Treffer** | M1 (US2), M9a (US14) |
| Episode, Feed, MediaVersion, Chapter, Evidence | Das einzige Modell ist `Recording` mit sechs Textfeldern | M1–M3 |
| **Mediengenauer Zeitbezug im Transkript** | siehe §3 — der wichtigste Befund | M3, M6, alles danach |
| Wiedergabe von Mediendateien mit exakten Grenzen | `AVAudioPlayer` für lokale Aufnahmen; kein `AVPlayer`, kein `AVQueuePlayer`, kein `forwardPlaybackEndTime` | M2, M6 |
| App Intents, App Entities | `grep -rl "AppIntent\|AppEntity"` → **0 Dateien** | M8b (FR-056) |
| Core Spotlight | `grep -rl "CoreSpotlight\|CSSearchable"` → **0 Dateien** | M4 (Index), Lücke FR-145 |
| BackgroundTasks | `grep -rl "BGTaskScheduler\|BackgroundTasks"` → **0 Dateien** | M3 (GATE-BG) |
| WidgetKit | 0 Dateien | FR-053 |
| Private Cloud Compute | Kein `PrivateCloudComputeLanguageModel`, kein PCC-Eintrag in vier `.entitlements` | M4 (GATE-PCC) |
| Semantischer Index, Retrieval, Chat | nicht vorhanden | M4 |
| Markdown-Export | nicht vorhanden | M8c |
| MCP | nicht vorhanden | M9a |

---

## 3. Der wichtigste Einzelbefund: das Transkript hat keine Medienzeit

`TranscriptionEngine.swift:98`:

```swift
let transcriber = SpeechTranscriber(
    locale: locale,
    transcriptionOptions: [],
    reportingOptions: [.volatileResults],
    attributeOptions: []          // ← keine Zeitattribute angefordert
)
```

und `TranscriptionResult.swift`:

```swift
public let text: String
public let isFinal: Bool
public let timestamp: Date       // Wanduhrzeit für Latenzmessung — NICHT die Position im Medium
```

**Warum das der kritische Punkt ist:** Das gesamte Produkt steht auf Versprechen V1 (jede Aussage führt zurück auf
Folge → Medienfassung → **Timecode**) und V2 (nur die relevanten Originalstellen abspielen). Beide sind ohne
mediengenaue Zeitbereiche pro Segment unmöglich. Die aktuelle Engine verwirft genau diese Information — für eine
Diktier-App völlig richtig, für einen Wissensplayer disqualifizierend.

**Gute Nachricht:** Es ist kein Architekturfehler, sondern eine nicht angeforderte Option. `SpeechTranscriber` kann
Zeitbereiche als Attribut liefern. Die Änderung ist eng umrissen:

1. `attributeOptions` um den Zeitbereich erweitern,
2. `TranscriptionResult` um einen `CMTimeRange` (oder Start/Dauer) ergänzen und die Attribute durchreichen,
3. den Checkpoint aus `plan.md` §2 ergänzen: Sampleposition, Asset-ID, Locale, Analysekonfiguration, Textrevision,
4. Wiederaufnahme mit kleinem Überlappungsbereich und Deduplizierung.

Das ist Arbeit von Tagen, nicht von Wochen — **wenn** es in M3 passiert. Wird es später bemerkt, ist jedes darauf
aufbauende Artefakt wertlos. Diese Punkte gehören in M3 als erste Aufgaben, vor allem anderen.

---

## 4. Zwei Architekturkonflikte mit der Constitution

### K1 — Sync: SwiftData-Spiegelung gegen CKSyncEngine

BrainSpeak nutzt die **automatische CloudKit-Spiegelung von SwiftData**. Constitution IX und ADR-0003 verlangen das
Gegenteil: „CKSyncEngine ist der einzige Sync-Writer“ und ausdrücklich „Kein doppeltes SwiftData-Auto-Sync plus
CKSyncEngine für dieselben Records“.

Das ist kein Detail. Die automatische Spiegelung erzwingt, dass **jede Eigenschaft optional oder vorbelegt** ist und
**keine Unique-Constraints** existieren — im `Recording`-Modell gut sichtbar, jedes Feld hat einen Defaultwert. Das
Paket verlangt dagegen unveränderliche oder revisionierte Artefakte, stabile Identität, Outbox und Tombstones im
selben Commit sowie ConflictCopy statt Textverlust. Beides zugleich geht nicht.

**Folge für M7:** US10 ist keine Erweiterung des Bestehenden, sondern eine **Migration** — inklusive Migrationspfad
für bereits in iCloud liegende Aufnahmen echter Nutzer. Das ist heute nicht im Plan eingepreist.

### K2 — Plattformversionen: 26 gegen 27

| | BrainSpeak heute | Constitution III |
|---|---|---|
| macOS / iOS / iPadOS | 26.0 | **27.0** |
| watchOS | **11.0** | **27.0** |
| Xcode | 26.0 | **27** |
| Swift | 6.2 | **6.4, Swift-6-Sprachmodus** |

Der watchOS-Wert ist zusätzlich in sich auffällig: `.watchOS(.v11)` neben `.macOS(.v26)` und `.iOS(.v26)`, und das
README nennt „watchOS 11 or later“. Entweder ist das ein stehengebliebener Wert oder die Watch-Zielversion wurde nie
mitgezogen — vor M0 zu klären, weil es die Watch-Fähigkeiten bestimmt.

Ein Sprung auf 27.0 überall hebt zudem die **Mindesthardware** an und schließt Bestandsnutzer aus. Das ist eine
Produktentscheidung, keine Buildeinstellung.

---

## 5. Ausgefüllte Integrationskarte

Ersetzt die Spalte „nicht ermittelt“ in `audit/integration-map.md`.

| Zuständigkeit | Vorhandener Codepfad | Entscheidung | Notwendiger Nachweis |
|---|---|---|---|
| Audio-/Dateiimport | `BrainSpeakKit/Audio/AudioFileReader.swift`, `AudioFileWriter.swift`, `BufferConverter.swift` | **erweitern** — Download, Validierung, Hash und MediaVersion fehlen | Formate, Hintergrund, atomarer FileStore |
| Speech/Transkription | `BrainSpeakKit/Transcription/TranscriptionEngine.swift`, `TranscriptionResult.swift`, `LocaleManager.swift` | **erweitern, zuerst** — Medienzeit und Checkpoint ergänzen (§3) | finalisierte Zeitsegmente, Wiederaufnahme mit Überlappung |
| Apple-Intelligence-Router | `BrainSpeakKit/Intelligence/FoundationModelsClient.swift`, `ModeEngine.swift`, `Modes/` | **erweitern** — PCC, Profile mit Tools, Evidence-ID-Auswahl fehlen | Framework, Modell, Entitlement, Fehlerpfade |
| Wissen/Index/Chat | — | **neu** | Scope und Evidenz |
| Persistenz/CloudKit | `BrainSpeakKit/Persistence/RecordingStore.swift`, `Recording.swift`, `RecordingAudioSync.swift`, `RecordingDeletion.swift` | **ersetzen für die Syncschicht, erweitern für den lokalen Store** (siehe K1) | Migration bestehender iCloud-Aufnahmen, Reset, Merge |
| Wiedergabe | `Sources/iOS/Detail/AudioPlayerView.swift` | **neu** — `AVAudioPlayer` trägt keine exakten Segmentgrenzen; Now-Playing-/Remote-Command-Verdrahtung übernehmen | Grenzen, stale Callbacks, Wiedergaberaten |
| UI/Plattformen | `Sources/App/`, `Sources/iOS/`, `Sources/watchOS/`, `Sources/Keyboard/` | **erweitern** — Shells existieren; `ObservableObject` → `@Observable` migrieren | native 27er-Targets |
| Markdownexport | — | **neu** | Quellen, Versionsbezug, Geheimnisse |
| Tests | `Tests/` (22× XCTest) | **erweitern** — Swift Testing ergänzen, nicht bestehende XCTests wegwerfen | Testplan, Evaluations-Gate |
| Watch | `Sources/watchOS/`, `WatchAudioArchive.swift`, `PhoneSessionManager.swift` | **erweitern** — heute reiner Rekorder, kein Wissensclient | Offline-Pack, PCC-Weg |

---

## 6. Nachweisliste aus `audit/brainspeak-baseline.md`

| Prüfung | Status |
|---|---|
| Lokaler Checkout, Branch, Commit, uncommitted Änderungen | ⚠️ ZIP ohne `.git` — **Commit und Branch sind nicht belegbar**. Für T001 formal einen echten Checkout verwenden. |
| Lizenz und Drittanbieterabhängigkeiten | ✅ MIT. Einzige externe Abhängigkeit: `KeyboardShortcuts` (sindresorhus) ab 2.2.0 — nur im macOS-Target. |
| App-Targets, Deployment-/Swift-Versionen, Signing | ✅ §1 |
| Audioimport, Speech-Pipeline, AppleModel-Nutzung, PCC-Adapter | ✅ §2, §3 — **kein PCC-Adapter vorhanden** |
| Persistenz-, CloudKit-, Export-, Löschpfade | ✅ §2, K1; `RecordingDeletion.swift` vorhanden, Export fehlt |
| Tests, Buildbefehle, CI, Migrationsbedarf | ⚠️ Tests und Buildbefehle erfasst; **keine CI-Konfiguration im Repository**; Migrationsbedarf siehe K1 |
| Funktionen dem Soll zugeordnet | ✅ §5 |
| Bestandsdaten durch Migrationstests abgesichert | ❌ offen — hängt an K1 und der Entscheidung D8 |

**Nicht geprüft und weiterhin offen:** Xcode-27-Build, Ausführung auf echter Hardware, PCC-Anfrage, Leistungs- und
Energiemessung. Diese Umgebung besitzt keine Apple-SDKs — GATE-SDK bleibt unverändert offen.
