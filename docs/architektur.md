# Architektur

## Aufbau

Die Logik liegt im Swift-Paket `app/Packages/PodcastAIKit`, die Oberfläche in `app/Apps`. iPhone, iPad und Mac teilen fast alle Ansichten; nur die Wurzel unterscheidet sich (Tab-Leiste auf iOS, Seitenleiste auf dem Mac).

| Modul | Aufgabe |
|---|---|
| PodcastAICore | Domäne: Quellen, Folgen, Zeitbereiche, Belege, Fakten, Hörzustand |
| PodcastAISources | RSS, Atom, OPML, Podlove- und Podcasting-2.0-Kapitel, Feed-Suche, YouTube |
| PodcastAIMedia | Download, Audio lesen, Formaterkennung für Dateien ohne Endung |
| PodcastAITranscription | SpeechAnalyzer mit Zeitmarken |
| PodcastAIIntelligence | Apple Intelligence auf dem Gerät und auf Private Cloud Compute |
| PodcastAIKnowledge | Relevanz, Suche für den Chat, Gegenpositionen |
| PodcastAIPlayback | Wiedergabe einzelner Stellen mit Freigabe |
| PodcastAISmartFeeds | Themen-Updates mit Kapiteln, Shownotes und Cover |
| PodcastAIExport | Markdown-Export für Folgen, Antworten und gemerkte Stellen |
| PodcastAIPersistence | SwiftData mit Abgleich über iCloud |

## Vom Feed zur Antwort

1. Der Feed liefert Folgen mit Audio-Adresse, Kapiteln und Shownotes.
2. Die App lädt die jüngsten Folgen und transkribiert sie auf dem Gerät. Jedes Wort trägt seine Zeit im Ton.
3. Das Transkript wird in Passagen von etwa einer Minute geschnitten. Jede Passage ist ein Beleg mit Zeitbereich.
4. Apple Intelligence zieht daraus Fakten. Jede Aussage zeigt auf ihren Beleg. Das läuft in einer eigenen Warteschlange neben den Transkripten, eine Folge nach der anderen und ohne das nächste Transkript aufzuhalten. Beim Start, nach Abgleich und Aktualisieren reiht die App Folgen mit Transkript ohne Fakten nach, neueste zuerst. Kam das Transkript von einem anderen Gerät, wartet dieses Gerät 20 Minuten auf dessen Fakten. Auf dem iPhone und iPad arbeitet die Warteschlange, solange die App vorn ist. Im Hintergrund arbeitet sie nur mit Zeit vom System: in der Hintergrundaufgabe `com.podcastai.analysis` oder solange Transkripte unter der fortgesetzten Verarbeitung entstehen. Der Ton im Hintergrund zählt nicht. Geht die App in den Hintergrund, hält die laufende Folge an und bleibt vorn in der Warteschlange. Scheitern einzelne Abschnitte einer Folge an Last oder Zeitüberschreitung, speichert die App, was da ist, merkt sich die fehlenden Abschnitte auf diesem Gerät und holt nur sie später nach.
5. Eine Frage sucht zuerst auf dem Gerät die passenden Belege: Stichworte gewichtet nach Seltenheit und semantische Nähe über Apples NaturalLanguage-Einbettungen. Nur diese Belege sieht das Sprachmodell. Die Antwort verweist mit Nummern auf sie. Ist die Frage auf einen Podcast oder einen Zeitraum eingegrenzt, nimmt der Code die übrigen Folgen vorher heraus; das Modell wählt nur unter dem, was bleibt.

## Welches Modell wann

| Aufgabe | Bevorzugt | Rückfall |
|---|---|---|
| Fragen beantworten, Positionen vergleichen | Private Cloud Compute | Gerätemodell |
| Fakten ziehen, Relevanz prüfen | Gerätemodell | keiner |

PCC heißt in der Oberfläche „Apple-Server“ und ist in den Einstellungen und auf der Datenschutzseite abschaltbar. Seit 0.7.1 tragen beide Apps die Berechtigung `com.apple.developer.private-cloud-compute` und den Info.plist-Schlüssel `PodcastAIPrivateCloudComputeEntitled`; der Schalter steht ab Werk an. Fehlt der Schlüssel in einem Build, bleibt PCC aus, denn ohne Berechtigung beendet FoundationModels unter iOS 27 die App beim ersten Fehler einer PCC-Anfrage. Ohne Apple Intelligence formuliert die App nichts und zeigt die passendsten Stellen im Wortlaut.

## Mobilfunk

