# ADR 0004 — LLM plant; Anwendung autorisiert und spielt

Status: im Spec-Entwurf entschieden; SDK-/Integrationsnachweise sind offen. Datum: 19.09.2026.

## Kontext
Freie generierte Zeiten und surprise autoplay sind unzuverlässig.

## Entscheidung
Vorschlag nur aus Evidence-IDs. Resolver erzeugt versionierten Plan. Gerät erzeugt auf bewusste Aktion einen lokalen, befristeten Grant mit Planhash; Player prüft bei Commit und Übergang.

## Konsequenzen
Grant wird nicht synchronisiert. Hintergrundvorschlag ist keine Autorisierung. Aktive Hörzeit und Originalmedienzeit bleiben getrennt. [A17]

Quellenkürzel: `references/sources.md`. Verifikation nicht mit Entwurfsentscheidung verwechseln.
