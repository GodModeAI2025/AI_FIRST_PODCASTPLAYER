# ADR 0016 — Image Playground nur über den unterstützten Systemdialog
Datum: 2026-09-20 · Status: beschlossen für Spezifikation 1.3 · Quellen A27–A30.

## Entscheidung
Episodencover erhalten automatisch ein natives Titel-/Themenlayout. Optional lässt der Nutzer ein individuelles Bild im Image-Playground-Systemdialog erzeugen und bestätigt es. Ein zuvor freigegebenes Feedmotiv darf wiederverwendet werden. Keine Nutzung von ImageCreator, keine fremden Modelle, keine versteckte Automatisierung des Systemdialogs.

## Gründe
Apple hat ImageCreator ab den Plattformversionen 27 eingestellt. Unterstützt ist die UI-geführte Integration. Die App darf deshalb nicht versprechen, für jede neue persönliche Folge im Hintergrund automatisch ein neues Image-Playground-Bild zu generieren. Die Kernfunktion bleibt durch Layoutcover vollständig nutzbar.

## Konsequenzen
Covererzeugung und Episodenpublikation sind entkoppelt. Dateipersistenz, Verfügbarkeit, Apple-only-Stilwahl, temporäre Ergebnisdatei und Watch-Sync besitzen eigene Abnahmen. Image-Playground-Verfügbarkeit ist keine bloße Übernahme des PCC-Textentitlements.
