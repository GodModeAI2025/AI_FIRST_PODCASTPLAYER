# ADR 0001 — Vier native Apple-27-Targets

Status: im Spec-Entwurf entschieden; SDK-/Integrationsnachweise sind offen. Datum: 19.09.2026.

## Kontext
Eine aktuelle gemeinsame Domain nutzt Swift 6.4 im Swift-6-Modus. SwiftUI-Shells reagieren auf Plattform und Fenstergröße. macOS ist ein natives Target, kein Catalyst.

## Entscheidung
Nur veröffentlichte 27er-SDK-APIs im Releasepfad; aktuelle Beta-Symbole hinter explizitem Gate und separater Prüflane. Xcode-Buildnummer wird bei Integration gelockt, nicht nur „latest“ angekreuzt.

## Konsequenzen
Kein 26er-Kompatibilitätsbaum; keine plattformfremde App-Runtime. Architektur bleibt testbar mit kleinen Apple-Adaptern. [A01–A04]

Quellenkürzel: `references/sources.md`. Verifikation nicht mit Entwurfsentscheidung verwechseln.
