# Research & decisions — 19. September 2026

Primärquellen mit kurzen Befunden: `references/sources.md`. Dokumentierte Eigenschaften sind keine eigenen Benchmarks. Gates werden in `tasks.md` geschlossen.

| Entscheidung | Rationale | Verworfen / Abgrenzung | Evidence |
|---|---|---|---|
| Xcode 27, Swift 6.4, Deploymentminimum 27.0 | Nutzervorgabe latest native ohne alte OS-Pfade | Swift 5, iOS 26-Kompatibilitätsarchitektur | A01, A02 |
| aktuelle SwiftUI-Paradigmen | State-Migration, ContentBuilder, native Container | Nachzeichnen von Systemchrome, eigener Crossplatform-Renderer | A03, A04, A24 |
| Apple-Modelle statt offener Providerwahl | harte Produktvorgabe | Framework-Providerabstraktion ist kein Auftrag für Claude/Gemini/MLX | A05–A09 |
| Watch-PCC zulassen, lokale Inferenz nicht annehmen | 27er-Watch-Unterstützung dokumentiert | „Watch kann grundsätzlich keine KI“ und erfundenes lokales Watch-LLM gleichermaßen falsch | A06, A21 |
| SpotlightSearchTool für Vollclients | nativer Such-/RAG-Weg | externer Vektordienst; ungeschütztes Tool mit gesamtem Scope | A10 |
| SpeechAnalyzer für Langform-Dateien | Audio unabhängig von Playback analysieren | stiller Rückfall auf Dritt-ASR oder Mikrofonmitschnitt | A11 |
| SwiftData lokal + expliziter Sync | Konflikt-/Löschlogik beherrschbar | zwei Synchronisationsbesitzer derselben Records | A12–A14 |
| Background-Gates statt Daemon-Versprechen | iOS entscheidet Scheduling, Ressourcen und Fortsetzung | Audio-Background als Dauer-KI-Trick | A15, A16 |
| Originalclip-Pläne statt Audio-Mashup | Belege, Rechte, Wiederaufnahme erhalten | neue zusammengeschnittene Mediendatei als Default | A17 + Produktentscheidung |
| Evaluations plus deterministische Tests | KI ist probabilistisch, Rechte/Grants sind nicht verhandelbar | LLM-Judge als alleinige Freigabe | A19, A20 |
| YouTube-Quellfähigkeiten explizit | Atom ist kein Audio-Enclosure | universal downloader / caption scraping | Y01–Y03 |
| BrainSpeak zuerst auditieren | Hauptbasis bleibt Vorgabe trotz 404 | stilles Greenfield-Replacement | G05 |

## GATE-BS — Existing code
Erwarteter Nachweis: tatsächlicher Commit, Targets, Architektur, Lizenzen, vorhandene Tests, Persistenzschema, Audio-Owner, Speech-/Foundation-Models-Zugriff, bekannter Schuldstand. Ausgabe `audit/brainspeak-baseline.md`. Erst danach werden Zielpfade auf echte Dateien gemappt.

## GATE-SDK — Compile truth
Auf Mac: xcodebuild -version, xcrun swift --version, xcodebuild -showsdks und pro Plattform xcrun --sdk ... --show-sdk-version. Typecheck für Foundation Models/PCC, SpotlightSearchTool, neue SwiftData-Observer, App Intents, Background Inference und SwiftUI-Änderungen. Ausgaben unter `validation/apple-sdk/` speichern. Fehlende API ist ein dokumentierter Befund, nicht automatisch ein Anlass zur Verwendung alter Alternativframeworks.

## GATE-PCC — Konto und Laufzeit
Accountberechtigung/Entitlement, Signierung, echtes Gerät, regionale/Hardware-/Sprachverfügbarkeit und Kontingentstatus testen. Watch gesondert prüfen. Zugang für Unternehmen nicht voraussetzen. Kein Netzwerkfallback zu fremden Modellen. [A08]

## GATE-BG — lange Analyse
90-Minuten- und Drei-Stunden-Datei im Vordergrund und nach Wechsel in den Hintergrund. Low Power, gesperrtes Gerät, Thermik, fehlende Ressource, Assetdownload und OS-Kill. Teilresultate müssen überleben. Neural-Engine-Entitlement ist kein Beweis, dass jede Foundation-Models-/Speech-Operation beliebig im Hintergrund unterstützt ist. [A15, A16]

## GATE-YT — Wiedergabe und Einbettung
Test mit offizieller sichtbarer Playeroberfläche, Quellenverlinkung, Sperrung von Background/Audioextraktion und separat gelieferten Transkripten. WebKit-Integration ist native Apple-UI für einen eng umrissenen Videoinhalt, keine HTML-Shell der App. [A22, Y02]

## GATE-SYNC — Konflikte
Zwei Vollclients, Watch-Transfer, Offlinekonflikt, Reset-Epoch, iCloud-Abmeldung, Quota, Löschungen, doppelte Jobs, Medienfassung geändert. Verschiedene Datendomänen besitzen verschiedene Merge-Regeln; keine globale LastWriteWins-Abkürzung.

## GATE-DEVICE — echte vier Plattformen
Native App auf iPhone, iPad, Mac und Watch; Preview/Simulator reicht nicht für PCC, Audiointerruptionen, Hintergrundressourcen und Watch-Connectivity. Ergebnis jeweils executed/failed/blocked/not-run dokumentieren.

## Nachtrag 2026-09-20
Smart Podcast List ist eine Produktanforderung des Nutzers, keine Behauptung über bereits vorhandenen BrainSpeak-Code. Cover-Unterstützung wurde mit A27–A30 neu geprüft: Systemdialog ja, automatische ImageCreator-Erzeugung ab 27 nein. Details in `../../references/imageplayground-2026-09-20.md`.
