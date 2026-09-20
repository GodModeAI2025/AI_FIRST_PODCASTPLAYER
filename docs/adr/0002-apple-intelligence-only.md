# ADR 0002 — Apple Intelligence lokal und PCC

Status: im Spec-Entwurf entschieden; SDK-/Integrationsnachweise sind offen. Datum: 19.09.2026.

## Kontext
AppleModelRouter nutzt ausschließlich SystemLanguageModel und PrivateCloudComputeLanguageModel, sofern tatsächlich verfügbar und zugelassen.

## Entscheidung
Runtimeprüfung pro Anfrage, begrenzter Kontext, Quota-/Fehlerstatus und deterministische Ergebnisvalidierung. PCC ist weder Speicher noch freier externer HTTP-LLM-Endpunkt.

## Konsequenzen
Der allgemeine neue LanguageModel-Vertrag erlaubt Adapterarchitektur, aber keine Freigabe fremder Provider. Watch nutzt verifiziertes PCC, nicht behauptete lokale Inferenz. [A05–A09]

Quellenkürzel: `references/sources.md`. Verifikation nicht mit Entwurfsentscheidung verwechseln.
