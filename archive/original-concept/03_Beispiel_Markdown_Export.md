---
schema_version: "1.0"
artifact_type: "episode_knowledge_note"
example_only: true
episode_id: "example-episode-001"
title: "Beispiel für einen Wissensexport"
source_type: "podcast_rss"
source_url: "https://example.org/podcast/folge-001"
published_at: "2026-09-01"
analyzed_at: "2026-09-19"
analysis_basis: "audio_transcription"
analysis_coverage: "complete"
transcript_origin: "apple_speech"
model_route: "on_device_then_pcc"
media_version_id: "example-media-version-001"
tags: [podcast, wissen]
---

# Beispiel für einen Wissensexport

> Dieses Dokument zeigt ausschließlich das vorgeschlagene Exportformat. Es enthält keine tatsächlich analysierte Podcastfolge. IDs, Datum, Quellenadresse, Modellroute und Zeitmarken sind Beispieldaten. Auch die Kennzeichnung „complete“ demonstriert nur das Schema.

## Kurzfassung

Hier steht eine verdichtete Zusammenfassung der tatsächlich verarbeiteten Inhalte. Titel und Shownotes allein reichen als Grundlage für eine inhaltliche Zusammenfassung nicht aus.

## Persönliche Relevanz

Hier kann eine vom Nutzer für diesen Export freigegebene Relevanzbegründung stehen. Das vollständige Interessenprofil wird nicht exportiert.

## Erkenntnisse

### Erkenntnis 1

Hier steht die paraphrasierte Aussage aus der Folge.

**Beleg:** Folge 001, 18:40–19:25, Segment `example-segment-001`.  
**Quellenadresse:** `https://example.org/podcast/folge-001`  
**Einordnung:** Aussage der Quelle; keine unabhängige Faktenprüfung.  
**Zeitbezug:** Bezogen auf die Medienfassung `example-media-version-001`.

### Eigene Ableitung

Hier steht eine ausdrücklich als Interpretation gekennzeichnete Schlussfolgerung aus der zuvor belegten Aussage.

## Kapitel

| Beginn | Titel | Herkunft |
|---|---|---|
| 00:00 | Beispielkapitel | Herausgeber |
| 18:40 | Beispiel für ein zusätzliches Themenkapitel | KI-erzeugt |

## Eigene Notizen

Hier stehen ausschließlich Notizen des Nutzers. Dieser Bereich darf bei einem späteren Export nicht ungefragt überschrieben werden.

## Offene Fragen

Hier stehen Fragen, die die ausgewertete Quelle nicht beantwortet oder für die die Analyse keine hinreichenden Belege gefunden hat.

## Verarbeitungsgrundlage und Grenzen

Der echte Export nennt Quellenumfang, Abdeckung, Transkript-/Medienfassung und relevante Unsicherheiten. Ein Mehrfolgen-Export dokumentiert zusätzlich, welche Folgen ausgewählt und welche tatsächlich analysiert waren.

## Quellen

- Folge: `https://example.org/podcast/folge-001`
- Beleg: Segment `example-segment-001`, 18:40–19:25

Private Feed-Zugangstoken, vollständige fremde Transkripte und Audio-Dateien sind nicht Bestandteil dieses Standardformats.
