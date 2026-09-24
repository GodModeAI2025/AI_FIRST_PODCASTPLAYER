# PodcastAI

Ein Podcast-Player für iPhone, iPad und Mac, der zuhört. Er spielt deine Podcasts wie jeder gute Player, schreibt die Folgen auf dem Gerät mit Zeitmarken mit und macht daraus Wissen, das du befragen, nachlesen und exportieren kannst. Jede Aussage führt zurück zur Stelle im Originalton. Die App spricht Deutsch und Englisch, und was sie formuliert, kommt in deiner Sprache, auch bei Podcasts in einer anderen.

## Für wen

**Einsteiger** suchen ihre Podcasts nach Namen, abonnieren sie mit einem Tipp und hören sie. Kapitel, Shownotes, Cover, Tempo, Schlaf-Timer, AirPlay und eine Warteschlange sind da, wo man sie erwartet. Die App merkt sich, wo du warst, auch wenn du vom iPhone zum Mac wechselst.

**Fortgeschrittene** lesen das Transkript mit, springen per Tipp an jede Stelle, sehen die wichtigsten Fakten einer Folge und stellen Fragen an eine Folge oder an alle zusammen. Jede Folge und jedes Kapitel trägt Tags aus dem Inhalt; mit Plus folgst du einem Tag, mit Minus nicht mehr, und „Für dich“ zeigt die Kapitel zu den Tags, denen du folgst.

**Experten** lassen sich je Thema eine eigene Folge aus ungehörten Originalstellen mehrerer Podcasts bauen, prüfen Thesen gegen belegte Gegenstimmen und exportieren Folgen, Antworten und Notizen als Markdown, etwa nach Obsidian oder Notion. Auf dem Mac dürfen andere Programme nach Freigabe lesend auf das Wissen zugreifen.

## Was die App kann

| Bereich | Umfang |
|---|---|
| Abonnieren | Suche nach Name, Anbieter oder Thema bei Apple Podcasts und Podcast Index zugleich, dazu ein Katalog mit den Charts von Apple Podcasts für die Region des Geräts, Apples 19 Rubriken als Kategorien und einer Seite je Podcast mit Cover, Beschreibung und neuesten Folgen, Links aus Apple Podcasts, Podcast-Feeds, Webseiten mit Feed, einzelne MP3-Links, YouTube-Kanäle über ihren Feed oder einen @-Link; zu YouTube-Kanälen findet die App den passenden Audio-Podcast. Abos aus anderen Apps kommen per OPML-Datei herüber und lassen sich als OPML exportieren |
| Hören | Tempo, ±15/30 Sekunden, Kapitel aus dem Feed, Schlaf-Timer, AirPlay, Sperrbildschirm, Warteschlange, Fortsetzung über Geräte hinweg |
| Transkript | auf dem Gerät mit Apples Spracherkennung, mit Zeitmarken, durchsuchbar, Tipp springt an die Stelle; fremdsprachige Folgen lassen sich auf dem Gerät übersetzen; YouTube-Videos bekommen ihr Transkript aus den vorhandenen Untertiteln, wenn du einen eigenen Supadata-Schlüssel einträgst, sonst aus dem passenden Audio-Podcast; mit dem Schlüssel gehen auch einzelne Beiträge von TikTok, Instagram, X und Facebook |
| Fakten | Aussagen je Folge, jede mit Zeitmarke auf dem Satz und dem Wortlaut; sie entstehen von selbst im Hintergrund |
| Chat | Fragen an eine Folge oder an alle Folgen mit Transkript, eingrenzbar auf einen Podcast und die letzten 7 oder 30 Tage; jeder Beleg nennt Podcast, Folge und Zeitmarke und spielt auf Wunsch ab; jede Antwort lässt sich sichern |
| Themen-Updates | eine eigene Folge je Thema mit Kapiteln, Shownotes und Cover, gebaut aus Originalstellen |
| Gemerkte Stellen | „Moment merken“ im Player mit eigenem Kommentar, dazu Merken im Transkript, bei Fakten und im Chat; Notizen bleiben, auch wenn die Folge gelöscht wird |
| Export | Folge mit Shownotes, Kapiteln, Fakten und Transkript; Chat-Antworten mit Belegen; gemerkte Stellen |
| Abgleich | über deine private iCloud-Datenbank zwischen iPhone, iPad und Mac |
| Speicher | die neueste Folge je Podcast bleibt für unterwegs auf dem Gerät, die anderen spielen nach dem Transkript aus dem Netz; „Laden (offline)“ holt nur den Ton und lässt ihn liegen, bis du „Audio entfernen“ wählst; „Audio entfernen“ löscht nur den Ton, alle Daten bleiben; „Folge löschen“ löscht die Folge mit allen Daten; einen Tag nach dem Hören räumt die App den Ton von selbst weg |

