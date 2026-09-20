# ADR 0005 — YouTube ist keine Audio-Enclosure

Status: im Spec-Entwurf entschieden; SDK-/Integrationsnachweise sind offen. Datum: 19.09.2026.

## Kontext
Atom-Metadaten liefern nicht automatisch eine autorisierte Audiodatei oder ein fremdes Volltranskript.

## Entscheidung
Sichtbares offizielles Playback bzw. externes Öffnen. Inhaltsanalyse nur mit separat nutzbarer Audio-/Textquelle. Kein Scraping, kein Audiosplit, kein verdeckter Player.

## Konsequenzen
YouTube-Beiträge können metadataOnly sein. Native WebKit-Ansicht ist eine begrenzte Medienintegration, keine App-Webarchitektur. [Y01–Y03, A22]

Quellenkürzel: `references/sources.md`. Verifikation nicht mit Entwurfsentscheidung verwechseln.
