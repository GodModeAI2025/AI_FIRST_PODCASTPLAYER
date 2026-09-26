# Funktionsstand

Stand 23. September 2026, Version 0.12.

## Geprüft

| Bereich | Wie geprüft |
|---|---|
| iOS- und macOS-App bauen | Xcode 27, Debug und Release, signiert |
| Start ohne Absturz | iPhone-Simulator und Mac |
| Alle fünf Tabs öffnen | UI-Test im Simulator |
| Feed hinzufügen, Folgen anzeigen | UI-Test mit echtem Feed |
| MP3-Link, Podigee-Adresse ohne Feed, YouTube-Kanal mit Audio-Podcast, Thema im Themen-Update | UI-Tests mit den Links aus dem TestFlight-Feedback |
| Transistor-Feed abonnieren, Folge mit Kapiteln und Shownotes öffnen, abspielen, Player, Warteschlange, Thema ohne Wahl einer Art | UI-Tests mit den Links aus dem Feedback zu 0.2 |
| Geladene Folge abspielen, Zeit läuft | UI-Test mit der MP3 aus dem Feedback, erst laden, dann abspielen |
| Themen-Update anlegen mit eingetipptem Thema | UI-Test, „Anlegen“ bleibt nicht gesperrt |
| Folge laden, transkribieren, Belege mit Zeitmarken | Ende-zu-Ende-Test auf dem Mac mit echter englischer Folge |
| Folge mit Reitern, Fragen an eine Folge, Export, Folge löschen, Einstellungen | UI-Tests im Simulator |
| Löschregeln: Audio entfernen behält Daten, Folge löschen entfernt alles und bleibt gelöscht, Quelle abbestellen, Doppelte aus dem Abgleich | Swift-Tests mit Speicher im Arbeitsspeicher |
| CloudKit-Schema für alle 13 Datentypen | angelegt und nach Production übertragen |
| Zusammenführen doppelter Datensätze, Hörstand je Gerät, verwaiste Zeilen | Swift-Tests, zuerst rot gegen den alten Stand |
| Code-Prüfung | mehrstufig: Funde je Bereich, jeder von zwei Prüfern gegengeprüft, jede Korrektur einzeln nachgeprüft |
| Kernlogik: Intervalle, Hörplan, Relevanz, Suche für den Chat, Export, Freigaben, Sprache der Modelltexte, Archiv, Nennungen, Kapitelschnitt, Behalten des Tons | 271 Swift-Tests im Paket |
| Podcastsuche nach Namen, Spotify-Hinweis, Moment merken, OPML-Import, YouTube-@-Links, Archiv, Speicher, Themen-Updates bearbeiten | UI-Tests im Simulator |
| Erwähnt im Überblick und im Chat einer Folge, ältere Folgen vorbereiten, Netzregeln unter Mobilfunk, neueste Folge behalten | UI-Tests im Simulator |
| Englische Oberfläche und deutsche Mehrzahl | UI-Tests mit `-AppleLanguages (en)` und `(de)` |
| iOS 27 | komplette UI-Suite im Simulator, ab 0.7.2 die einzige unterstützte Version |
| Bedienung durch Einsteiger bis Experten | 50 Personas mit Screenshots und Code, danach 10 Personas, die die App im Simulator selbst bedient haben, plus ein Begriffstest mit 12 Personas |
| Jeder Knopf, jedes Menü, jeder Schalter, jeder Hinweistext | Prüfung auf Wirkung, jeder Fund von Gegenprüfern bestätigt oder verworfen |
| Upload nach App Store Connect | Jede Version für iOS und macOS, interne TestFlight-Gruppe „Intern“ je App |

## Noch auf einem Gerät zu prüfen

