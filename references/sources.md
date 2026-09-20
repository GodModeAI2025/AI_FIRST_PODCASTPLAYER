# Quellenregister

Stand: 19. September 2026. Kurze eigene Befunde, keine vollständige Offlinekopie externer Dokumentation. Entwurfsentscheidungen sind keine Herstellerzusagen. SDK-Signaturen und Berechtigungen werden auf dem realen Mac geprüft.

## A01 — Xcode SDKs and system requirements
`https://developer.apple.com/xcode/system-requirements`

Xcode 27 mit Swift-6.4-Compiler und 27er-SDKs; die Tabelle listet auch 27.x-Betas. Release-Baseline und experimentelle SDK-Lane werden getrennt.

## A02 — Swift 6.4 Released — 15 September 2026
`https://www.swift.org/blog/swift-6.4-released/`

Swift 6.4 ist veröffentlicht. Compiler-Version und Swift-Sprachmodus sind getrennte Einstellungen.

## A03 — TN3211: SwiftUI State and ContentBuilder
`https://developer.apple.com/documentation/technotes/tn3211-resolving-swiftui-source-incompatibilities-for-state-and-contentbuilder`

Xcode 27 verändert State zur Makroform und vereinheitlicht Result Builder mit ContentBuilder. Migrationsprüfung für bestehendes BrainSpeak ist erforderlich.

## A04 — SwiftUI updates, June 2026
`https://developer.apple.com/it/documentation/updates/swiftui`

Die aktuelle Übersicht beschreibt unter anderem Reordering, ToolbarOverflowMenu und URL-basierte Dokumentprotokolle. Konkrete Signaturen im installierten SDK prüfen.

## A05 — Foundation Models updates
`https://developer.apple.com/documentation/Updates/FoundationModels`

27er-Generation: DynamicProfile, LanguageModel-Abstraktion und differenzierte Fehlertypen. Der lokale Apple-Modellstand ändert sich mit dem Betriebssystem.

## A06 — What’s new in Foundation Models — WWDC26
`https://developer.apple.com/videos/play/wwdc2026/241/`

PCC erweitert Foundation Models auf watchOS 27. Das belegt keinen lokalen SystemLanguageModel auf der Watch. Framework unterstützt Systemtools und dynamische Profile.

## A07 — PCC integration guide
`https://developer.apple.com/documentation/FoundationModels/adding-server-side-intelligence-with-private-cloud-compute/`

PrivateCloudComputeLanguageModel: dokumentiertes 32K-Kontextfenster, Reasoning-Konfiguration und tägliches Nutzerkontingent. Netz- und Quotenstatus sind Produktzustände.

## A08 — Private Cloud Compute eligibility
`https://developer.apple.com/private-cloud-compute/`

Entwicklerberechtigung umfasst Small Business Program, weniger als zwei Millionen Erstdownloads über die Apps und ein zugewiesenes Entitlement. Das konkrete Konto wurde nicht geprüft.

## A09 — Build with PCC — WWDC26
`https://developer.apple.com/videos/play/wwdc2026/319/`

PCC bietet Apple-seitige Serverinferenz. Verfügbarkeit, Kontext und Ressourcen sind im Integrationsspike auf realer Hardware nachzuweisen.

## A10 — LLM search using Core Spotlight — WWDC26
`https://developer.apple.com/videos/play/wwdc2026/246/`

SpotlightSearchTool erschließt den eigenen App-Index auf iOS, iPadOS, macOS und visionOS. watchOS wird in dieser Verfügbarkeit nicht genannt.

## A11 — SpeechAnalyzer — WWDC25, still current architecture
`https://developer.apple.com/videos/play/wwdc2025/277/`

SpeechAnalyzer mit SpeechTranscriber verarbeitet längere Audioaufnahmen lokal. Finalisierte Textläufe besitzen Audiozeitbereiche. Sprachassets und Audioformat werden separat verwaltet.

## A12 — SwiftData updates
`https://developer.apple.com/documentation/updates/swiftdata`

27er-Änderungen umfassen sectionBy, Codable-Attribute, ResultsObserver und HistoryObserver. Die Verfügbarkeit wird im SDK-Spike bestätigt.

## A13 — CKSyncEngine
`https://developer.apple.com/documentation/CloudKit/CKSyncEngine-5sie5`

CloudKit-Synchronisierung von lokalen und entfernten Records. App stellt Records und Konfliktlogik bereit; Scheduling hängt von Systembedingungen ab.

## A14 — CKSyncEngine state serialization
`https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/stateupdate/stateserialization`

Aktuellste Engine-State-Serialization muss persistent neben den App-Daten gespeichert und beim Start wiederhergestellt werden.

## A15 — Continued background processing
`https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados/`

BGContinuedProcessingTask ist für nutzerinitiierte, im Vordergrund gestartete Jobs vorgesehen. System kann Fortsetzung begrenzen; kein frei laufender Daemon.

