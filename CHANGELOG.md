# Änderungsverlauf

## App 0.2 · 2026-09-22
Aus dem ersten TestFlight-Feedback:
- Direkte Audio-Links, etwa MP3-Downloads von Podigee, werden als Einzelfolge angelegt und lassen sich erschliessen. Vorher suchte die App darin nach einem Feed und brach an der 12-MB-Grenze ab.
- Liegt unter einer Feed-Adresse kein Feed, sucht die App auf der Seite und auf der Startseite nach dem verlinkten Feed. `think-ai.podigee.io/rssfeed` führt so zu `/feed/mp3`.
- Zu YouTube-Kanälen sucht die App im Apple-Podcast-Verzeichnis nach dem Audio-Podcast desselben Anbieters und bietet das Abo an. Dessen Folgen lassen sich transkribieren. Das Audio der YouTube-Videos selbst lädt die App weiterhin nicht.
- Themen lassen sich direkt beim Anlegen eines Themen-Updates erstellen. „Für dich“ führt ohne Umweg zu den Interessen.

## App 0.1 · 2026-09-22
- iOS- und macOS-App bauen mit Xcode 27 und starten ohne Absturz.
- Erschliessen einer Folge funktioniert Ende zu Ende: Download, Transkription in der Feedsprache, Belege mit Zeitmarken.
- App-Icon, Privacy-Manifest und Signierung für TestFlight im Team Mobile Box.
- UI-Test für den Hauptweg und Ende-zu-Ende-Test für die Transkription.
- Behobene Fehler stehen in [app/STATUS.md](app/STATUS.md).

## Spezifikation 1.3 · 2026-09-20
- Smart Podcast List mit persistenten Themenfeeds, neuen persönlichen Folgen und unveränderlichen Originalsegment-Manifests ergänzt.
- Episodenfokus, globale Intervallhistorie, Alles-Ungehörte-/Budgetmodus und doppelte Zeitachsen verbunden.
- Eigene Titel, belegte Shownotes, nativer automatischer Cover-Fallback und Image-Playground-Systemdialog spezifiziert; ImageCreator ab 27 ausdrücklich ausgeschlossen.
- FR-121–144, US17–20, T219–266, Datenverträge, synthetische Beispiele, Traceability, Testregeln, Plattformzustände und Agentenauftrag ergänzt.
- Originalbilder und bisherige Spezifikation erhalten. Keine gebaute App und keine neu gerenderten Screens behauptet.

## Spezifikation 1.2 · 2026-09-19
Widerspruchs-Mixer und Breadcrumb-Trail durchgaengig aufgenommen; korrigierbare bestaetigte Thesen, faire Gegenpositionen, Sessiongrenzen, Quellenzaehlung, Wissensgraph und portabler Parkexport. Spezifikation jetzt 120 FR, 16 US, 218 Tasks. Releasebuild-/Konvergenzabhaengigkeiten nach allen Nutzerergaenzungen ausgerichtet. Quellen 1–4 im Testkorpus synthetisch, miteinander konsistent.

## Spezifikation 1.1 · 2026-09-19
YouTube-URL → Kanal → Feed automatisch; Abo/Einzelimport und rueckwirkende Kataloganalyse; Highlights, semantische Suche, Transkriptexport, reversible Pipeline, Smart Skip und macOS-MCP.

## Spezifikation 1.0 · 2026-09-19
Native 27er-Vorgabe, BrainSpeak-first, Timecode-Fokus, quellengebundener Chat, vier Plattformen, Originalscreens und urspruengliches Konzept archiviert.
