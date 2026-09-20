# Sonar / BrainSpeak — AI-First Audio, Apple 27

**Vollstaendiges Spezifikationspaket, Version 1.3 · Stand 20. September 2026.**
Arbeitsname Sonar; Hauptbasis BrainSpeak. Native Umsetzung ausschliesslich fuer **iOS 27, iPadOS 27, watchOS 27 und macOS 27**. Dieses Archiv ist ein ausgefuelltes Spec-Kit-Arbeitspaket, nicht die fertige Anwendung.

> Audio verstehen, relevante Originalstellen hoeren und daraus einen selbst kuratierten Wissenspfad machen.

## Einstieg
Lies [START_HERE.md](START_HERE.md). Uebergib dem Coding-Agenten danach [prompts/00_START_IMPLEMENTATION.md](prompts/00_START_IMPLEMENTATION.md) zusammen mit dem vorhandenen BrainSpeak-Checkout. Repositoryzugriff war 404; dessen Code wird nicht erfunden oder als enthalten bezeichnet.

## Inhalt
| Bereich | Dateien |
|---|---|
| Prinzipien | [.specify/memory/constitution.md](.specify/memory/constitution.md) |
| Produkt und Abnahme | [spec.md](specs/001-ai-podcast-player/spec.md), requirements.json, stories.json, acceptance-cases.json |
| Native Umsetzung | [plan.md](specs/001-ai-podcast-player/plan.md), data-model.md, research.md, quickstart.md |
| Arbeitsauftraege | [tasks.md](specs/001-ai-podcast-player/tasks.md), tasks.json, traceability.csv/json |
| Detailfunktionen | Fokusplayer, YouTube-Discovery/Archiv, Wissen/Highlights, MCP, Sync, Sicherheit, Widerspruchs-Mixer, Breadcrumb-Trail, Smart Podcast List |
| UI | Originalbild, zehn unveraenderte Ausschnitte, [Offlinegalerie](design/gallery.html), acht Mermaid-Flows, vier Plattformbeschreibungen |
| Schnittstellen | JSON-Schemas, Swift-Domaincontracts und MCP-Tooldefinitionen |
| Beispieldaten | Vier ausschliesslich synthetische Quellen mit Belegen; Fokusplan, Highlights, Graph und [Markdown-Wissenslandkarte](fixtures/export/trail/README.md) |
| Pruefung | Python-Paketpruefung, Invariantentests, Apple-SDK-Probes; reale App-/Geraetenachweise noch offen |
| Nachweise und Historie | Quellenregister, ADRs, Nutzervorgaben, urspruengliches Konzept und Original-ZIP |

**144 Anforderungen · 20 Nutzerablaeufe · 266 verknuepfte Umsetzungsschritte.** Alle Produkttasks sind offen. Die mitgelieferten Tests pruefen nur Daten-, Contract- und Paketkonsistenz und duerfen nicht als fertiger Player/LLM-/Geraetetest verstanden werden.

## Funktionsumfang
RSS und Einzelimporte; YouTube-Link mit automatischer Kanal-/Feed-Erkennung und historischem Katalog; getrennte Hoer-/Analysequeues; Apple-Sprachanalyse; AI-Kapitel; belegter Einzel-/Mehrfolgenchat; semantische Suche; Timecode-Fokus aus Chat und Interessen; Highlights; optional Smart Skip; Markdown/SRT/VTT/TXT/JSON; kontrollierter macOS-MCP-Zugriff; Sync; native vier Plattformen.

**Widerspruchs-Mixer:** freiwillig eine These an fairen belegten Gegenpositionen pruefen. Gespeichert oder gehoert bedeutet nicht zugestimmt. **Breadcrumb-Trail:** jede bewusst abgeschlossene Session bietet Vertiefen, Parken oder Verwerfen. Parken baut einen portablen Wissensgraphen, Verwerfen erhaelt Originalwissen, Vertiefen startet keinen endlosen Audioloop.

## Architekturentscheidungen
SwiftUI/Observation, Structured Concurrency/Actors, SwiftData, expliziter CloudKit-Sync, AVFoundation, SpeechAnalyzer, Foundation Models/PCC, Core Spotlight, App Intents und Swift Testing/Apple Evaluations sind die vorgesehenen nativen Bausteine. Release- und Beta-SDK-Kanaele bleiben getrennt. Die recherchierten Details und Grenzen stehen in [references/sources.md](references/sources.md) und den SDK-Probes. Kein Electron, Catalyst, Flutter, fremder LLM-Provider, Whisper-/MLX-Fallback oder Drittcodec-Runtime.

## Ehrliche Grenzen
PCC braucht Berechtigung des konkreten Entwicklerkontos. YouTube-Metadaten/Abos sind kein allgemeiner Zugriff auf fremde Audiospuren oder Captions. Hintergrundanalyse erfolgt unter OS-Ressourcenregeln. Die Watch bekommt keine erfundene lokale LLM-/Langform-ASR-Faehigkeit. Das Konzeptbild ist kein Screenshot einer laufenden App. Neue Mixer-/Breadcrumb-Oberflaechen sind als Wireflows beschrieben, nicht als fertig gerenderte Plattformmockups ausgegeben.

## Lokale Pruefung
```bash
python3 scripts/validate_packet.py
python3 -m unittest discover -s tests -p 'test_*.py'
```
Der Validator benoetigt fuer die verwendeten Schemas nur Python-Standardbibliothek; ist `jsonschema` installiert, prueft er zusaetzlich mit Draft202012Validator. Diese Entwicklungspruefungen sind keine Laufzeitabhaengigkeit der Swift-App. Apple-Probes laufen ausschliesslich auf einem Mac mit Xcode 27:
```bash
bash scripts/probe-apple-sdk.sh
```

Fuer unabhaengige Integritaetspruefung dienen PACKAGE_MANIFEST.json und SHA256SUMS. Gespeicherte Validierungsergebnisse stehen unter `validation/`. Schriftdateien, Apple-SDKs, Zugangsdaten und nicht zugaenglicher fremder Quellcode sind nicht enthalten.

## Neu in 1.3 — Smart Podcast List
[Erweiterung lesen](ERWEITERUNG_SMART_PODCAST_LIST.md). Persönliche Themenfeeds erhalten neue Folgen aus ungehörten Originalsegmenten, eigene Shownotes und Cover. Episodenfokus und feedübergreifende segmentgenaue Hörhistorie sind integriert. Image-Playground-Cover entstehen über den bestätigten Systemdialog; automatische native Layoutcover halten neue Folgen sofort nutzbar. Technische Details: [Smart-Podcast-Spezifikation](specs/001-ai-podcast-player/smart-podcast-list.md).
