# iPadOS 27 — Lesen, Quellen und Chat nebeneinander

Eigenes adaptives Layout im gemeinsamen Mobile-Target. Breite Fenster: Sidebar (Bereiche/Quellen), Content (Folge/Transkript/Erkenntnisse), optionaler Inspector (Chat/Belege/Fokus). Schmale Fenster: dieselben Daten in NavigationStack; keine abgeschnittenen dritten Spalten. Die Struktur folgt Fensterbreite, nicht ausschließlich Geräteklasse.

**Journey:** Zwei Folgen in der Mediathek auswählen → in den Vergleich ziehen → Frage im Inspector → Beleg im Transkript markieren → Fokusliste öffnen → abspielen. Quellumfang bleibt sichtbar, Auswahl wird nicht durch Inspectorwechsel verloren. Drag/Drop ergänzt dieselbe Aktion per Button/Tastatur.

Externe Tastatur: globale Suche, Play/Pause mit Fokuskonfliktbehandlung, zur nächsten Fundstelle, Export und neue Frage. Textcursor hat Vorrang vor Wiedergabe-Shortcuts. Pointerzustände und Kontextmenüs nutzen native Komponenten. Spaltenbreiten und Auswahl pro Fenster wiederherstellen.

Apple Pencil dient im Kernumfang der üblichen Systemeingabe/Selektion; keine nicht angeforderte Handschrift-/Zeichenpipeline. Native Textnotizen bleiben editierbar. Dokument-/Dateiimport über Files, sichere externe URLs und koordinierte Zugriffe.

Die Audioinstanz ist appweit einmal vorhanden, auch wenn mehrere Fenster offen sind. Chat bleibt fensterspezifisch; eine Hintergrundantwort darf nicht den Scope eines anderen Fensters ändern. In engem Layout wird die Scopeauswahl nicht hinter einem Icon versteckt.

**Abnahme:** Hoch-/Querformat, frei verkleinerte Fenster, Splitansicht, externe Tastatur und Pointer, VoiceOver, große Schrift, zwei Fenster mit konkurrierendem Play-Wunsch, Drag-Abbruch, Export nach Files. Keine Annahme, dass iPad immer die Leistung eines bestimmten Chips bietet.



## Widerspruchs-Mixer und Breadcrumb
US15/US16 ergaenzen den bestehenden Plattformflow. Gegenpositionen nutzen die vorhandene Fokusvorschau und den Originalplayer. Sessionabschluss ist ueberspringbar, nicht modal erzwungen. Native Bedienung und Quellenzugang bleiben erhalten; Graph immer auch als barrierefreie Liste. Watch bietet kompakte Entscheidungen und bestaetigte Transferzustaende, Vollclients den vollstaendigen Wissensgraph-/Exportflow. Details in `../breadcrumb-and-counterpoint.md`.

## Smart Podcast List (1.3)
Themenfeed, Ausgabenliste und Originalquelleninspector passen sich Fensterbreite an. Coverdialog mit bestätigtem Motiv; Apple-only-Stile. Keine neue Web-Shell und keine versteckte automatische Bildgenerierung.
