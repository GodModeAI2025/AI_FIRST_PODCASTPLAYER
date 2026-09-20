# ADR 0009 — Core Spotlight mit Fach-Scope

Status: im Spec-Entwurf entschieden; SDK-/Integrationsnachweise sind offen. Datum: 19.09.2026.

## Kontext
Neue Apple-Tools ermöglichen lokale Suche, erzwingen aber nicht automatisch unseren Nutzer-Scope.

## Entscheidung
Vollclients indexieren nur app-eigenen zulässigen Bestand; Tools erhalten begrenzte Suchkontexte, Ergebnisse und generierte Evidence-IDs werden nochmals fachlich geprüft. Watch nutzt nur explizite Packs.

## Konsequenzen
Index ist rebuildable und löschbar. Trefferanzahl ist keine Vollständigkeitsgarantie. Exhaustive queries benutzen einen Coverage-Lauf. [A10]

Quellenkürzel: `references/sources.md`. Verifikation nicht mit Entwurfsentscheidung verwechseln.
