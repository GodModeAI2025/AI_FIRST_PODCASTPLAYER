# Architektur

## Aufbau

Die Logik liegt im Swift-Paket `app/Packages/PodcastAIKit`, die Oberfläche in `app/Apps`. iPhone, iPad und Mac teilen fast alle Ansichten; nur die Wurzel unterscheidet sich (Tab-Leiste auf iOS, Seitenleiste auf dem Mac).

| Modul | Aufgabe |
|---|---|
| PodcastAICore | Domäne: Quellen, Folgen, Zeitbereiche, Belege, Fakten, Hörzustand |
| PodcastAISources | RSS, Atom, Podlove- und Podcasting-2.0-Kapitel, Feed-Suche, YouTube |
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
4. Apple Intelligence zieht daraus Fakten. Jede Aussage zeigt auf ihren Beleg.
5. Eine Frage sucht zuerst auf dem Gerät die passenden Belege: Stichworte gewichtet nach Seltenheit und semantische Nähe über Apples NaturalLanguage-Einbettungen. Nur diese Belege sieht das Sprachmodell. Die Antwort verweist mit Nummern auf sie.

## Welches Modell wann

| Aufgabe | Bevorzugt | Rückfall |
|---|---|---|
| Fragen beantworten, Positionen vergleichen | Private Cloud Compute | Gerätemodell |
| Fakten ziehen, Relevanz prüfen | Gerätemodell | keiner |

PCC ist in den Einstellungen abschaltbar. Ohne Apple Intelligence formuliert die App nichts und zeigt die passendsten Stellen im Wortlaut.

## Abgleich

SwiftData spiegelt die Datenbank in den CloudKit-Container `iCloud.com.godmodeai.podcastai`, den iPhone-, iPad- und Mac-App gemeinsam nutzen. Abgeglichen werden Abos, Folgen, Transkripte, Belege, Fakten, Hörzustand mit Fortsetzungsstelle, Interessen, Themen-Updates, gemerkte Stellen und geparkte Fragen. Audiodateien nicht; jedes Gerät lädt den Ton selbst oder streamt ihn.

CloudKit kennt keine eindeutigen Schlüssel. Treffen zwei Geräte denselben Datensatz, bereinigt `LibraryStore.removeDuplicates()` die Doppelten beim nächsten Laden.

## Löschen

| Aktion | Was verschwindet | Was bleibt |
|---|---|---|
| Audio entfernen | die Audiodatei | Transkript, Belege, Fakten, Hörzustand, gemerkte Stellen; abgespielt wird aus dem Netz |
| Folge löschen | Audiodatei, Transkript, Belege, Fakten, Hörzustand dieser Folge | ein Merkzeichen, damit der Feed die Folge nicht wieder anlegt; deine Notizen, denn sie tragen Zitat, Folge, Quelle und Zeitmarke selbst |
| Quelle abbestellen | die Quelle mit allen Folgen und deren Daten | deine Notizen |

Beides ist in `LibraryStore.removeEpisode`, `removeSource` und `markAudioRemoved` umgesetzt und durch Tests abgesichert.

Den Ton räumt die App auch von selbst weg, beides in den Einstellungen abschaltbar und voreingestellt an: nach dem erfolgreichen Auswerten und einen Tag, nachdem eine Folge zu Ende gehört ist. Es ist derselbe Weg wie „Audio entfernen“, alle Daten bleiben. Was mit „Laden (offline)“ geholt wurde, bleibt nach dem Auswerten liegen. Eine Folge im Player wartet, bis sie dort nicht mehr liegt. Welche Folgen jemand aus der Warteschlange genommen oder für unterwegs geladen hat, merkt sich jedes Gerät in den Benutzereinstellungen, nicht in der Datenbank.
