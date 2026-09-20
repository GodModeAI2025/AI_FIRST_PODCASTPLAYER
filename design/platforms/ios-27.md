# iOS 27 — unterwegs verstehen und hören

Vier Tabbereiche mit je eigener NavigationStack. Ein kleiner systemintegrierter Player bleibt bei aktiver Wiedergabe erreichbar. „Für dich“ startet mit persönlichem Nutzen, nicht mit einem riesigen Cover. Neue Folgen zeigen Analysebasis und Lücken.

**Journey:** Relevanzkarte → Verstehen → Evidence-Chip → Fokusvorschau → Start. Der Rückweg führt zur ursprünglichen Karte bzw. Chatantwort, ohne normalen Queuezustand zu verlieren. Chat-Scope ist über dem Eingabefeld dauerhaft sichtbar. „Spiele …“ zeigt kurze Startkarte mit Undo/Stop; eine reine Frage bleibt stumm.

Die Detailseite bietet Verstehen / Hören / Fragen. Kapitel und Transkript sind erreichbar, aber nicht als sechs verschachtelte Tabs. Fokusliste als Sheet mit Größe passend zum Inhalt; Vollbild nur bei Bedarf. Eine aktive Budget-Sitzung zeigt verbleibende aktive Hörzeit und Originalquelle.

Share Extension übernimmt URL/Dateireferenz in einen persistenten Importauftrag und kehrt zügig zurück. Keine lange Transkription oder PCC-Session in der Extension. Berechtigungen erst beim konkreten Bedarf; ein Dateipodcast braucht keine Mikrofonerlaubnis. Benachrichtigungen sind optional und öffnen vorbereiteten Inhalt, starten keinen Ton.

Systemintegration: Now Playing, Remote Commands, App Intents, Widgets/Live Activities wo sinnvoll und auf echter Hardware validiert. Ein laufender Backgroundjob nutzt den dafür vorgesehenen Systemstatus; eigene Aktivitätsanzeigen dürfen keinen zweiten widersprüchlichen Fortschritt darstellen.

**Abnahme:** Sperrbildschirm, AirPlay/Bluetooth, Anrufunterbrechung, Kopfhörerentfernung, 1,25×-Fokus, größter Text, Einhandbedienung, offline, reduzierte Bewegung/Transparenz, leere Mediathek und nur Metadaten. iPhone-Fenster-/Größenänderungen nach SwiftUI-Containerbreite behandeln, keine fixen Pixel aus dem Bild.



## Widerspruchs-Mixer und Breadcrumb
US15/US16 ergaenzen den bestehenden Plattformflow. Gegenpositionen nutzen die vorhandene Fokusvorschau und den Originalplayer. Sessionabschluss ist ueberspringbar, nicht modal erzwungen. Native Bedienung und Quellenzugang bleiben erhalten; Graph immer auch als barrierefreie Liste. Watch bietet kompakte Entscheidungen und bestaetigte Transferzustaende, Vollclients den vollstaendigen Wissensgraph-/Exportflow. Details in `../breadcrumb-and-counterpoint.md`.

## Smart Podcast List (1.3)
„Für dich → Meine Podcasts“ zeigt persönliche Themenfeeds. Ausgaben besitzen Cover, textuelle Shownotes und Originalkapitel. Persönlicher Player führt persönliche und Originalzeit getrennt. Image Playground wird nur nach Coveraktion als Systemdialog präsentiert.
