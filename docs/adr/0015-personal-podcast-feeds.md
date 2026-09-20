# ADR 0015 — Persönliche Folgen als immutable Originalsegment-Manifeste
Datum: 2026-09-20 · Status: beschlossen für Spezifikation 1.3.

## Entscheidung
Smart Podcast Lists werden als private persistente Themenfeeds mit eigenen Ausgaben modelliert. Jede Ausgabe besitzt Titel, Shownotes, Cover und nachvollziehbare Originalsegmente. Technisch ist sie kein neu synthetisierter Podcast und keine implizit veröffentlichte RSS-Mediendatei. Der bestehende PlaybackCoordinator spielt das Segmentmanifest.

## Gründe
Der Nutzer möchte auf Play drücken und passende, noch nicht gehörte Originalausschnitte wie eine eigene Folge hören. Persistente Ausgaben erlauben Fortschritt, Shownotes, Quellenbelege, Originalsprung und geräteübergreifende Wiederaufnahme. Eine globale segmentgenaue Ledger verhindert Wiederholungen; Folge-Played-Bools allein reichen nicht.

## Konsequenzen
Separate Vollständigkeitsmodi; stabiler Batch-Key; Publikations-/Hörstatus getrennt; veröffentlichte Manifeste unveränderlich; Quellenzugang bleibt pro Medium geprüft. Wissen und Audio werden nicht aus generierten Shownotes erneut als Primärquelle aufgenommen. Kein automatischer Tonstart bei Publikation.
