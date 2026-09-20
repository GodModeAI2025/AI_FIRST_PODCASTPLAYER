# ADR 0008 — BrainSpeak bleibt Hauptbasis; YourPods bleibt Referenz

Status: im Spec-Entwurf entschieden; SDK-/Integrationsnachweise sind offen. Datum: 19.09.2026.

## Kontext
BrainSpeak konnte in der Sitzung nicht gelesen werden; YourPods ist GPLv3.

## Entscheidung
Kein Ersatz-Fork, kein behauptetes Porting ohne Ist-Audit. Vorhandene BrainSpeak-Module zuerst inventarisieren. YourPods-Code nicht in dieses Paket übernehmen; Funktionalität unabhängig spezifizieren.

## Konsequenzen
Fehlende Repo-Berechtigung bleibt Integration-Gate. Direkte spätere Codeübernahme benötigt gesonderte Lizenzentscheidung. [G03–G05]

Quellenkürzel: `references/sources.md`. Verifikation nicht mit Entwurfsentscheidung verwechseln.