| Bereich | Warum offen |
|---|---|
| Relevanzauswahl, Chat, Fakten | Auf dem iOS-27-Simulator läuft das Gerätemodell; die Qualität der Antworten zeigt sich erst auf einem Gerät mit Apple Intelligence |
| Abgleich zwischen iPhone, iPad und Mac | Braucht zwei Geräte mit derselben Apple-ID und das Schema in der Produktionsumgebung |
| Private Cloud Compute | Berechtigung erteilt und in beiden App-IDs eingeschaltet. Chat und Folgen-Chat antworten im iOS-27-Simulator über PCC; die Qualität zeigt sich auf einem Gerät |
| Transkription auf iPhone und iPad | Der Simulator hat keine Spracherkennung |
| Wiedergabe im Hintergrund, AirPlay, CarPlay | Nur auf Hardware sinnvoll |
| Widget „Was ist neu“ | Die Erweiterungen bauen für iOS und macOS, Schnappschuss und Schreibregel sind getestet. Anzeige, Neuladen und die Tipps auf Tag-Zeilen zeigen sich erst mit signiertem Build und eingerichteter App Group |
| YouTube-Abos aus Google Takeout | Leser und Auswahl mit Swift-Tests geprüft, der UI-Test ist gebaut, lief aber noch nicht im Simulator. Offen sind eine echte Takeout-Datei mit deutscher Kopfzeile und Apples Drosselung bei mehreren hundert Kanälen |
| Hintergrundaktualisierung | Das System plant sie erst nach einiger Nutzung ein |
| Transkripte und Fakten im Hintergrund | Die Fortschrittsanzeige des Systems gibt es nur auf einem iPhone oder iPad |
| Siri und Kurzbefehle | Brauchen ein installiertes Build auf einem Gerät |
| „An PodcastAI senden“ | Das Teilen-Menü lässt sich im UI-Test nicht bedienen; geprüft sind Eingang, Vorschau und Audiodatei über Startargumente. Offen: ob die Erweiterung nur bei Links und Audio erscheint, wie Finder und AirDrop Dateien anbieten, ob der Mac die App öffnet, wie lange eine große Datei beim Kopieren braucht. Signierte Builds brauchen einmal neue Profile mit der App Group |

## Bewusst nicht enthalten

- Audio und Untertitel fremder YouTube-Videos.
- Pausen kürzen und Lautstärke angleichen. Beides bräuchte eine eigene Audio-Verarbeitung statt AVPlayer.
- CarPlay. Dafür vergibt Apple eine eigene Berechtigung.
- Apple Watch App.

## In Version 0.7 behobene Fehler

- Fragen im Chat, in einer Folge und bei den Gegenpositionen beendeten die App unter iOS 27, weil FoundationModels ohne PCC-Berechtigung hart abbricht.
- Die automatische Vorbereitung arbeitete sich rückwärts durchs ganze Archiv.
- „Transkript erstellen“ tat nichts, solange die Folge automatisch eingereiht auf WLAN wartete.
- Automatische Themen-Updates entstanden nie, weil der Hintergrundauftrag nie angemeldet war.
- Der Agentenzugang (MCP) auf dem Mac startete nie.
- Per Siri gemerkte Stellen hatten weder Zitat noch Folge noch Zeitmarke.
- Themen trafen Wortteile, etwa „KI“ in „Kinder“.
- Fakten entstanden nur einmal direkt nach dem Transkript; scheiterte das, kamen nie welche.

## Frühere behobene Fehler

- Beide Apps stürzten beim Start ab, weil die Fehleranzeige das App-Modell nicht fand.
- Erschließen hing: MP3-Dateien melden am Ende einen Fehler statt null Frames, und die Analyse wurde erst nach ihrem eigenen Ende abgeschlossen. Eine Folge von neun Minuten brauchte 44 Minuten, jetzt 21 Sekunden.
- Transkription lief in der Gerätesprache statt in der Sprache des Podcasts.
- Nach einem Fehler blieb die Transkription gesperrt und meldete bei jedem Versuch „läuft bereits“.
- Der Markdown-Export schlug Quellen- und Folgentitel mit dem falschen Schlüssel nach und hätte überall „Unbekannte Quelle“ gezeigt.
- Tabulator und Seitenvorschub im Transkript wurden im Export zu Zeilenumbrüchen.
- Über der Tab-Leiste stand eine leere Mini-Player-Leiste, auch wenn nichts lief.
- Mehrere gleichzeitig gestartete Erschließungen scheiterten an der Grenze der Spracherkennung. Sie laufen jetzt nacheinander.
- Feeds, die mit einer Stylesheet-Anweisung beginnen, wurden als Webseite behandelt.
- Geladene Folgen blieben stumm, weil die Datei keine Endung hat und AVFoundation das Format nicht erkannte.
- Die Wiedergabe begann an einer zufälligen Stelle, weil der Sprung vor dem Bereitsein der Folge verpuffte.
- Erschlossene Folgen galten nach einem Neustart wieder als unbearbeitet.
