# Änderungsverlauf

## App 0.6 · 2026-09-22
- Abgleich über iCloud: Abos, Folgen, Transkripte, Belege, Fakten, Hörstand mit Fortsetzungsstelle, Interessen, Themen-Updates und gemerkte Stellen gleichen sich zwischen iPhone, iPad und Mac ab. Audiodateien lädt jedes Gerät selbst. Ein Speicher aus einer früheren Testversion wird beim ersten Start beiseitegelegt und neu angelegt.
- Löschen: „Audio entfernen“ löscht nur den Ton, Transkript, Fakten und Hörstand bleiben, gespielt wird dann aus dem Netz. „Folge löschen“ entfernt die Folge mit allem, was aus ihr entstanden ist, und der Feed legt sie nicht wieder an. Quellen lassen sich abbestellen.
- Folgen haben Reiter: Überblick, Kapitel, Transkript mit Suche und Sprung an jede Stelle, Fakten mit Zeitmarke, Fragen an genau diese Folge.
- Fragen: Antworten sind jetzt Fliesstext mit nummerierten Belegen, die an die Stelle springen. Die Suche nutzt Stichworte und die semantische Nähe aus Apples NaturalLanguage. Auch Fragen über die Mediathek selbst („Welche Folgen habe ich noch nicht gehört?“) finden eine Antwort. Vorschlagsfragen helfen beim Einstieg.
- Private Cloud Compute: Antworten und Vergleiche laufen auf Apples Servermodell mit grösserem Kontext, sobald die Berechtigung vorliegt. Sonst und bei fehlendem Netz antwortet das Gerätemodell. Abschaltbar in den Einstellungen.
- Export: jede Folge mit Shownotes, Kapiteln, Fakten und Transkript als Markdown, jede Antwort mit ihren Belegen.
- Player: Schlaf-Timer (Minuten, Kapitelende, Folgenende), AirPlay-Auswahl. Die Warteschlange bleibt über einen Neustart erhalten.
- Einstieg: Willkommensblatt beim ersten Start mit zwei Beispiel-Podcasts, Hilfeseite „So funktioniert's“ für Einsteiger, Fortgeschrittene und Experten.
- Einstellungen: Private Cloud Compute, Speicher mit „Alle Audiodateien entfernen“, Stand der Synchronisation.

## App 0.5 · 2026-09-22
Aus dem Feedback zu 0.4:
- Die App bereitet die jüngsten Folgen jeder Quelle von selbst vor: laden, transkribieren mit Zeitmarken, Belege bilden. Vorher passierte das nur auf ausdrückliche Anforderung, und „Für dich“, die Suche und die Themen-Updates blieben deshalb leer. Abschaltbar in den Einstellungen unter „Vorbereiten“.
- Erschlossene Folgen werden nach einem Neustart wiedererkannt. Bisher sah nach jedem Start alles unbearbeitet aus.
- „Anlegen“ beim Themen-Update ist nicht mehr grundlos gesperrt. Themen sind vorausgewählt, ein eingetipptes Thema zählt mit, und ohne Namen entsteht einer aus den Themen.
- Abspielen beginnt dort, wo man aufgehört hat. Die Stelle wird je Folge gemerkt, und der Sprung wartet, bis die Folge bereit ist. Vorher startete die Wiedergabe irgendwo.
- Beim Wechsel auf eine andere Folge wird keine Hörzeit mehr auf die neue Folge gebucht.
- Fehler beim automatischen Vorbereiten unterbrechen niemanden mehr. Kann ein Gerät gar nicht transkribieren, hört die App von selbst auf, Folgen dafür zu laden, und sagt das in der Warteschlange.
- Neue Oberfläche: grosse Cover, Glas-Bedienelemente im Player und in der Folge, Karten in „Für dich“, Cover in Mediathek und Folgenliste, hervorgehobenes laufendes Kapitel.

