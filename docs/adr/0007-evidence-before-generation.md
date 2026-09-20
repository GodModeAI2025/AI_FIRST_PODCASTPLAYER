# ADR 0007 — Evidenz und Medienrevision sind Primärdaten

Status: im Spec-Entwurf entschieden; SDK-/Integrationsnachweise sind offen. Datum: 19.09.2026.

## Kontext
Dynamische Werbung, umgeschnittene Videos und unzeitgestempelte Transkripte können Zeitbelege verfälschen.

## Entscheidung
Unveränderliche Episode/MediaVersion/TranscriptRevision/Segment-Referenzen. Verifizierte Ausrichtung ist Voraussetzung für abspielbare Evidenz. Retrievalindex und Zusammenfassungen sind abgeleitete, erneuerbare Daten.

## Konsequenzen
Mehr Metadaten und Invalidierungsregeln; kein erfundener Ersatzzeitcode. App sichert Belegtreue, nicht automatisch Wahrheit aller Aussagen. [A10, A11, G03]

Quellenkürzel: `references/sources.md`. Verifikation nicht mit Entwurfsentscheidung verwechseln.
