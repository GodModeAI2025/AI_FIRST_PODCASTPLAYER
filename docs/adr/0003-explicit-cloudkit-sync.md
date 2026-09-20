# ADR 0003 — SwiftData lokal, CKSyncEngine explizit

Status: im Spec-Entwurf entschieden; SDK-/Integrationsnachweise sind offen. Datum: 19.09.2026.

## Kontext
Fachliche Konflikt-/Löschregeln verlangen nachvollziehbare Synchronisation.

## Entscheidung
SwiftData bleibt lokale Persistenz. Ein eigener CKSyncEngine-Adapter synchronisiert ausgewählte Records in einer privaten CloudKit-Datenbank. Automatischer SwiftData-CloudKit-Sync ist für dieselben Modelle deaktiviert.

## Konsequenzen
Mehr Integrationsaufwand, dafür explizite Outbox/StateSerialisierung, Rewind-/Resetregeln und Datenminimierung. CloudKit ist eventual, kein Exactly-once-Jobbroker. [A12–A14]

Quellenkürzel: `references/sources.md`. Verifikation nicht mit Entwurfsentscheidung verwechseln.
