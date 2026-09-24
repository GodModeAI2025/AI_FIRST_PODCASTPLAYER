# Änderungsverlauf

## App 0.9 · 2026-09-24
Das Fundament aus dem Plan zur Vereinfachung:
- Metadaten aus der Quelle: Jede Folge zeigt Podcast, Autor, Datum, Dauer, Staffel und Folge, Rubriken und Link, jeder Podcast Beschreibung, Rubriken, Sprache und Website. Beim Aktualisieren kommen sie neu.
- Kapitel: Kapiteldateien bleiben gespeichert, Zeitmarken aus Shownotes und YouTube-Beschreibungen werden zu Kapiteln. Transkripte, die der Podcast selbst mitliefert, nutzt die App zuerst.
- Folge nach Kapiteln: Jedes Kapitel zeigt einen Satz, worum es geht, seine Fakten und ein Stück Transkript. Ohne Kapitel bildet die App Abschnitte. Fakten decken jetzt jedes Kapitel ab.
- „Original öffnen“ an Kapiteln der Themen-Updates, im Player und an Belegen im Chat.
- Fortsetzen: Transkripte und Fakten machen nach einem Abbruch dort weiter, wo sie standen, die Warteschlange übersteht einen Neustart. Pausiert iOS die Arbeit im Hintergrund, sagt eine Mitteilung das.
- Einzelne Folgen: „Nur diese Folge“ im Katalog, in der Vorschau und für Folgenlinks aus Apple Podcasts und von Hostern. Einzelne Folgen stehen unter ihrem Podcast als „nicht abonniert“ und lassen sich später abonnieren.
- YouTube: Jeder Link, ob Video, Shorts, Live, @-Name oder Playlist, führt zu einer Vorschau mit „Kanal abonnieren“, „Nur dieses Video“ und dem passenden Audio-Podcast. Playlists sind eigene Quellen.
- Supadata mit eigenem Schlüssel (Einstellungen): Untertitel von YouTube-Videos werden zum Transkript mit Fakten, Kapiteln und Chat, dazu fehlende Metadaten, die Suche nach YouTube-Kanälen und ältere Videos. Einzelne Beiträge aus TikTok und Instagram lassen sich hinzufügen. Supadata ist ein eigener Dienst, der Schlüssel bleibt im Schlüsselbund des Geräts.

## App 0.8 · 2026-09-24
Der Chat, nach den Neuerungen der WWDC26:
- Antworten entstehen sichtbar: der Text erscheint, während Apple Intelligence schreibt, und „Abbrechen“ hält die Frage an, ohne Fehlermeldung.
- Das Modell bekommt so viele Stellen, wie wirklich in sein Fenster passen, gezählt nach Token statt geschätzt. Auf dem Gerät sind das oft mehr als bisher.
- Sind die Apple-Server für heute ausgeschöpft oder ausgelastet, sagt die Antwort das und nennt, ab wann es wieder geht.
- Im Chat einer Folge kennt die Frage die Stelle im Player: „Was wurde gerade gesagt?“ antwortet mit den Passagen kurz davor.
- Unter jeder Antwort: „Gegenpositionen prüfen“ mit dem Kernsatz als These, und je Folge „Mehr aus dieser Folge“.
- Gesicherte Antworten zeigen Verweise wie der Chat. VoiceOver liest eine Antwort am Stück, Belege lassen sich per Aktion abspielen, merken und übersetzen. Belege zeigen „34:10 von 58:00“.
- Antworten lassen sich aus dem Verlauf entfernen, gesicherte Fassungen bleiben.

## App 0.7.3 · 2026-09-24
- Podcast-Katalog in „Podcast hinzufügen“, ohne Konto und ohne Schlüssel: „Angesagt“ zeigt die Apple-Charts deines Landes, 19 Kategorien mit Symbol öffnen die Charts ihres Genres, jede Seite mit Cover, Beschreibung, den neuesten Folgen und „Abonnieren“. Die Suche fragt Apple und Podcast Index zugleich und zeigt jeden Podcast einmal, so finden sich auch Podcasts, die nicht bei Apple stehen. Aus dem Katalog spielt nichts ab.

