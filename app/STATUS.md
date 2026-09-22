# Funktionsstand

Stand 22. September 2026, Version 0.1.

## Geprüft

| Bereich | Wie geprüft |
|---|---|
| iOS- und macOS-App bauen | Xcode 27, Debug und Release, signiert |
| Start ohne Absturz | iPhone-Simulator und Mac |
| Alle fünf Tabs öffnen | UI-Test im Simulator |
| Feed hinzufügen, Folgen anzeigen | UI-Test mit echtem Feed |
| Folge laden, transkribieren, Belege mit Zeitmarken | Ende-zu-Ende-Test auf dem Mac mit echter englischer Folge |
| Kernlogik: Intervalle, Hörplan, Relevanz, Export, Freigaben | 36 Swift-Tests im Paket |

## Noch auf einem Gerät zu prüfen

| Bereich | Warum offen |
|---|---|
| Relevanzauswahl, Chat, Gegenpositionen | Brauchen Apple Intelligence, das es im Simulator nicht gibt |
| Transkription auf iPhone und iPad | Der Simulator hat keine Spracherkennung |
| Wiedergabe im Hintergrund, AirPlay, CarPlay | Nur auf Hardware sinnvoll |
| Hintergrundaktualisierung | Das System plant sie erst nach einiger Nutzung ein |
| Siri und Kurzbefehle | Brauchen ein installiertes Build auf einem Gerät |

## Bewusst nicht enthalten

- Private Cloud Compute. Dem Entwicklerkonto fehlt die Berechtigung, deshalb läuft alles auf dem Gerätemodell.
- Audio und Untertitel fremder YouTube-Videos.
- Apple Watch App.

## In diesem Stand behobene Fehler

- Beide Apps stürzten beim Start ab, weil die Fehleranzeige das App-Modell nicht fand.
- Erschliessen hing: MP3-Dateien melden am Ende einen Fehler statt null Frames, und die Analyse wurde erst nach ihrem eigenen Ende abgeschlossen. Eine Folge von neun Minuten brauchte 44 Minuten, jetzt 21 Sekunden.
- Transkription lief in der Gerätesprache statt in der Sprache des Podcasts.
- Nach einem Fehler blieb die Transkription gesperrt und meldete bei jedem Versuch „läuft bereits“.
- Der Markdown-Export schlug Quellen- und Folgentitel mit dem falschen Schlüssel nach und hätte überall „Unbekannte Quelle“ gezeigt.
- Tabulator und Seitenvorschub im Transkript wurden im Export zu Zeilenumbrüchen.
- Über der Tab-Leiste stand eine leere Mini-Player-Leiste, auch wenn nichts lief.
