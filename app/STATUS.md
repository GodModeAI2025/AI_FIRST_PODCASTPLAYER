# Funktionsstand

Stand 22. September 2026, Version 0.6.1.

## Geprüft

| Bereich | Wie geprüft |
|---|---|
| iOS- und macOS-App bauen | Xcode 27, Debug und Release, signiert |
| Start ohne Absturz | iPhone-Simulator und Mac |
| Alle fünf Tabs öffnen | UI-Test im Simulator |
| Feed hinzufügen, Folgen anzeigen | UI-Test mit echtem Feed |
| MP3-Link, Podigee-Adresse ohne Feed, YouTube-Kanal mit Audio-Podcast, Thema im Themen-Update | UI-Tests mit den Links aus dem TestFlight-Feedback |
| Transistor-Feed abonnieren, Folge mit Kapiteln und Shownotes öffnen, abspielen, Player, Warteschlange, Erklärung der Interessenarten | UI-Tests mit den Links aus dem Feedback zu 0.2 |
| Geladene Folge abspielen, Zeit läuft | UI-Test mit der MP3 aus dem Feedback, erst laden, dann abspielen |
| Themen-Update anlegen mit eingetipptem Thema | UI-Test, „Anlegen“ bleibt nicht gesperrt |
| Folge laden, transkribieren, Belege mit Zeitmarken | Ende-zu-Ende-Test auf dem Mac mit echter englischer Folge |
| Folge mit Reitern, Fragen an eine Folge, Export, Folge löschen, Einstellungen | UI-Tests im Simulator |
| Löschregeln: Audio entfernen behält Daten, Folge löschen entfernt alles und bleibt gelöscht, Quelle abbestellen, Doppelte aus dem Abgleich | Swift-Tests mit Speicher im Arbeitsspeicher |
| CloudKit-Schema für alle 13 Datentypen | angelegt und nach Production übertragen |
| Zusammenführen doppelter Datensätze, Hörstand je Gerät, verwaiste Zeilen | Swift-Tests, zuerst rot gegen den alten Stand |
| Code-Prüfung | mehrstufig: Funde je Bereich, jeder von zwei Prüfern gegengeprüft, jede Korrektur einzeln nachgeprüft |
| Kernlogik: Intervalle, Hörplan, Relevanz, Suche für den Chat, Export, Freigaben | 104 Swift-Tests im Paket |
| Upload nach App Store Connect | Jede Version für iOS und macOS, interne TestFlight-Gruppe „Intern“ je App |

## Noch auf einem Gerät zu prüfen

| Bereich | Warum offen |
|---|---|
| Relevanzauswahl, Chat, Fakten, Gegenpositionen | Brauchen Apple Intelligence, das es im Simulator nicht gibt |
| Abgleich zwischen iPhone, iPad und Mac | Braucht zwei Geräte mit derselben Apple-ID und das Schema in der Produktionsumgebung |
| Private Cloud Compute | Braucht die von Apple zugewiesene Berechtigung |
| Transkription auf iPhone und iPad | Der Simulator hat keine Spracherkennung |
| Wiedergabe im Hintergrund, AirPlay, CarPlay | Nur auf Hardware sinnvoll |
| Hintergrundaktualisierung | Das System plant sie erst nach einiger Nutzung ein |
| Erschliessen im Hintergrund | Die Fortschrittsanzeige des Systems gibt es nur auf einem iPhone oder iPad |
| Siri und Kurzbefehle | Brauchen ein installiertes Build auf einem Gerät |

## Bewusst nicht enthalten

- Audio und Untertitel fremder YouTube-Videos.
- Pausen kürzen und Lautstärke angleichen. Beides bräuchte eine eigene Audio-Verarbeitung statt AVPlayer.
- CarPlay. Dafür vergibt Apple eine eigene Berechtigung.
- Apple Watch App.

## In diesem Stand behobene Fehler

- Beide Apps stürzten beim Start ab, weil die Fehleranzeige das App-Modell nicht fand.
- Erschliessen hing: MP3-Dateien melden am Ende einen Fehler statt null Frames, und die Analyse wurde erst nach ihrem eigenen Ende abgeschlossen. Eine Folge von neun Minuten brauchte 44 Minuten, jetzt 21 Sekunden.
- Transkription lief in der Gerätesprache statt in der Sprache des Podcasts.
- Nach einem Fehler blieb die Transkription gesperrt und meldete bei jedem Versuch „läuft bereits“.
- Der Markdown-Export schlug Quellen- und Folgentitel mit dem falschen Schlüssel nach und hätte überall „Unbekannte Quelle“ gezeigt.
- Tabulator und Seitenvorschub im Transkript wurden im Export zu Zeilenumbrüchen.
- Über der Tab-Leiste stand eine leere Mini-Player-Leiste, auch wenn nichts lief.
- Mehrere gleichzeitig gestartete Erschliessungen scheiterten an der Grenze der Spracherkennung. Sie laufen jetzt nacheinander.
- Feeds, die mit einer Stylesheet-Anweisung beginnen, wurden als Webseite behandelt.
- Geladene Folgen blieben stumm, weil die Datei keine Endung hat und AVFoundation das Format nicht erkannte.
- Die Wiedergabe begann an einer zufälligen Stelle, weil der Sprung vor dem Bereitsein der Folge verpuffte.
- Erschlossene Folgen galten nach einem Neustart wieder als unbearbeitet.
