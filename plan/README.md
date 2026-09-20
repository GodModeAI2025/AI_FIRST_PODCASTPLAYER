# Umsetzungsplan BrainSpeak — Einstieg

Dieser Ordner enthält den **Plan für das Gesamtkonzept** „BrainSpeak — der AI-First Knowledge Podcast Player“.
Er ist die Schicht **über** dem eingecheckten Spec-Kit-Paket v1.3: Das Paket sagt *was* gebaut wird
(144 Anforderungen, 20 Nutzerabläufe, 266 Aufgaben), dieser Plan sagt *in welcher Reihenfolge, gegen welche
Nachweise und mit welchen offenen Entscheidungen*.

| Dokument | Inhalt |
|---|---|
| [01-umsetzungsplan.md](01-umsetzungsplan.md) | Rückgrat, parallele Tracks, Meilensteine M0–M9, Release-Züge, Gates, Aufwandsszenario |
| [02-konzept-abdeckung.md](02-konzept-abdeckung.md) | Konzeptkapitel 1–20 → US/FR/Tasks; drei echte Lücken mit Vorschlag FR-145–147 |
| [03-risiken-und-entscheidungen.md](03-risiken-und-entscheidungen.md) | Top-Risiken mit Gegenmaßnahme, sechs Entscheidungen, die vor M1 fallen müssen |

## Der Plan in fünf Sätzen

1. Vor jedem Code entscheiden drei Nachweise über den Rest: BrainSpeak-Checkout, Xcode-27-Toolchain, PCC-Berechtigung (**M0**).
2. Danach wächst ein einziger vertikaler Pfad vom Abo bis zur Fokuswiedergabe — jede Stufe endet auf echter Hardware (**M1–M6**).
3. Die **Smart Podcast List** wird gegenüber der Task-Nummerierung des Pakets nach vorn gezogen: sie ist das stärkste
   Produktmerkmal und hängt abhängigkeitstechnisch an nichts, was nach ihr käme (**M7**).
4. Plattformen, YouTube-Historie, Wissensexport, Mixer und Breadcrumb laufen danach als parallele Tracks (**M8–M9**).
5. Erst am Ende steht der große Release-Gate-Block — aber jede Stufe davor hat bereits ihren eigenen Gerätenachweis.

## Warum der Plan neben dem Paket liegt

Das Spec-Kit-Paket ist über `PACKAGE_MANIFEST.json` und `SHA256SUMS` hashgesichert; `scripts/validate_packet.py`
prüft jede Datei gegen ihren Hash. Dieser Plan ist deshalb **rein additiv** — keine Paketdatei wurde verändert,
auch nicht die `README.md`. Das Paket validiert unverändert:

```
$ python3 scripts/validate_packet.py
{"status": "passed", "inventory": "passed", "requirements": 144, "stories": 20, "tasks": 266, ...}
$ python3 -m unittest discover -s tests -p 'test_*.py'
Ran 95 tests ... OK
```

Anforderungsänderungen (etwa die vorgeschlagenen FR-145–147) gehören nicht in diesen Ordner, sondern über das
Änderungsverfahren der Constitution in `specs/` — mit neu erzeugtem Manifest.

## Stand und Ehrlichkeit

Nichts in diesem Repository ist gebaute App. Das Spec-Kit-Paket validiert als Dokumentpaket
(`python3 scripts/validate_packet.py` → `status: passed`), das beweist **keinen** Xcode-Build, **keinen** Gerätetest
und **keine** Modellinferenz. Alle 266 Aufgaben stehen auf `not_started`.
