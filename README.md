# PodcastAI

Ein Podcast-Player für iPhone, iPad und Mac, der zuhört. Er spielt deine Podcasts wie jeder gute Player, schreibt jede Folge auf dem Gerät mit Zeitmarken mit und macht daraus Wissen, das du befragen, nachlesen und exportieren kannst. Jede Aussage führt zurück zur Stelle im Originalton.

## Für wen

**Einsteiger** abonnieren Podcasts und hören sie. Kapitel, Shownotes, Cover, Tempo, Schlaf-Timer, AirPlay und eine Warteschlange sind da, wo man sie erwartet. Die App merkt sich, wo du warst, auch wenn du vom iPhone zum Mac wechselst.

**Fortgeschrittene** lesen das Transkript mit, springen per Tipp an jede Stelle, sehen die wichtigsten Fakten einer Folge und stellen Fragen an eine Folge oder an alle zusammen. „Für dich“ zeigt die Stellen, die zu deinen Interessen passen.

**Experten** lassen sich je Thema eine eigene Folge aus ungehörten Originalstellen mehrerer Podcasts bauen, prüfen Thesen gegen belegte Gegenstimmen und exportieren Folgen, Antworten und Notizen als Markdown, etwa nach Obsidian oder Notion. Auf dem Mac dürfen andere Programme nach Freigabe lesend auf das Wissen zugreifen.

## Was die App kann

| Bereich | Umfang |
|---|---|
| Abonnieren | Podcast-Feeds, Webseiten mit Feed, einzelne MP3-Links, YouTube-Kanäle über ihren Feed; zu YouTube-Kanälen findet die App den passenden Audio-Podcast |
| Hören | Tempo, ±15/30 Sekunden, Kapitel aus dem Feed, Schlaf-Timer, AirPlay, Sperrbildschirm, Warteschlange, Fortsetzung über Geräte hinweg |
| Transkript | auf dem Gerät mit Apples Spracherkennung, mit Zeitmarken, durchsuchbar, Tipp springt an die Stelle |
| Fakten | überprüfbare Aussagen je Folge, jede mit Zeitmarke |
| Fragen | an eine Folge oder an alle ausgewerteten Folgen, eingrenzbar auf einen Podcast und die letzten 7 oder 30 Tage; jeder Beleg nennt Podcast, Folge und Zeitmarke und spielt auf Wunsch ab; jede Antwort lässt sich als Wissenslandkarte sichern |
| Themen-Updates | eine eigene Folge je Thema mit Kapiteln, Shownotes und Cover, gebaut aus Originalstellen |
| Export | Folge mit Shownotes, Kapiteln, Fakten und Transkript; Chat-Antworten mit Belegen; gemerkte Stellen |
| Abgleich | über deine private iCloud-Datenbank zwischen iPhone, iPad und Mac |
| Speicher | „Audio entfernen“ löscht nur den Ton, alle Daten bleiben; „Folge löschen“ löscht die Folge mit allen Daten |

Die jüngsten Folgen jeder Quelle bereitet die App von selbst vor. Das lässt sich in den Einstellungen abschalten.

## Apple Intelligence

Alles läuft mit Apple Intelligence. Antworten und Vergleiche nutzen Private Cloud Compute, wenn Gerät und App es dürfen; dort passen mehr Stellen in eine Antwort. Fakten und Relevanz entstehen auf dem Gerät. Ein anderer KI-Anbieter kommt nicht zum Einsatz. Ohne Apple Intelligence zeigt die App die passendsten Stellen im Wortlaut, statt etwas zu formulieren.

## Datenschutz

Transkription und Suche laufen auf dem Gerät. Private Cloud Compute verarbeitet Anfragen, ohne sie zu speichern, und ist in den Einstellungen abschaltbar. Deine Daten liegen in deiner privaten iCloud-Datenbank. Es gibt kein Konto bei uns und keinen API-Schlüssel. Eine Empfehlung startet nie von selbst Ton.

## Voraussetzungen

| Plattform | Mindestversion |
|---|---|
| iPhone und iPad | iOS 26, Private Cloud Compute ab iOS 27 |
| Mac | macOS 26, Private Cloud Compute ab macOS 27 |

Transkription braucht Apples Spracherkennung auf dem Gerät. Fragen, Fakten und Relevanz brauchen ein Gerät mit Apple Intelligence.

## Testen über TestFlight

Interne Builds für iOS und macOS laufen über TestFlight im Team Mobile Box. Die Apps heissen „PodcastAI“ und „PodcastAI Mac“, die Testgruppe „Intern“ verteilt neue Builds automatisch.

## Mehr

- [Änderungen je Version](CHANGELOG.md)
- [Selbst bauen und testen](app/README.md)
- [Architektur, Abgleich und Löschregeln](docs/architektur.md)
- [Recherche mit Quellen](docs/recherche.md)
- [Funktionsstand und Bekanntes](app/STATUS.md)