## App 0.7.2 · 2026-09-23
Aus dem TestFlight-Feedback zu 0.6, 0.7 und 0.7.1, jede Änderung von zwei Prüfern gegengelesen und nachgebessert:
- Erwähnt: Jede Folge zeigt im Überblick, welche Links, Termine, Adressen, Telefonnummern, E-Mail-Adressen, Personen, Organisationen und Orte in Shownotes und Transkript vorkommen, mit Zeitmarke zum Nachhören. Links öffnen im Browser, Adressen in Karten, Termine landen im Kalender. Im Chat fragst du „Welche Links werden genannt?“ für eine Folge oder über alle, auch ohne Apple Intelligence.
- Ton auf dem Gerät: Die neueste Folge jedes Podcasts bleibt zum Hören unterwegs auf dem Gerät. Alle anderen verlieren den Ton nach dem Transkript und laufen als Stream, außer du hast sie mit „Laden (offline)“ geholt. Eine Folge, deren Ton schon auf dem Gerät liegt, wartet für ihr Transkript nicht mehr aufs WLAN. In einer wartenden Folge gibt es „Jetzt erstellen“ und den Schalter für Mobilfunk direkt dort. Die beiden Netzregeln stehen in den Einstellungen unter Mobilfunk zusammen.
- Ältere Folgen: Im Podcast selbst bereitet „Ältere Folgen auch vorbereiten“ das ganze Archiv vor, neueste zuerst, nach einer Rückfrage mit Anzahl und Größe. Was du selbst anforderst, läuft vor diesem Archiv.
- Cover: Themen-Updates bekommen ein Bild aus Image Playground, abstrakt und ohne Schrift, aus ihren Themen. „Neues Cover erzeugen“ macht ein anderes. Ohne Image Playground bleibt ein ruhiges Layoutcover, dessen Titel nicht mehr mitten im Wort bricht.
- Player: Oben steht groß das Cover des Themen-Updates oder des Podcasts, darunter klein die Quelle der laufenden Stelle mit Podcast, Folge, Zeitbereich und „Stelle x von y“.
- Interessen sind nur noch Themen. Die Wahl zwischen Thema, Vorhaben und Frage ist weg, vorhandene Vorhaben und Fragen werden zu Themen.
- Themen-Updates schneiden an Kapiteln: Liegt eine Stelle in einem Kapitel bis zehn Minuten, das ins Zeitbudget passt, kommt das ganze Kapitel. Stellen einer Folge laufen am Stück und in der Reihenfolge des Originals.
- Chat: Die Antwort beginnt mit dem Kern in kräftiger Schrift, danach Punkte. Jeder Verweis wie [4] springt zum Beleg. Belege stehen je Folge in einer Karte mit Cover, Titel und Datum.
- Hilfe: zehn Themenkarten statt einer langen Liste, mit Stufen von Einsteiger bis Experte, Suche und „Zeig es mir“, das an die passende Stelle der App springt.
- „Kurz gesagt“ zeigt höchstens zehn Schlagworte, die umbrechen statt seitlich zu scrollen, deine Themen zuerst.
- Kein Orange mehr: Hinweise sind grau mit „i“ und erklären auf Tipp mehr. Rot bleibt für echte Störungen.
- Fakten tragen keine Reste wie „3 |“ oder Listenstriche mehr.
- Voraussetzung ist jetzt iOS 27 und macOS 27. Der Code für ältere Systeme ist entfernt, Unterbrechungen durch Anrufe und Siri laufen über die neuen Meldungen der Audiositzung.

## App 0.7.1 · 2026-09-23
- Private Cloud Compute ist freigegeben. Apple hat den Zugang für das Team erteilt, die App fragt Apples Server jetzt für Antworten im Chat, Überblicke und Gegenpositionen. Dort passt mehr Text in eine Anfrage. Abschaltbar unter Einstellungen › Intelligenz. Fakten und Relevanz entstehen weiter auf dem Gerät.