## App 0.4 · 2026-09-22
Aus dem Feedback zu 0.3:
- Kein Ton bei erschlossenen Folgen behoben. Geladene Folgen liegen ohne Dateiendung auf dem Gerät, und AVFoundation konnte sie deshalb nicht öffnen. Der Player zeigte trotzdem „läuft“. Die App erkennt das Format jetzt am Dateianfang. Das betraf auch das Abspielen einzelner Stellen aus „Für dich“.
- Lässt sich eine geladene Datei trotzdem nicht öffnen, spielt der Player die Folge aus dem Stream weiter.
- Die Zeitanzeige springt beim Wechsel zwischen Kapiteln nicht mehr hin und her.
- Der Player zeigt, wenn er noch lädt oder eine Folge nicht abspielen kann, statt stumm „läuft“ anzuzeigen.

## App 0.3 · 2026-09-22
Aus dem zweiten TestFlight-Feedback:
- Feeds von Transistor wie `feeds.transistor.fm/ai-to-the-dna` lassen sich abonnieren. Die App hielt sie für Webseiten, weil sie mit einer Stylesheet-Anweisung beginnen.
- Ganze Folgen hören: jede Folge hat eine eigene Ansicht mit Cover, Shownotes, Kapiteln und den erschlossenen Stellen. Kapitel kommen aus dem Feed (Podlove) oder aus der Kapiteldatei nach Podcasting 2.0. Der Player kann springen, Kapitel wechseln und die Geschwindigkeit ändern, auch vom Sperrbildschirm aus.
- Aus „Für dich“ springt ein Tippen in die ganze Folge an genau diese Stelle. Gedrückt halten spielt nur die Stelle. Folge, Kapitel und Stellen zeigen, was schon gehört ist.
- Neue Warteschlange in der Mediathek und auf dem Mac in der Seitenleiste: was läuft, was als Nächstes gehört wird, was gerade und demnächst erschlossen wird. Die Aktivitätsanzeige oben öffnet sie.
- Erschlossen wird immer eine Folge nach der anderen. Das behebt „Maximum number of recognizers“, das bei mehreren gleichzeitig gestarteten Folgen kam. Auf dem iPhone läuft die Arbeit im Hintergrund weiter, mit Fortschrittsanzeige des Systems.
- Fehlermeldungen sagen, was passiert ist und was man tun kann, statt technische Codes zu zeigen.
- Feeds aktualisieren sich beim Start, bei der Rückkehr in die App und alle 30 Minuten. Ziehen zum Aktualisieren gibt es weiterhin.
- Bei den Interessen steht, wofür Thema, aktuelles Vorhaben und offene Frage jeweils gedacht sind.

## App 0.2 · 2026-09-22
Aus dem ersten TestFlight-Feedback:
- Direkte Audio-Links, etwa MP3-Downloads von Podigee, werden als Einzelfolge angelegt und lassen sich erschliessen. Vorher suchte die App darin nach einem Feed und brach an der 12-MB-Grenze ab.
- Liegt unter einer Feed-Adresse kein Feed, sucht die App auf der Seite und auf der Startseite nach dem verlinkten Feed. `think-ai.podigee.io/rssfeed` führt so zu `/feed/mp3`.
- Zu YouTube-Kanälen sucht die App im Apple-Podcast-Verzeichnis nach dem Audio-Podcast desselben Anbieters und bietet das Abo an. Dessen Folgen lassen sich transkribieren. Das Audio der YouTube-Videos selbst lädt die App weiterhin nicht.
- Themen lassen sich direkt beim Anlegen eines Themen-Updates erstellen. „Für dich“ führt ohne Umweg zu den Interessen.

## App 0.1 · 2026-09-22
- iOS- und macOS-App bauen mit Xcode 27 und starten ohne Absturz.
- Erschliessen einer Folge funktioniert Ende zu Ende: Download, Transkription in der Feedsprache, Belege mit Zeitmarken.
- App-Icon, Privacy-Manifest und Signierung für TestFlight im Team Mobile Box.
- UI-Test für den Hauptweg und Ende-zu-Ende-Test für die Transkription.
- Behobene Fehler stehen in [app/STATUS.md](app/STATUS.md).