Was jemand selbst abspielt, mit „Laden (offline)“ holt oder als Transkript anfordert, lädt auch über Mobilfunk. Ist in den Einstellungen unter Mobilfunk „Abspielen und Laden über Mobilfunk“ aus, fragt die App im Mobilfunk oder Hotspot vorher („Über Mobilfunk laden?“). Ein Ja gilt, bis das Gerät wieder im WLAN ist. Die nächste Folge aus „Als Nächstes“ startet dann nur, wenn sie geladen ist, damit keine Frage aus der Hosentasche kommt. Siri spielt in diesem Fall nichts aus dem Netz und sagt, warum. Angeforderte Transkripte, deren Ton noch nicht auf dem Gerät liegt, warten ohne Ja in der Warteschlange („wartet auf WLAN“), auch wenn sie im WLAN angefordert wurden. Kommt die Warteschlange bei ihnen an, fragt die App einmal für alle; nach „Abbrechen“ laufen sie im nächsten WLAN weiter. Was schon auf dem Gerät liegt, fragt nie, auch nicht „Auf dem Gerät behalten“. Transkripte für neue Folgen regelt davon getrennt „Nur im WLAN“. Umgesetzt in `AppModel.askBeforeMobileData` und `AppModel.queueWait(for:)`, die Frage stellt `MobileDataQuestion`. Sie und die Fehlermeldung hängen an der Wurzel und an jedem Blatt (`sheetFeedback()`); das oberste offene Blatt zeigt sie, sonst warteten sie hinter der Warteschlange oder dem Player.

## Abgleich

SwiftData spiegelt die Datenbank in den CloudKit-Container `iCloud.com.godmodeai.podcastai`, den iPhone-, iPad- und Mac-App gemeinsam nutzen. Abgeglichen werden Abos, Folgen, Transkripte, Belege, Fakten, Hörzustand mit Fortsetzungsstelle, Interessen, Themen-Updates, gemerkte Stellen und geparkte Fragen. Audiodateien nicht; jedes Gerät lädt den Ton selbst oder streamt ihn.

CloudKit kennt keine eindeutigen Schlüssel. Treffen zwei Geräte denselben Datensatz, bereinigt `LibraryStore.removeDuplicates()` die Doppelten beim nächsten Laden.

## Löschen

| Aktion | Was verschwindet | Was bleibt |
|---|---|---|
| Audio entfernen | die Audiodatei | Transkript, Belege, Fakten, Hörzustand, gemerkte Stellen; abgespielt wird aus dem Netz |
| Folge löschen | Audiodatei, Transkript, Belege, Fakten, Hörzustand dieser Folge, ihre Stellen in Themen-Updates; Chat-Antworten, die sie zitieren; in gesicherten Antworten ihre Belege und ein daraus formulierter Antworttext, leere Karten ganz | ein Merkzeichen, damit der Feed die Folge nicht wieder anlegt; deine Notizen, denn sie tragen Zitat, Folge, Quelle und Zeitmarke selbst |
| Quelle abbestellen | die Quelle mit allen Folgen und deren Daten, ihre Stellen in Themen-Updates | deine Notizen |

Beides ist in `LibraryStore.removeEpisode`, `removeSource` und `markAudioRemoved` umgesetzt und durch Tests abgesichert. Eine Ausgabe, der dabei alle Stellen verloren gehen, verschwindet ganz; bei den übrigen rückt die Zeitachse zusammen (`PersonalEpisodePublisher.removingSegments`).

Den Ton räumt die App auch von selbst weg, beides in den Einstellungen abschaltbar und voreingestellt an: nach dem erfolgreichen Auswerten und einen Tag, nachdem eine Folge zu Ende gehört ist. Es ist derselbe Weg wie „Audio entfernen“, alle Daten bleiben. Was mit „Laden (offline)“ geholt wurde, bleibt nach dem Auswerten liegen. Eine Folge im Player wartet, bis sie dort nicht mehr liegt. Welche Folgen jemand aus der Warteschlange genommen oder für unterwegs geladen hat, merkt sich jedes Gerät in den Benutzereinstellungen, nicht in der Datenbank.

## Themen-Updates

Eine Ausgabe entsteht auf zwei Wegen. Von Hand über „Neue Ausgabe zusammenstellen“ oder Siri, dann ohne Mindestmenge. Von selbst nach dem Aktualisieren der Feeds, nach der Auswertung neuer Folgen und in der Hintergrundaufgabe `com.podcastai.analysis`, dann erst ab fünf Minuten ungehörtem Material und nur, wenn die letzte Ausgabe gehört oder älter als zwölf Stunden ist. Auf dem Mac gibt es keinen `BGTaskScheduler`; dort übernimmt das Aktualisieren beim Start und alle 30 Minuten diese Rolle. Keine Ausgabe startet Ton.
