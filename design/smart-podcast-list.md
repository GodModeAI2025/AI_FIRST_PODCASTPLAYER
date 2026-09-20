# Neue Screens / Zustände: Smart Podcast List
**Spezifikations-Wireflow, keine neuen gerenderten Screens.** Vorhandene Bilder bleiben Referenz für Stil und Grundnavigation. iOS/iPadOS/watchOS/macOS 27; Sonar/BrainSpeak.

## SF01 — Für dich / Meine Podcasts
Zusätzlicher Bereich innerhalb des bestehenden Tabs „Für dich“, kein unreflektierter fünfter Tab. Karten: Feedcover, Name, Zahl neuer persönlicher Ausgaben, letzte Ausgabedauer, Zustand „Neue Folge“/„Wird vorbereitet“/„Nichts Neues“. Beispiele: „Mein Datenschutz-Podcast“, „Mein Themen-Update“. Plus öffnet Thema/Frage, Quellen, Alles-Ungehörte oder Zeitbudget, Filter und Lernfreigabe.

## SF02 — Themenfeed
Feedcover, Name, editierbare Beschreibung, Topics und Scope. Ausgabenliste mit Ausgabecover, Titel, Datum der Zusammenstellung, Herkunftszeitraum, Länge und Reststatus. Primäraktion letzte neue Ausgabe spielen; Sekundäraktion Umfang ansehen. Keine neuen Kandidaten: „Du bist für diesen Bestand auf dem aktuellen Stand“ plus ehrliche Analyseabdeckung.

## SF03 — Persönliche Folge
Eigenes Cover, Titel, KI-zusammengestellt-Hinweis, Originalstimmen, Gesamtlänge, Quellenzahl. Play setzt begrenzten Plan frei. Tabs/Bereiche „Überblick“, „Kapitel“, „Fragen“. Textuelle Shownotes fassen enthaltene Originalsegmente zusammen. Jede Kapitelzeile zeigt persönliche Zeit, Originalquelle und Originalzeitspanne. Fehlender Inhalt wird vor Start sichtbar statt durch fremden Inhalt ersetzt.

## SF04 — Personal Player
Oben Ausgabetitel/-cover, darunter aktuell sprechende Originalquelle und belegter Sprechername, sofern verfügbar. Hauptscrubber: persönliche Gesamtzeit. Nebenzeile: „Original 18:40 / 68:00“. Aktionen „Nächster Ausschnitt“, „Im Original weiterhören“, „Merken“. Keine sprechende KI zwischen Ausschnitten. Kontextwiederholung ist beschriftet. Beim Quellenwechsel ist die neue Quelle sichtbar und barrierefrei ansprechbar.

## SF05 — Originalfolge / Hörmodus
Drei Einstiege: „Ganz hören“, „Für mich relevante Stellen“ und direkte Kapitel-/Timecode-Aktion. Relevanzgrund kommt aus bestätigtem Profil; kein erneutes Interview. Eine Mischfunktion „Alles zum Thema über meine Quellen“ führt von hier zu einem Feedentwurf und setzt ihn nicht ungefragt dauerhaft aktiv.

## SF06 — Cover gestalten
Automatisches Layoutcover bereits sichtbar. Button „Mit Image Playground gestalten“ erscheint nur bei Unterstützung; eigener Dialog mit vorausgefülltem, datensparsamen Motiv. Nach Nutzerbestätigung neues Cover speichern. Abbruch behält vorheriges Cover. Native Layoutcover und generierte Illustration erhalten unterschiedliche Herkunftskennzeichnung. Optional einmaliges Feedmotiv für Folgeausgaben.

## Plattformadaption
| Plattform | Verhalten |
|---|---|
| iPhone | Karten → Feed → Ausgabe; Mini-Player bleibt; Cover als natives Sheet. |
| iPad | Sidebar/Feedliste + Ausgabe + optionaler Quelleninspector; alle Aktionen bei schmalem Fenster navigierbar. |
| Mac | Native Sidebar „Meine Podcasts“, Sortierung, Ausgabeninspector und Mehrfensteransicht bei zentralem Player. |
| Watch | Kompakte Ausgabenliste, großes Play, Kapitel-/Quellenwechsel, verbleibende Dauer; gespeicherte Cover, keine lokale Bildgenerierung. |

Neue persönliche Ausgaben können nach optionaler Freigabe benachrichtigen; Benachrichtigungen spielen kein Audio ab.