## App 0.7 · 2026-09-23
Aus dem TestFlight-Feedback, einem Test mit 50 Personas, einer Runde mit 10 Personas, die die App im Simulator selbst bedient haben, einem Begriffstest mit 12 Personas und einer Prüfung jedes Bedienelements:
- Podcast finden: Das Blatt „Podcast hinzufügen“ sucht im Apple-Podcast-Verzeichnis nach Name, Anbieter oder Thema und abonniert mit einem Tipp. Links aus Apple Podcasts funktionieren, YouTube-Links mit @-Namen auch. Bei Spotify-Links sagt die App, warum es nicht geht. Abos lassen sich als OPML-Datei übernehmen und sichern. Die Einführung beginnt mit der Suche.
- Begriffe, die Einsteiger verstehen: „Transkript erstellen“ und „Transkript fertig“ statt „erschließen“, Reiter „Meine Podcasts“, „Themen-Updates“ und „Chat“ mit Sprechblase statt Lupe, „Gesicherte Antworten“ statt „Wissenslandkarten“. Die Hilfe hat ein kleines Glossar.
- Englisch: Die ganze Oberfläche gibt es auf Englisch, samt Siri-Kurzbefehlen.
- Deine Sprache: Was Apple Intelligence neu formuliert, Fakten, Antworten und Zusammenfassungen, kommt in der Sprache der App, auch bei Podcasts in einer anderen Sprache. Zitate bleiben im Original. Transkripte und Shownotes fremdsprachiger Folgen lassen sich auf dem Gerät übersetzen.
- Fakten von selbst: Nach jedem Transkript sammelt die App die Fakten im Hintergrund, holt fehlende nach und versucht es erneut, sobald Apple Intelligence bereit ist.
- Einstellungen, Hilfe und Datenschutz sind über das Zahnrad oben in „Für dich“ und „Meine Podcasts“ erreichbar. Ein eigener Schalter regelt, ob Abspielen und Laden über Mobilfunk dürfen; ist er aus, fragt die App vorher.
- Vor dem Abonnieren zeigt ein Tipp auf den Treffer Beschreibung und neueste Folgen. Abonnieren bricht nach einer Weile mit einer klaren Meldung ab, statt ewig zu warten, und große Feeds mit Hunderten Folgen gehen jetzt. Laden zeigt Fortschritt und Größe.
- Große Schrift: Der Player bricht die Knopfreihe um, Tempo und Schlaf-Timer öffnen ein Blatt, nichts läuft mehr über den Rand. VoiceOver kennt Namen für Regler und Symbolknöpfe.
- Export: eine echte Markdown-Datei mit Angaben zu Folge, Podcast, Datum und Link, samt deinen Notizen.
- Rechtschreibung mit ß.
- Moment merken: Im Player hält „Moment merken“ die Stelle mit Zitat, Zeitmarke und eigenem Kommentar fest. Merken geht auch im Transkript, bei Fakten, in Chat-Antworten und auf den Karten in „Für dich“. Notizen bleiben, wenn die Folge gelöscht wird.
- Für dich: Weiterhören nach einem Neustart, neue Folgen aus den Abos, Treffer nach Thema gruppiert, mit Datum und „Nicht relevant“. Themen treffen ganze Wörter statt Wortteile („KI“ findet keine Kinder mehr) und haben eigene Stichworte mit Vorschlägen.
- Speicher und unterwegs: „Laden (offline)“ holt nur den Ton. Nach dem Transkript und einen Tag nach dem Hören räumt die App den Ton von selbst weg, beides abschaltbar. Transkripte für neue Folgen entstehen nur im WLAN, für die gewählte Zahl neuester Folgen je Podcast. Im Hotspot oder Datensparmodus sagt die App, worauf sie wartet.
- Ältere Folgen: Die Folgenliste hat eine Suche über Titel und Shownotes, Filter, Sortierung und eine Auswahl, für die man auf einmal Transkripte erstellen lässt.
- Chat: Jeder Beleg nennt Podcast und Folge. Fragen lassen sich auf einen Podcast und einen Zeitraum eingrenzen. Antworten lassen sich sichern und später wieder öffnen.
- Themen-Updates: neue Ausgabe auf Knopfdruck, frühere Ausgaben, bearbeiten und löschen. Automatische Ausgaben entstehen jetzt wirklich, auf dem iPhone auch im Hintergrund.
- Player: Die Warteschlange hat einen Abspielknopf und setzt dort fort, wo man war. „Als Nächstes“ reiht vorne ein. Das Tempo bleibt gespeichert. Folgen ohne Ton öffnen YouTube.
- Fakten: Die Zeitmarke zeigt auf den Satz, der Wortlaut lässt sich einblenden, und Fakten tragen kein Prüfsiegel mehr, weil sie gesagt und nicht geprüft sind. Gegenpositionen durchsuchen den ganzen Bestand und sagen ehrlich, wenn etwas nicht eingeordnet werden konnte.
- Stabilität: Unter iOS 27 beendete eine Frage an Apple Intelligence die App, weil der Zugang zu Private Cloud Compute noch nicht freigegeben ist. Bis zur Freigabe antwortet das Gerätemodell.
- Mac: Der Agentenzugang (MCP) startet über `--mcp`. Die Seitenleiste zeigt, was läuft. Mehrere Fenster doppeln keine Meldungen mehr.
- Rechtliches: Impressum, Datenschutzerklärung, eine Seite „Datenschutz in PodcastAI“ und Verweise auf Apples eigene Erklärungen.

