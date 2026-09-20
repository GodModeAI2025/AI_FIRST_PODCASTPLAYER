# ADR 0006 — Watch als fokussierter Wissens- und Hörclient

Status: im Spec-Entwurf entschieden; SDK-/Integrationsnachweise sind offen. Datum: 19.09.2026.

## Kontext
Ein Telefonlayout und ein kompletter lokaler Bibliotheksindex passen nicht zur Watch-Aufgabe.

## Entscheidung
Watch erhält geprüfte Evidence-Packs, Focus-Pläne und erlaubte Offline-Audioassets. Kurze Fragen über PCC bei Verfügbarkeit; größere Aufgaben/Handoff nachvollziehbar über Companion.

## Konsequenzen
WatchConnectivity ist iPhone/Watch, nicht generischer Mac-RPC. Jeder Transfer und Export hat Ack/Pending/Error. Keine Dauersprachanalyse auf Watch vorgesehen. [A06, A21, A23]

Quellenkürzel: `references/sources.md`. Verifikation nicht mit Entwurfsentscheidung verwechseln.