## A16 — Background Neural Engine inference entitlement
`https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference?changes=_7&language=objc`

Aktuelle Dokumentation nennt Background Inference für Neural-Engine-Nutzung. Beta-Markierung/Signatur und Profilfreigabe lokal prüfen; Entitlement bedeutet keine Laufzeitgarantie.

## A17 — AVPlayerItem forwardPlaybackEndTime
`https://developer.apple.com/documentation/avfoundation/avplayeritem/forwardplaybackendtime`

Definiert das Ende der Vorwärtswiedergabe. Zusammen mit geprüftem Seek und zustandsbasierter Steuerung für Originalpassagen nutzbar.

## A18 — App Intents updates
`https://developer.apple.com/documentation/Updates/AppIntents`

27er-App-Intents ergänzen unter anderem SyncableEntity und OwnershipProvidingEntity. Stabile geräteübergreifende IDs und Bestätigung sensibler Aktionen berücksichtigen.

## A19 — Evaluations framework
`https://developer.apple.com/documentation/evaluations`

Swift-basiertes Framework für Datensätze, Metriken, Evaluatoren und Swift-Testing-Integration; eignet sich für probabilistische KI-Qualität.

## A20 — Tool-calling evaluations
`https://developer.apple.com/documentation/Evaluations/evaluating-tool-calling-behavior`

Werkzeugreihenfolge und Argumente lassen sich gegen erwartete Trajektorien evaluieren. Für prepare/commit-Wiedergabe gesondert prüfen.

## A21 — watchOS 27 overview
`https://developer.apple.com/watchos/whats-new/`

Apple nennt intelligente kompakte Erlebnisse mit Foundation Models auf watchOS 27. Watch erhält eine eigenständige, ressourcenbewusste Oberfläche.

## A22 — WebKit WebView for SwiftUI
`https://developer.apple.com/documentation/WebKit/WebView-swift.struct`

WebView mit WebPage ist eine native SwiftUI-Integration für Webinhalte. Einsatz nur als isolierter sichtbarer YouTube-Player, keine Web-App-Oberfläche.

## A23 — WatchConnectivity WCSession
`https://developer.apple.com/documentation/WatchConnectivity/WCSession`

Reachability gilt für unmittelbare Nachrichten; Hintergrunddaten und Dateien werden über eigene Transfermechanismen zugestellt. Übertragung ist nicht sofort garantiert.

## A24 — ContentBuilder
`https://developer.apple.com/documentation/swiftui/contentbuilder`

Einheitlicher SwiftUI-Builder für Views und weitere Content-Typen. Neue Bausteine daran ausrichten, ohne eigene DSL zu erfinden.

## Y01 — YouTube channel Atom feed
`https://developers.google.com/youtube/v3/guides/push_notifications`

Kanalaktualisierungen über Atom/WebSub. Ein Videohinweis ist kein Audio-Enclosure; Polling dient dem lokalen Client ohne Webhook-Backend.

## Y02 — YouTube API developer policies
`https://developers.google.com/youtube/terms/developer-policies`

Kein pauschales Extrahieren/Isolieren von Audio und kein versteckter Hintergrundplayer. Offizielle Wiedergabe bleibt quellenabhängig; keine Zugangskontrollen umgehen.

## Y03 — YouTube caption download
`https://developers.google.com/youtube/v3/docs/captions/download`

Die offizielle Caption-Download-Operation verlangt Bearbeitungsberechtigung am Video. Kein allgemeiner Transkriptzugang für fremde Videos.

## G01 — GitHub Spec Kit official project
`https://github.com/github/spec-kit`

Aktueller Ablauf: constitution, specify, plan, tasks, implement, converge. CLI und Agent-Skills sind getrennt; Integrationen können Punkt- oder Bindestrichsyntax verwenden.

## G02 — Spec Kit inspected commit
`https://github.com/github/spec-kit/commit/d4229c071c7ea3885b43e8a7739847300f618f13`

Am 19.09.2026 über GitHub gelesen; Commit vom 18.09.2026. Paket verwendet kompatible Strukturen und eigene projektspezifische Hilfen, nicht den vollständig vendorten CLI.

## G03 — YourPods functional reference
`https://github.com/asecretcompany/yourpods-source/blob/57ce7e26e60866c14d1ac8a9fa315f856b2f5c02/README.md`

Im vorherigen Rechercheteil gelesene Referenz für RSS, Kapitel, Transkripte, Notizen und Markdown. Keine Quellcodeübernahme und keine Build-Verifikation.

## G04 — YourPods license notice
`https://github.com/asecretcompany/yourpods-source/blob/57ce7e26e60866c14d1ac8a9fa315f856b2f5c02/NOTICE.md`

GPLv3 und gesonderte Drittanbieterhinweise. Integration ist vor Übernahme rechtlich und technisch freizugeben.

## G05 — BrainSpeak required source repository
`https://github.com/GodModeAI2025/BrainSpeak`

