# watchOS 27 — Fokus am Handgelenk

Eigenständige SwiftUI-App mit vier kurzen Einstiegen: Tagesfokus, Weiterhören, Erkenntnisse, Frage. Keine Miniaturkopie der Smartphone-Tabs. Vertikales Blättern/Karten, Listennavigation, Crown und große Hauptaktionen folgen Systemkonventionen.

**Tagesfokus:** „3 Stellen · 8 Min.“ → Quellenübersicht → Start. Player zeigt Quelle, Originalzeit, Segment 2/3, Pause/Skip und „Mehr Kontext“. Eine gespeicherte Erkenntnis kann markiert, als bekannt oder als nicht relevant bewertet werden. Umfangreiche Profileditierung erfolgt auf Vollclients; Feedback bleibt auch offline in einer Outbox.

**Offline-Pack:** native Audio-Dateien/Manifest, validierte Segmente und kurze Evidence-Auszüge. Nicht das komplette Podcastarchiv auf die Watch kopieren. Status unterscheiden vorbereitet / wird übertragen / unvollständig / offline bereit. Checksums und Zugriffspolicy werden vor dem Start geprüft. Kopfhörer-/Ausgaberouten und Systeminterruptions testen.

**KI unter watchOS 27:** Foundation Models über PCC ist dokumentiert. Ein kurzer Request verwendet nur den lokal vorhandenen Evidence-Pack; alternativ wird ein ausdrücklich bezeichneter Companion-Auftrag erstellt. Die Watch hat nicht automatisch SpotlightSearchTool oder das gesamte Wissen des Macs. Der Umfang steht an der Antwort. Ohne PCC/Netz/Companion zeigt sie gespeicherte Erkenntnisse und spielt erlaubtes lokales Audio; keine erfundene Vollantwort. [A06, A10, A21]

**Handoff:** WatchConnectivity ist Verbindung zum gekoppelten iPhone, kein universeller Mac-RPC-Bus. Live-Message erfordert Erreichbarkeit; persistente Übertragung hat gesonderten Status. Direkter CloudKit-Metadatensync erfolgt nur nach Plattform-/Accountprüfung. Langformtranskription wird nicht auf die Watch geplant. [A23]

Widget/Smart Stack zeigt letzte bestätigte Fokusliste und direkte Nutzeraktion. Kein Ton und keine lange KI durch einen Widgetrefresh. „Export“ speichert einen sichtbaren Auftrag für einen Vollclient; Datei ist erst nach dessen Bestätigung fertig.

**Abnahme:** Telefon aus, Watch offline, nur WLAN/Cellular, Pack halb übertragen, PCC-Limit, Diktat-/Eingabeverfügbarkeit, kurze vs. lange Antworten, VoiceOver, Handgelenk unten, Anrufunterbrechung und native Audiowiedergabe. Keine pauschale Zusage direkter PCC-Verfügbarkeit ohne reales Gerät/Entitlement.



## Widerspruchs-Mixer und Breadcrumb
US15/US16 ergaenzen den bestehenden Plattformflow. Gegenpositionen nutzen die vorhandene Fokusvorschau und den Originalplayer. Sessionabschluss ist ueberspringbar, nicht modal erzwungen. Native Bedienung und Quellenzugang bleiben erhalten; Graph immer auch als barrierefreie Liste. Watch bietet kompakte Entscheidungen und bestaetigte Transferzustaende, Vollclients den vollstaendigen Wissensgraph-/Exportflow. Details in `../breadcrumb-and-counterpoint.md`.

## Smart Podcast List (1.3)
Persönliche Ausgaben aus vollständig übertragenen Packs auswählen, Originalsegmente hören, Kapitel wechseln und Restzeit sehen. Cover kommt vom Vollclient/Sync; keine angenommene Image-Playground-Generierung auf der Watch. Hörintervalle gehen in globale Ledger.
