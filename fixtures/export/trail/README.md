---
schema_version: 1
synthetic: true
trail_id: "graph-demo"
session_id: "session-demo"
curation: "preview"
---
# Welche Betriebsform passt zu meinem Testprojekt?

**Synthetischer Exportentwurf, kein realer Podcast und keine Aussage ueber den Nutzer.**
Vier im Testkorpus vorhandene Quellen werden als Perspektiven auf eine Frage zusammengefuehrt. Aufbewahren ist keine Zustimmung und kein Wahrheitsbeweis.

## Erkenntnisse und Quellen
| Perspektive | Kernaussage | Beleg |
|---|---|---|
| Lokaler Betrieb | Anfragen koennen ohne externen Modellanbieter laufen. | episode-1 / ev-1-0 / media-1 / 00:10–00:26 |
| Verwalteter Dienst | Eigener Betriebsaufwand kann sinken; Netzzugang und Freigabe sind Voraussetzungen. | episode-2 / ev-2-0 bis ev-2-2 / media-2 / 00:10–01:06 |
| Offline-Anforderungen | Ein verlaesslicher lokaler Pfad ist fuer Arbeiten ohne Netz erforderlich. | episode-3 / ev-3-0 / media-3 / 00:10–00:26 |
| Hybrid | Lokale Grundfunktionen koennen mit verwalteten Zusatzfunktionen kombiniert werden. | episode-4 / ev-4-0 / media-4 / 00:10–00:26 |

## Beziehung und offene Frage
„Verwalteter Dienst“ **qualifiziert** die Betrachtung des lokalen Betriebs unter anderen Voraussetzungen; es ist kein direkter Beweis gegen Offlinefaehigkeit. Diese Relation ist ein zu pruefender Modellvorschlag.

**Offene Frage:** Welche Ausfall-, Betriebs- und Datenanforderungen sind fuer das konkrete Projekt entscheidend?

Die maschinenlesbare Landkarte steht in [graph.json](graph.json), ihre textbasierte Visualisierung in [map.mmd](map.mmd). Echte Medien und funktionierende externe Timecode-Links sind in diesem Testpaket nicht enthalten; die Zeiten testen ausschliesslich die Referenzstruktur.