## App 0.6.1 · 2026-09-23
Nach einer gründlichen Prüfung von 0.6 mit 60 gemeldeten und 22 nachträglich gefundenen Fehlern, alle behoben und einzeln nachgeprüft:
- Abgleich: Legen zwei Geräte dieselbe Quelle oder Folge an, bevor iCloud abgeglichen hat, werden die Doppelten jetzt zusammengeführt statt gelöscht. Vorher konnte dabei das Transkript des anderen Geräts verloren gehen. Der Hörstand liegt je Gerät in einer eigenen Zeile und wird beim Lesen vereinigt, damit gleichzeitiges Hören auf zwei Geräten nichts überschreibt.
- Fortsetzen: Die Stelle, an der eine Folge weitergeht, blieb nach den ersten Sekunden stehen und wurde auch vom Anhören einzelner Stellen verstellt. Beides ist behoben, die Stelle reist über iCloud mit.
- Löschen: Eine gelöschte Folge kommt nicht mehr zurück, auch nicht, wenn sie gerade erschlossen wurde oder auf einem anderen Gerät noch in der Warteschlange stand. Aus dem Player gemerkte Stellen gehen mit ihrer Folge.
- Private Cloud Compute: Scheitert PCC, beantwortet das Gerätemodell die Frage mit einer passend kleinen Auswahl. Fragen über die Mediathek selbst erreichen das Modell. Verweise wie [3, 5] werden erkannt.
- Fakten: laufen auf dem Gerät in passenden Portionen, tragen die richtige Herkunft und melden, wenn Apple Intelligence fehlt.
- Player: Es besitzt immer nur ein Player den Sperrbildschirm. Der Schlaf-Timer am Kapitelende funktioniert auch im letzten Kapitel und hält die nächste Folge an. Systempausen durch Anrufe oder gezogene Kopfhörer werden erkannt. Hängt die Wiedergabe, wechselt die App nach zehn Sekunden auf den Stream oder sagt, was los ist.
- YouTube: Fällt der Feed-Dienst von YouTube aus, wird der Kanal trotzdem angelegt und der passende Audio-Podcast angeboten.
- iPhone: Die Statuszeile verdeckt keine Knöpfe mehr.

## App 0.6 · 2026-09-22
- Abgleich über iCloud: Abos, Folgen, Transkripte, Belege, Fakten, Hörstand mit Fortsetzungsstelle, Interessen, Themen-Updates und gemerkte Stellen gleichen sich zwischen iPhone, iPad und Mac ab. Audiodateien lädt jedes Gerät selbst. Ein Speicher aus einer früheren Testversion wird beim ersten Start beiseitegelegt und neu angelegt.
- Löschen: „Audio entfernen“ löscht nur den Ton, Transkript, Fakten und Hörstand bleiben, gespielt wird dann aus dem Netz. „Folge löschen“ entfernt die Folge mit allem, was aus ihr entstanden ist, und der Feed legt sie nicht wieder an. Quellen lassen sich abbestellen.
- Folgen haben Reiter: Überblick, Kapitel, Transkript mit Suche und Sprung an jede Stelle, Fakten mit Zeitmarke, Fragen an genau diese Folge.
- Fragen: Antworten sind jetzt Fließtext mit nummerierten Belegen, die an die Stelle springen. Die Suche nutzt Stichworte und die semantische Nähe aus Apples NaturalLanguage. Auch Fragen über die Mediathek selbst („Welche Folgen habe ich noch nicht gehört?“) finden eine Antwort. Vorschlagsfragen helfen beim Einstieg.
- Private Cloud Compute: Antworten und Vergleiche laufen auf Apples Servermodell mit größerem Kontext, sobald die Berechtigung vorliegt. Sonst und bei fehlendem Netz antwortet das Gerätemodell. Abschaltbar in den Einstellungen.
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
- Neue Oberfläche: große Cover, Glas-Bedienelemente im Player und in der Folge, Karten in „Für dich“, Cover in Mediathek und Folgenliste, hervorgehobenes laufendes Kapitel.

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
- Direkte Audio-Links, etwa MP3-Downloads von Podigee, werden als Einzelfolge angelegt und lassen sich erschließen. Vorher suchte die App darin nach einem Feed und brach an der 12-MB-Grenze ab.
- Liegt unter einer Feed-Adresse kein Feed, sucht die App auf der Seite und auf der Startseite nach dem verlinkten Feed. `think-ai.podigee.io/rssfeed` führt so zu `/feed/mp3`.
- Zu YouTube-Kanälen sucht die App im Apple-Podcast-Verzeichnis nach dem Audio-Podcast desselben Anbieters und bietet das Abo an. Dessen Folgen lassen sich transkribieren. Das Audio der YouTube-Videos selbst lädt die App weiterhin nicht.
- Themen lassen sich direkt beim Anlegen eines Themen-Updates erstellen. „Für dich“ führt ohne Umweg zu den Interessen.

## App 0.1 · 2026-09-22
- iOS- und macOS-App bauen mit Xcode 27 und starten ohne Absturz.
- Erschließen einer Folge funktioniert Ende zu Ende: Download, Transkription in der Feedsprache, Belege mit Zeitmarken.
- App-Icon, Privacy-Manifest und Signierung für TestFlight im Team Mobile Box.
- UI-Test für den Hauptweg und Ende-zu-Ende-Test für die Transkription.
- Behobene Fehler stehen in [app/STATUS.md](app/STATUS.md).