Erneuter autorisierter Repository-Abruf dieser Sitzung lieferte 404. Kein Commit, keine aktuelle Codebasis im Paket; Ursache unbekannt. BrainSpeak bleibt verbindliche Hauptbasis.

## Y04 — YouTube channels.list
`https://developers.google.com/youtube/v3/docs/channels/list`

forHandle/forUsername/id lösen Kanäle auf; contentDetails enthält Uploads-Playlistinformationen.

## Y05 — YouTube playlistItems.list
`https://developers.google.com/youtube/v3/docs/playlistItems/list`

Historische Uploads können über Playlistseiten und nextPageToken enumeriert werden; maxResults höchstens 50 pro Seite, kein Gesamtarchivlimit von 50.

## Y06 — YouTube videos.list
`https://developers.google.com/youtube/v3/docs/videos/list`

Video-Metadaten können aus IDs abgefragt werden; snippet liefert Kanalzuordnung.

## M01 — MCP Specification 2026-07-28
`https://modelcontextprotocol.io/specification/2026-07-28`

Aktuelles latest-Ziel beim Abruf am 19.09.2026. Keine alte connection-scoped Handshake-Semantik ungeprüft übernehmen.

## M02 — MCP transport bindings
`https://modelcontextprotocol.io/specification/2026-07-28/basic/transports`

UTF-8 JSON-RPC; stdio und Streamable HTTP; request-scoped Metadata im Body. Aktueller Protokollstand unterscheidet sich von älteren Session-Modellen.

## M03 — MCP tools
`https://modelcontextprotocol.io/specification/2026-07-28/server/tools`

Tools mit JSON-Schemas und strukturierten Ergebnissen; Berechtigung je Request und klare menschliche Kontrolle vorsehen.

## C01 — Snipd product website
`https://www.snipd.com/`

Herstellerbeschreibung für Snips/Highlights und Wissensnutzung. Inspiration, kein unabhängiger Benchmark und keine bestätigte Millionenzahl.

## C02 — Onda product website
`https://getonda.app/`

Hersteller beschreibt Notizen, Zusammenfassungen und Zitate aus Podcasts. Konzeptinspiration, nicht getestete Funktionsparität.

## C03 — Anycast product website
`https://anycast.website/`

Herstellerseite für KI-Podcastfunktionen. Kein verifizierter Vergleich von Latenz, Sprachqualität oder Archivgröße.

## A25 — Apple Translation framework
`https://developer.apple.com/documentation/translation`

Native Übersetzung als optionale Erweiterung; konkrete Plattform-/Sprachpaar-/Assetverfügbarkeit vor Nutzung prüfen.



## A26 — watchOS Group Lab / WWDC26
`https://developer.apple.com/videos/play/wwdc2026/8014/`

Am 19.09.2026 erneut gelesen: watchOS-Foundation-Models benoetigt Netz; es laeuft kein lokales Modell auf der Watch und es wird nicht automatisch das iPhone-Modell geborgt. PCC ist berechtigungsabhaengig. Vorbereitete lokale Ergebnisse und Offline-Audio bleiben eigene Funktionen.

## Revalidierung 19.09.2026
A01/A02: Apple fuehrt Xcode 27 mit Swift 6.4 sowie neuere 27.x-Betakanaele getrennt. A08: Accountberechtigung bleibt zwingend. A10: SpotlightSearchTool umfasst iOS/iPadOS/macOS, nicht den Watch-eigenen Index. Y05: Playlistpagination bestaetigt, kein Vollarchiv allein durch RSS. M02: aktueller MCP-Transportstand verwendet request-scoped Metadata. Diese Revalidierung ersetzt keine lokalen Compiler-/Entitlement-/Geraetetests.

## Nachtrag 2026-09-20 — Cover / Smart Podcast List

**A27 — Apple Image Playground Framework**
https://developer.apple.com/documentation/imageplayground

Unterstützte Integration via Systemdialog; UI-gesteuerte Bildauswahl ist von Hintergrundautomatik zu unterscheiden.

**A28 — Apple — Deprecation of the ImageCreator class (June 11, 2026)**
https://developer.apple.com/news/?id=dz9wvq0r

ImageCreator funktioniert ab iOS/iPadOS/macOS/visionOS 27 nicht mehr; auf unterstützten UI-Pfad migrieren.

**A29 — Apple — ImageCreator.init()**
https://developer.apple.com/documentation/imageplayground/imagecreator/init()

Initializer dokumentiert notSupported ab Version 27; kein tragfähiger Hintergrund-Covergenerator.

**A30 — Apple WWDC26 — Create high-quality images using Image Playground**
https://developer.apple.com/videos/play/wwdc2026/375/

Systemdialog, Apple-Stil-Allowlist ohne externalProvider, Verfügbarkeitswert, Bestätigung und Persistenz der temporären Ergebnisdatei; Vollclients, kein Watch-Bildgenerator.
