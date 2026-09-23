# Architektur

## Aufbau

Die Logik liegt im Swift-Paket `app/Packages/PodcastAIKit`, die Oberfläche in `app/Apps`. iPhone, iPad und Mac teilen fast alle Ansichten; nur die Wurzel unterscheidet sich (Tab-Leiste auf iOS, Seitenleiste auf dem Mac).

| Modul | Aufgabe |
|---|---|
| PodcastAICore | Domäne: Quellen, Folgen, Zeitbereiche, Belege, Fakten, Hörzustand |
| PodcastAISources | RSS, Atom, OPML, Podlove- und Podcasting-2.0-Kapitel, Feed-Suche, YouTube, Podcast-Katalog über Podcast Index |
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

## Podcast-Katalog

Das Blatt „Podcast hinzufügen“ ist zugleich der Katalog. Die Daten kommen von Podcast Index (podcastindex.org), einem offenen Verzeichnis mit gut vier Millionen Feeds. Der Client steht in `PodcastIndexClient`, die Ansichten in `CatalogViews.swift`, Zugang und Zwischenspeicher in `PodcastCatalog.swift`.

| Teil | Endpunkt | Was die App daraus macht |
|---|---|---|
| Suche | `search/byterm` und Apples `itunes.apple.com/search` zugleich | `CatalogMerge` legt Treffer mit gleicher Feed-Adresse (auch der alten vor einem Umzug) oder gleicher Apple-Kennung zusammen. Antwortet nur einer der beiden Dienste, zählt dessen Liste. |
| Angesagt | `podcasts/trending?lang=de,de-de,de-at,de-ch` | In der Sprache der App, mit Schalter für alle Sprachen. `lang` trifft die Schreibweise im Feed, deshalb filtert die App die Antwort noch einmal nach `language`. |
| Kategorien | `podcasts/trending?cat=…` | Podcast Index kennt 112 Wörter ohne Hierarchie, nur auf Englisch. `CatalogCategory` fasst sie zu 19 Rubriken mit Namen auf Deutsch und Englisch, SF Symbol und Farbe zusammen. Oberbegriffe entscheiden, Unterbegriffe zählen nur, wenn kein Oberbegriff passt. Die API blättert nicht, „Mehr laden“ fragt eine längere Liste, höchstens 200. |
| Seite eines Podcasts | `podcasts/byfeedid`, `episodes/byfeedid` (10 Folgen) | Großes Cover, Kategorien, Beschreibung, Website, neueste Folgen mit Datum und Länge. Ohne Kennung bei Podcast Index liest die App den Feed selbst. |

Regeln:

- Aus dem Katalog wird nichts abgespielt. `CatalogEpisode` trägt nicht einmal eine Audio-Adresse. Abonniert wird über `AppModel.subscribe(to:)`, denselben Weg wie ein eingefügter Link.
- Texte aus dem Katalog sind fremde Daten. `CatalogText` macht aus HTML reinen Text, Adressen gehen durch `NetworkDestination` und werden auf https gehoben. Nichts davon geht an ein Sprachmodell.
- Aufgegebene Feeds (`dead`) und Feeds, die kein Podcast sind (`medium` Musik, Film, Blog, Newsletter), zeigt der Katalog nicht.
- Jede Anfrage trägt `User-Agent: PodcastAI/<Version>`, `X-Auth-Key`, `X-Auth-Date` (Unixzeit in ganzen Sekunden) und `Authorization`, den SHA-1 über Schlüssel, Geheimnis und Zeit in kleinen Hexziffern. `PodcastIndexSignature` rechnet ihn, ein Test prüft ihn am Rechenbeispiel der Dokumentation. Der Server nimmt nur Zeiten an, die höchstens drei Minuten abweichen. Nach einem 401 rechnet der Client deshalb einmal mit der Zeit aus der Kopfzeile `Date` nach, wenn die Uhr des Geräts mehr als eine Minute danebenliegt.
- `RedirectGuard` entfernt bei einem Wechsel des Hosts auch `X-Auth-Key` und `X-Auth-Date`.
- Fehler des Katalogs (`PodcastIndexError`) haben eigene Sätze. Ein 429 heißt „zu viele Anfragen“ und nicht „der Server des Podcasts“.
- Angesagt, Einzelheiten und Folgen hält die App 15 Minuten im Speicher. Die Betreiber erlauben das für Daten, die jemand öffnet, nicht aber, den Index abzugrasen. Die Suche wartet wie bisher 450 ms nach dem letzten Tastendruck.
- Cover lädt `AsyncImage` direkt vom Server des Podcasts über den gemeinsamen `URLCache` (32 MB Speicher, 256 MB Platte).

Zugang: Schlüssel und Geheimnis stehen in `app/Config/PodcastIndex/PodcastIndexCredentials.plist`. Die Datei ist in `.gitignore`, denn das Repository ist öffentlich. Wie man sie anlegt, steht in `app/README.md`. Der Ordner ist in `project.yml` als Ordnerreferenz eingebunden, kopiert wird also, was beim Bauen darin liegt. Eine einzelne Datei mit `optional: true` ließ den Build scheitern, wenn sie fehlte. Fehlt die Datei oder ist ein Feld leer, ist der Katalog aus: Die Suche fragt nur Apple, Angesagt, Kategorien und der Absatz zu Podcast Index in den Datenschutzangaben fehlen, und nichts geht an Podcast Index.

UI-Tests starten mit `-catalog-fixtures`. Dann antwortet der Katalog in Debug-Builds aus `PodcastIndexFixtures`, ohne Netz und ohne Zugang.

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

Geschnitten wird an den Kapitelmarken des Originals. Liegt eine passende Stelle in einem Kapitel, das höchstens zehn Minuten lang ist, kommt das ganze Kapitel in die Ausgabe; weitere Stellen aus demselben Kapitel hängen sich als Belege an denselben Abschnitt. Ist das Kapitel länger, fehlen Kapitel oder ist das Ende des letzten Kapitels unbekannt, bleibt es bei der Stelle mit sechs Sekunden Vorlauf. Kapitel aus einer eigenen Kapiteldatei lädt die App beim Zusammenstellen für bis zu zwölf Folgen nach. Was ins Budget kommt, entscheidet die Relevanz. Abgespielt wird danach Folge für Folge: die relevanteste Folge zuerst, ihre Abschnitte am Stück und in der Reihenfolge des Originals. Ist ein Abschnitt zu Ende, beginnt der nächste von selbst, solange die angetippte Ausgabe läuft (`PersonalEpisodePublisher.playbackOrder`, `PlaybackCoordinator`). Dieselbe Folge-für-Folge-Ordnung gilt für Hörpläne aus „Für dich“ und dem Chat (`FocusPlanner`).
