# Umsetzungsplan (Planungsstand vor dem Bau)

Die App ist gebaut und liegt unter `app/`. Was sie heute kann, steht im [README](../README.md). Dieser Ordner bewahrt die ursprüngliche Planung.

Dieser Ordner enthält den **Plan für das Gesamtkonzept** „BrainSpeak — der AI-First Knowledge Podcast Player“.
Er ist die Schicht **über** dem eingecheckten Spec-Kit-Paket v1.3: Das Paket sagt *was* gebaut wird
(144 Anforderungen, 20 Nutzerabläufe, 266 Aufgaben), dieser Plan sagt *in welcher Reihenfolge, gegen welche
Nachweise und mit welchen offenen Entscheidungen*.

| Dokument | Inhalt |
|---|---|
| [01-umsetzungsplan.md](01-umsetzungsplan.md) | Rückgrat, parallele Tracks, Meilensteine M0–M9, Release-Züge, Gates, Aufwandsszenario |
| [02-konzept-abdeckung.md](02-konzept-abdeckung.md) | Konzeptkapitel 1–20 → US/FR/Tasks; drei echte Lücken mit Vorschlag FR-145–147 |
| [03-risiken-und-entscheidungen.md](03-risiken-und-entscheidungen.md) | Top-Risiken mit Gegenmaßnahme, die Entscheidungen, die vor M1 fallen müssen |
| [04-brainspeak-audit.md](04-brainspeak-audit.md) | **Ist-Audit des echten BrainSpeak-Checkouts** (2026-09-20): was wiederverwendbar ist, was Neubau ist, zwei Architekturkonflikte |

## Nach dem Ist-Audit: die wichtigste Erkenntnis zuerst

> **BrainSpeak ist kein Podcast-Player — aber auch kein bloßes Diktiergerät.** Es nimmt Audio auf, transkribiert
> on-device und zieht daraus **persona-gefilterte Fakten**, idempotent und wiederaufnehmbar.
> Die **Verstehens-Hälfte** des Konzepts (§2, §3) ist damit im Kern vorhanden; **Quellen, Mediathek, Zeitachse und
> segmentgenaue Wiedergabe** (§1, §4–§8) sind Neubau — null Zeilen Podcast-Domäne.
>
> Die Naht dazwischen ist die eigentliche Arbeit: die vorhandene Extraktion liefert **Markdown-Prosa ohne
> Herkunft**, und das Transkript trägt **keine Medienzeit**. M3/M4 heißt deshalb „Herkunftsbindung nachrüsten“,
> nicht „Extraktion bauen“.
> Details und Konsequenzen: [04-brainspeak-audit.md](04-brainspeak-audit.md).

## Der Plan in fünf Sätzen

1. Vor jedem Code entscheiden zwei Nachweise und zwei Konflikte über den Rest: Xcode-27-Toolchain, PCC-Berechtigung,
   Plattformversionen 26 gegen 27 und die Syncarchitektur (**M0**).
2. Danach wächst ein einziger vertikaler Pfad vom Abo bis zur Fokuswiedergabe — jede Stufe endet auf echter Hardware (**M1–M6**).
3. Die **Smart Podcast List** wird gegenüber der Task-Nummerierung des Pakets nach vorn gezogen: sie ist das stärkste
   Produktmerkmal und hängt abhängigkeitstechnisch an nichts, was nach ihr käme (**M7**).
4. Plattformen, YouTube-Historie, Wissensexport, Mixer und Breadcrumb laufen danach als parallele Tracks (**M8–M9**).
5. Erst am Ende steht der große Release-Gate-Block — aber jede Stufe davor hat bereits ihren eigenen Gerätenachweis.
