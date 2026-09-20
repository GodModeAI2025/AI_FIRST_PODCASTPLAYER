# macOS 27 — native Wissenswerkbank

Native macOS-App, ausdrücklich kein Catalyst und keine iPhone-Kompatibilitäts-App. WindowGroup für Bibliothek/Arbeit; zusätzlicher eigenständiger Vergleichs- oder Erkenntnisfensterzustand möglich. Sidebar, selektierbare Table/List, Content und Inspector sind mit Commands/Toolbar verbunden.

**Journey:** OPML oder Audiodateien aus Finder importieren → Auswahl in Analysequeue → parallel im anderen Fenster lesen → mehrere Folgen befragen → Quellen vergleichen → Markdown in gewählten Ordner exportieren. Fortschritt bleibt im Activity-Bereich sichtbar; das Schließen eines Fensters beendet nicht willkürlich die appweite Analyse.

Fensterzustand ist lokal, Wissen synchronisierbar. Ein zentraler Prozess-Player verhindert doppelte Wiedergabe. Menüeinträge für Quelle hinzufügen, Import, Export, neue Frage, Fokus starten/stoppen, Queue und Einstellungen. Standardshortcuts respektieren Texteingaben. Drag/Drop von Referenzen und Dateien, context menu und Dateidialoge verwenden native Mechanismen.

Mac kann große Archive abarbeiten, ist aber kein verpflichtender Master für iPhone/iPad. Appbeenden unterbricht Jobs mit Checkpoint. Kein automatisch installierter LaunchAgent, kein Rootservice, kein permanentes Keep-awake. Optionale spätere Login-Helfer wären eine neue ausdrückliche Entscheidung.

Dateizugriff bleibt sandboxed und nutzergewählt. Security-scoped Zugriffe/Bookmarks werden nur soweit nötig persistiert und nach Gebrauch freigegeben. App-Sandbox und ausgehendes Netzwerk passen zu Podcastdownloads, nicht pauschalem Zugriff auf Home-/Mail-/Fotos-Verzeichnisse.

**Abnahme:** zwei bis drei Fenster, Fenster schließen vs. App beenden, Sleep/Wake, Netzwerkwechsel, große Bibliothek, Finder-Import, fehlender früherer Exportordner, Tastatur-only, VoiceOver, Apple-Silicon-Gerät mit echter Modellverfügbarkeit. Latest macOS bedeutet nicht automatisch alle KI-Fähigkeiten auf jeder Hardware.



## Widerspruchs-Mixer und Breadcrumb
US15/US16 ergaenzen den bestehenden Plattformflow. Gegenpositionen nutzen die vorhandene Fokusvorschau und den Originalplayer. Sessionabschluss ist ueberspringbar, nicht modal erzwungen. Native Bedienung und Quellenzugang bleiben erhalten; Graph immer auch als barrierefreie Liste. Watch bietet kompakte Entscheidungen und bestaetigte Transferzustaende, Vollclients den vollstaendigen Wissensgraph-/Exportflow. Details in `../breadcrumb-and-counterpoint.md`.

## Smart Podcast List (1.3)
Native Sidebar mit persönlichen Themenfeeds, Archiv-/Kompositionsjobs und Ausgabeninspector. Ein zentraler Player für alle Fenster. Image Playground als nutzergeführter Dialog; native Fallback-Cover bei fehlender Verfügbarkeit.