Für die neuesten Folgen jedes Podcasts erstellt die App das Transkript von selbst, im WLAN und für die gewählte Zahl Folgen. Das lässt sich in den Einstellungen abschalten, ebenso die Regel mit dem WLAN. Mit „Ältere Folgen auch vorbereiten“ in der Folgenliste eines Podcasts kommt dessen ganzes Archiv dazu. Liegt der Ton schon auf dem Gerät, entsteht das Transkript auch ohne Netz.

## Apple Intelligence

Alles läuft mit Apple Intelligence. Antworten und Vergleiche nutzen Private Cloud Compute, wenn Gerät und App es dürfen; dort passen mehr Stellen in eine Antwort. Fakten und Relevanz entstehen auf dem Gerät. Satz und Tags je Kapitel auch, nur wenn das Gerätemodell fehlt oder für die Tags zu langsam ist, springt Private Cloud Compute ein. Ein anderer KI-Anbieter kommt nicht zum Einsatz. Ohne Apple Intelligence zeigt die App die passendsten Stellen im Wortlaut, statt etwas zu formulieren.

## Datenschutz

Transkription und Suche laufen auf dem Gerät. Private Cloud Compute verarbeitet Anfragen, ohne sie zu speichern, und ist in den Einstellungen abschaltbar. Deine Daten liegen in deiner privaten iCloud-Datenbank. Es gibt kein Konto bei uns, und du brauchst keinen eigenen API-Schlüssel. Nur für Transkripte von YouTube-Videos kannst du einen eigenen Schlüssel von Supadata (supadata.ai) eintragen, einem unabhängigen Dienst; dann gehen die Links der Videos und Beiträge dorthin, um Untertitel und Metadaten abzurufen, sonst nichts, und der Schlüssel bleibt im Schlüsselbund des Geräts. Charts und Kategorien kommen von Apple Podcasts, gesucht wird bei Apple und bei Podcast Index (podcastindex.org). Beide sehen dabei Suchbegriff und IP-Adresse. Eine Empfehlung startet nie von selbst Ton.

## Voraussetzungen

| Plattform | Mindestversion |
|---|---|
| iPhone und iPad | iOS 27 oder neuer |
| Mac | macOS 27 oder neuer |

Transkription braucht Apples Spracherkennung auf dem Gerät. Fragen, Fakten und Relevanz brauchen ein Gerät mit Apple Intelligence.

## Testen über TestFlight

Interne Builds für iOS und macOS laufen über TestFlight im Team Mobile Box. Die Apps heißen „PodcastAI“ und „PodcastAI Mac“, die Testgruppe „Intern“ verteilt neue Builds automatisch.

## Mehr

- [Änderungen je Version](CHANGELOG.md)
- [Selbst bauen und testen](app/README.md)
- [Architektur, Abgleich und Löschregeln](docs/architektur.md)
- [Recherche mit Quellen](docs/recherche.md)
- [Funktionsstand und Bekanntes](app/STATUS.md)
