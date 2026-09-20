# BrainSpeak Podcasts
## Produktkonzept für einen AI-First-Podcast-Player

**Stand:** 19. September 2026  
**Status:** recherchierter Produkt- und UX-Entwurf, keine implementierte oder getestete Anwendung  
**Arbeitsname:** BrainSpeak Podcasts  
**Hauptbasis:** BrainSpeak, wie vom Auftraggeber vorgegeben  
**Ergänzende Referenz:** YourPods für klassische Podcast-Funktionen  
**Entwurfsannahme:** iPhone als primärer Einstieg; gemeinsamer Wissenskern für iPad und Mac. Plattformumfang und Distribution sind noch keine festgelegten Produktentscheidungen.

> Ein Podcast muss nicht gehört werden, um nützlich zu werden. Die App erschließt abonnierte Inhalte, zeigt ihre persönliche Relevanz und macht Aussagen über Quellen und Zeitmarken nachvollziehbar.

## 1. Das eigentliche Produkt

BrainSpeak Podcasts ist kein gewöhnlicher Podcast-Player mit einem zusätzlichen Chat-Button. Es ist ein persönlicher Wissenseingang mit vollwertiger Wiedergabe.

Die App verfolgt Podcasts und YouTube-Kanäle, nimmt einzelne Folgen ohne Abonnement auf und verarbeitet zugängliche, zur Nutzung berechtigte Medien beziehungsweise Transkripte. Daraus entstehen durchsuchbare Aussagen, Kapitelzusammenfassungen, thematische Verbindungen und Antworten mit Quellenbezug. Apple Intelligence übernimmt die lokale Verarbeitung; Private Cloud Compute ist für anspruchsvollere Synthesen vorgesehen, sofern die Voraussetzungen erfüllt sind.

Die zentrale Frage auf der Startseite lautet nicht: „Was wurde neu veröffentlicht?“, sondern: „Was davon hilft mir gerade weiter?“

Ein Nutzer kann eine Folge vollständig hören, nur eine relevante Passage hören, die Erkenntnisse lesen, Fragen stellen oder Ergebnisse in Markdown exportieren. Keine dieser Nutzungsarten setzt voraus, dass die Folge zuvor abgespielt wurde.

### Drei Ebenen, die nicht vermischt werden dürfen

**Medienebene:** Sendungen, Kanäle, Folgen, Downloads, Wiedergabe, Kapitel und Hörfortschritt.

**Wissensebene:** Transkripte, belegte Aussagen, Zusammenfassungen, Vergleiche, offene Fragen und eigene Notizen.

**Interessenebene:** vom Nutzer bestätigte Themen, aktuelle Vorhaben, Rückmeldungen und vorsichtig abgeleitete Präferenzen.

Eine Folge kann ungehört und vollständig analysiert sein. Eine Zusammenfassung kann gelesen sein, ohne dass ihr Inhalt vom Nutzer verstanden, akzeptiert oder als wahr bestätigt wurde. Diese Unterschiede sind Bestandteil des Datenmodells und der Oberfläche.

## 2. Recherche und belastbarer Ausgangspunkt

### 2.1 YourPods: geeignete Referenz für das Player-Handwerk

Gelesen wurden die README, der Spezifikations-Tracker, die Lizenzhinweise sowie relevante Teile von `TranscriptService.swift`, `ChapterService.swift` und `BackgroundRefreshService.swift`. Der bei der Recherche angezeigte Repository-Stand war `57ce7e26e60866c14d1ac8a9fa315f856b2f5c02`. Es wurde kein Build ausgeführt und kein Laufzeitverhalten getestet.

Das Projekt beschreibt einen nativen Swift-/SwiftUI-Player mit RSS-Abonnements, Downloads, Hintergrundaktualisierung, Kapitelunterstützung, Transkriptanzeige und zeitbezogenen Notizen. Die README dokumentiert Markdown-Export mit YAML-Metadaten. [S1]

Der gelesene Transkriptdienst lädt und verarbeitet vorhandene Textformate, darunter SRT, VTT und Markdown. Er ist nicht mit einer Audio-zu-Text-Pipeline gleichzusetzen. Der Kapitelservice verarbeitet externe Kapitel-JSON, eingebettete Podlove-Metadaten und Zeitmarken aus Beschreibungen; die Projektübersicht nennt zusätzlich in Audiodateien eingebettete Kapitel. [S2–S4]

**Nützliche Muster:** Feed-Import, Kapitelauflösung, Transkriptformate, sichere Wiederaufnahme von Hintergrundarbeiten und Verknüpfung von Notizen mit einer Position.

**Nicht als gegeben behandeln:** automatische Audioanalyse, interessenabhängige Wissensextraktion oder ein quellengebundener Mehrfolgen-Chat. Diese Funktionen sind durch die gelesenen YourPods-Dateien nicht belegt.

YourPods steht unter GPLv3. Codeübernahme und Lizenzkompatibilität müssen vor einer Integration geprüft werden. Der Entwurf setzt deshalb zunächst auf funktionale Referenz und klar getrennte Module, nicht auf ungeprüftes Kopieren von Quellcode. [S5]

### 2.2 BrainSpeak bleibt die Hauptbasis

Der angegebene BrainSpeak-Link und der Repository-Abruf lieferten in dieser Sitzung einen 404; auch die gezielte Repository-Suche lieferte keinen Treffer. Daraus lässt sich nicht bestimmen, ob das Repository privat, umbenannt, gelöscht oder für diese Verbindung nicht freigegeben ist.

Daher enthält dieses Dokument **keine Behauptung über aktuell vorhandene BrainSpeak-Klassen, Dateipfade oder fertig implementierte Funktionen**. BrainSpeak ist die vorgegebene Hauptbasis; die folgende Modulaufteilung ist ein Soll-Entwurf. Die Zuordnung zu dessen tatsächlichem Code bleibt ein expliziter Integrationsprüfpunkt.

Die Richtung lautet: **BrainSpeak um Podcast-Quellen und Player-Funktionen erweitern**, nicht YourPods forken und BrainSpeak auf einen Neben-Chat reduzieren.

## 3. Zwei entscheidende Machbarkeitsfragen

### 3.1 Apple Intelligence und Private Cloud Compute

Apple dokumentiert inzwischen `PrivateCloudComputeLanguageModel` für iOS 27 und die entsprechenden weiteren Apple-Plattformen. Die Nutzung erfolgt über das Foundation-Models-Framework. PCC benötigt Netzwerkzugriff, unterstützt ein größeres Kontextfenster und unterliegt einem täglichen Nutzerkontingent. Die Dokumentation nennt 32K Kontext; konkrete verfügbare Modellkapazitäten sollen zur Laufzeit abgefragt werden. [S6, S7]

Der Zugang ist nicht allein durch ein kompatibles iPhone gegeben. Apple verlangt ein berechtigtes Entwicklerkonto im App Store Small Business Program, die Einhaltung der Erstdownload-Grenze sowie ein freigeschaltetes PCC-Entitlement. Apples Berechtigungsseite beschreibt außerdem TestFlight-/Ad-hoc-Tests und Bedingungen bei späterem Verlust der Berechtigung. Die Kontoprüfung ist daher ein Freigabekriterium, insbesondere bevor eine Distribution unter einem Unternehmensaccount eingeplant wird. [S8]

**Produktentscheidung:** lokal vorbereiten und durchsuchen; PCC gezielt für anspruchsvolle Antworten und Vergleiche einsetzen. Kein automatischer Wechsel zu fremden KI-Anbietern.

Bei fehlendem PCC bleiben Player, bereits erschlossenes Wissen, lokale Suche und die tatsächlich verfügbare lokale Analyse nutzbar. Eine schwächere lokale Antwort darf nicht als gleichwertiger Ersatz für eine anspruchsvolle PCC-Synthese ausgegeben werden. Der Nutzer sieht den Verarbeitungsmodus und seine Grenzen.

PCC ist eine Rechenoption, kein dauerhafter Wissensspeicher und kein Ersatz für eine lokale Jobsteuerung. Der Wissensbestand und die Interessenverwaltung bleiben Aufgaben der App.

### 3.2 YouTube-Abonnement ist nicht gleich Audio-Feed

Google dokumentiert einen Atom-Feed für Kanalaktualisierungen. Seine Einträge referenzieren Videos; sie stellen nicht den üblichen Podcast-Audio-Anhang bereit. [S9]

Die YouTube-API-Richtlinien untersagen unter anderem das Isolieren von Audio und einen Hintergrundplayer, der nicht auf der betrachteten Oberfläche angezeigt wird. Ein YouTube-Premium-Abonnement wird in diesem Entwurf nicht als Erlaubnis für beliebige Drittanbieter-Audioextraktion behandelt. Die offizielle Caption-Download-API verlangt Bearbeitungsrechte am Video und ist damit kein allgemeiner Transkriptzugang für fremde Videos. [S10, S11]

Daraus folgt eine quellenabhängige Funktionsfreigabe:

| Quelle | Abonnieren / aufnehmen | Wiedergabe | Wissen erschließen |
|---|---|---|---|
| Podcast-RSS mit zugänglichem Audio | Ja | Native Audio- und Hintergrundwiedergabe | Aus geeignetem Transkript oder direkt aus der Audiodatei |
| Einzelne berechtigt verfügbare Mediendatei | Ohne Abo | Native Wiedergabe | Vollständige lokale Verarbeitung nach Format-/Sprachprüfung |
| YouTube-Kanal oder einzelnes Video | Kanal verfolgen bzw. Video aufnehmen | Richtlinienkonformer sichtbarer Player oder YouTube öffnen | Nur mit gesondert zugänglichem, berechtigt nutzbarem Medien-/Textmaterial |
| YouTube plus zugehöriger offizieller Podcast-Feed | Beide Quellen verknüpfen | Audio aus dem RSS-Feed | Analyse dieser Audiofassung; abweichende Schnittfassungen beachten |
| YouTube ohne nutzbares Transkript oder Audio | Ja, als Quelle | Video ansehen | Nur Metadaten-Vorschau, keine vorgetäuschte Inhaltsanalyse |

**Nicht versprechen:** „Jedes YouTube-Video wird automatisch als Offline-Audio ausgewertet.“ Ein solcher universeller Zugang ist durch die geprüften offiziellen Schnittstellen nicht gedeckt.

## 4. Informationsarchitektur

Die primäre Navigation hat vier Bereiche. Einstellungen und Interessenprofil liegen im Profilmenü. Ein Mini-Player bleibt bei laufender Wiedergabe verfügbar.

| Bereich | Nutzerfrage | Hauptinhalt | Primäre Aktion |
|---|---|---|---|
| **Für dich** | Was lohnt sich für mich? | Persönlich begründete Relevanz, neue Aussagen, offene Fragen, Gegenpositionen | Verstehen |
| **Mediathek** | Welche Quellen und Folgen habe ich? | Abos, Einzelimporte, Downloads, Hör- und Analysewarteschlange | Quelle hinzufügen |
| **Fragen** | Was sagen meine Quellen dazu? | Chat mit sichtbarem Quellenumfang und Analyseabdeckung | Frage stellen |
| **Wissen** | Was möchte ich behalten? | Gesicherte Aussagen, Notizen, Themen, Vergleiche, Markdown-Export | Erkenntnis öffnen |

### Folgenansicht

Im Kopf stehen Titel, Quelle, Dauer, Veröffentlichungsdatum und der Bearbeitungsstand. Darunter liegen gleichwertig **Verstehen**, **Hören/Ansehen** und **Fragen**. Der Wiedergabeknopf wird nie durch eine noch laufende Analyse blockiert.

Der Standardbereich „Verstehen“ zeigt erst die persönliche Relevanz, dann die Kurzfassung und anschließend belegte Erkenntnisse. Unter „Kapitel“ liegen Herausgeberkapitel und sichtbar gekennzeichnete KI-Kapitel. Das Transkript kann unabhängig geöffnet und durchsucht werden.

Auf iPad und Mac kann dieselbe Struktur als geteilte Ansicht erscheinen: links Quellen/Folgen, in der Mitte Inhalt, rechts Chat und Belege. Das ist eine Layout-Annahme, kein zweites Produkt mit anderem Wissensbestand.

## 5. Die persönliche Vorschau vor dem Abspielen

Ein fertiger Eintrag beantwortet vier Fragen: Warum passt das zu mir? Was steht tatsächlich darin? Was ergänzt meinen bisherigen Wissensbestand? Welche Stellen sollte ich gezielt hören?

**Illustratives UI-Beispiel; Titel, Zahlen und Zeitmarken sind frei erfunden und stammen nicht aus einer analysierten Folge:**

```text
Lokale KI im Unternehmen                         68 Minuten
Vollständig analysiert · Noch nicht gehört

Für dich relevant
Passt zu deinem bestätigten Thema „Lokale KI“
und deiner offenen Frage nach Betriebsaufwand.

Neu in deinem Wissensbestand
Ein Praxisbeispiel ergänzt deine bisherigen Notizen
um die Perspektive des laufenden Modellbetriebs.

Stelle zum Vertiefen
18:40–26:10 · Betrieb statt reiner Modellleistung

[Verstehen]  [Diese Stelle hören]  [Fragen]
Warum empfohlen? · Bereits bekannt · Nicht relevant
```

Die App darf nicht aus dem Titel heraus behaupten, dass eine bestimmte Aussage im Audio vorkommt. Deshalb existieren getrennte Evidenzstufen:

**Nur beschrieben:** Vorschau aus Titel und Beschreibung, deutlich als vorläufig markiert. Keine erfundenen Zitate, Zeitmarken oder Inhaltsaussagen.

**Teilweise analysiert:** Resultate nur für verarbeitete Abschnitte; Abdeckung in Minuten oder Abschnitten nennen. Keine Gesamtaussage über die vollständige Folge.

**Vollständig ausgewertet:** Ergebnisse beziehen sich auf die vollständig verfügbare und verarbeitete Inhaltsfassung. „Vollständig“ bedeutet nicht „fehlerfrei“ oder „extern auf Wahrheit geprüft“.

Für eine noch nicht abonnierte Sendung ist die persönliche Passung zunächst eine Metadaten-Prognose. Erst nach Analyse ausgewählter Beispielfolgen wird sie als inhaltsbasiert gekennzeichnet. Die Oberfläche behauptet dabei keine Aussage über das gesamte historische Archiv.

## 6. Interessenlernen unter Kontrolle des Nutzers

### Das Profil

Das Profil enthält dauerhafte Themen, aktuelle Vorhaben, offene Fragen und gewünschte inhaltliche Tiefe. Ein Nutzer kann beispielsweise „lokale KI“ als dauerhaftes Interesse und „eine Entscheidung zu Betriebsmodellen vorbereiten“ als zeitlich begrenztes Vorhaben anlegen.

Neue Nutzer können mit einem Satz beginnen oder das Profil überspringen. Die App bleibt ohne Personalisierung verwendbar.

### Welche Signale zählen?

Explizite Themen und Korrekturen haben Vorrang. Gesicherte Erkenntnisse, wiederkehrende Fragen und gewählte Vergleiche sind zusätzliche Signale. Hörverhalten ist nur ein schwaches Hilfssignal: Abbrechen kann Zeitmangel bedeuten, vollständiges Hören kann Unterhaltung statt fachlichen Nutzen bedeuten.

Die Anwendung sollte deshalb nicht einfach „mehr Hörminuten = größeres Interesse“ lernen.

**Feedbackaktionen:** „Mehr davon“, „Nicht relevant“, „Schon bekannt“ und „Nur für dieses Vorhaben“. Die App erklärt den Bezug: „Empfohlen wegen deines bestätigten Themas X; ergänzt deine gespeicherte Notiz Y.“

Vermutete neue Interessen werden als Vorschläge angezeigt, nicht heimlich zu verbindlichen Eigenschaften erklärt. Das Profil kann eingesehen, verändert, pausiert und gelöscht werden. Sensible persönliche Eigenschaften werden nicht aus Medienkonsum abgeleitet.

### Nicht nur eine Filterblase optimieren

Ein eigener Bereich „Andere Perspektive“ zeigt relevante Gegenpositionen. Sortiert werden kann jederzeit auch rein chronologisch. Nicht ausgewählte Folgen verschwinden nicht aus der Mediathek.

„Neu für dich“ wird vorsichtiger als **„Neu in deinem Wissensbestand“** formuliert. Die App weiß, was gespeichert oder als bekannt markiert wurde; sie kennt nicht das gesamte Wissen eines Menschen.

## 7. Vom Audio zu nachvollziehbarem Wissen

### Eine dateibasierte Pipeline statt Mithören

Das Audio wird als zugängliche Mediendatei übernommen. Es muss nicht in Echtzeit abgespielt werden und wird nicht über Lautsprecher oder Mikrofon erneut aufgenommen.

Ein geeignetes, vollständig zugängliches Herausgebertranskript kann die aufwendige Transkription ersetzen. Es wird nur gleichwertig verwendet, wenn Inhalt und Fassung passend sind. Fehlt es oder ist es ungeeignet, verarbeitet die App die Audiodatei direkt. Shownotes sind kein Ersatz für eine solche Inhaltsgrundlage.

Apple stellt mit SpeechAnalyzer und SpeechTranscriber APIs für die Verarbeitung von Sprachaufnahmen bereit; die Dateiverarbeitung und zeitbezogene Transkription sind dokumentiert. Die Verfügbarkeit passender Sprachassets und Gerätefunktionen muss geprüft werden. [S12, S13]

### Verarbeitungsschritte

1. Quelle auflösen und erlaubte Funktionen bestimmen.
2. Audio beziehungsweise geeignetes Transkript beschaffen.
3. Die konkrete Medienfassung identifizieren.
4. Zeitbezogenes Transkript erstellen oder importieren.
5. Nach Sinnabschnitten und vorhandenen Kapiteln strukturieren.
6. Pro Abschnitt Aussagen, Begriffe, Beispiele und Unsicherheiten extrahieren.
7. Abschnittsergebnisse zu einer Folgenübersicht zusammenführen.
8. Die Inhalte in den lokalen Such- und Wissensbestand aufnehmen.
9. Persönliche Relevanz aus dem bestätigten Interessenprofil berechnen.
10. Vorschauen und Antworten mit vorhandenen Belegen verknüpfen.

Quelleninhalte gelten dabei als Daten, nicht als Handlungsanweisungen für den Agenten. Ein im Podcast ausgesprochener Befehl darf beispielsweise keine Dateien exportieren oder Einstellungen verändern.

### Kapitel und Zeitmarken

Vorhandene Herausgeberkapitel bleiben erhalten. Fehlende Kapitel können aus zeitbezogenem Transkript erzeugt werden und tragen die Kennzeichnung „KI-Kapitel“. Zusätzlich kann der Nutzer eine persönliche Auswahl „Für mich relevante Stellen“ sehen, ohne dass die Originalstruktur überschrieben wird.

YourPods weist ausdrücklich auf die Ausrichtung eingebetteter Kapitel zur tatsächlich abgespielten Audiodatei hin. [S1] Der Soll-Entwurf erweitert dieses Prinzip: Audio, Transkript, Kapitel und Zitate referenzieren dieselbe Medienversion. Ändern dynamische Werbeeinblendungen oder andere Schnitte die Datei, werden alte Zeitmarken nicht unbemerkt auf die neue Fassung übertragen. Nicht zeitcodierte Texte erhalten Absatzbelege, keine erfundenen Sekundenangaben.

## 8. Chat mit einer Folge, mehreren Folgen oder der Bibliothek

### Sichtbarer Quellenumfang

Jeder Chat zeigt dauerhaft einen wählbaren Umfang: **Diese Folge**, **Auswahl**, **Sammlung** oder **Alle analysierten Folgen**. Ein Wechsel startet eine nachvollziehbare neue Quellenauswahl; er darf nicht stillschweigend passieren.

„Alle“ heißt: alle indexierten Inhalte im gewählten Bestand. Es heißt weder „alle jemals veröffentlichten Folgen“ noch „der gesamte Inhalt des Internets“.

Ein Beispielsatz über der Antwort lautet: „14 von 20 Folgen in dieser Auswahl sind analysiert. Für diese Antwort wurden Fundstellen aus vier Folgen verwendet.“ Beide Zahlen erfüllen unterschiedliche Zwecke und werden getrennt angezeigt.

### Ergebnisform

Eine gute Antwort trennt:

- **Aussagen der Quellen:** mit Folge, Veröffentlichungsdatum und belegbarer Passage.
- **Zusammenführung oder Ableitung:** ausdrücklich als Interpretation gekennzeichnet.
- **Unklarheiten und fehlende Abdeckung:** etwa widersprüchliche Quellen oder noch nicht analysierte Folgen.

Die App zeigt bei Bedarf Gegenpositionen und zeitliche Entwicklungen. Eine Podcast-Aussage ist nicht automatisch eine extern verifizierte Tatsache.

### Technischer Entwurf

Die Anwendung sucht zuerst passende Passagen im lokalen Bestand und übergibt sie mit stabilen Beleg-IDs an das Modell. Bei Vergleichen werden zunächst Aussagen pro Folge extrahiert, danach Gemeinsamkeiten und Unterschiede zusammengeführt. Fragen nach vollständigen Listen erfordern eine systematische Verarbeitung aller ausgewählten Inhalte; wenige Suchtreffer dürfen dafür nicht als Vollständigkeitsnachweis ausgegeben werden.

Auch PCC bekommt nicht blind die gesamte Bibliothek. Der begrenzte Modellkontext macht eine Auswahl und mehrstufige Zusammenführung weiterhin erforderlich. [S6]

Beleg-IDs und Zeitbereiche kommen aus den gespeicherten Daten. Das Modell darf keine neuen Quell-URLs oder Zeitmarken erfinden. Die Anwendung prüft, ob angegebene Belege existieren und zum gewählten Umfang gehören. Das reduziert Fehler, ersetzt aber keine Qualitätsprüfung der inhaltlichen Belegtreue.

## 9. Hintergrundbetrieb ohne falsche Versprechen

Vier Aufgaben benötigen getrennte Steuerung:

| Aufgabe | Technischer Bezug | UX-Vertrag |
|---|---|---|
| Audio hören | Native Medienwiedergabe mit passenden Audio-/Hintergrundkonfigurationen | Hören muss unabhängig vom Analysezustand funktionieren. |
| Neue Folgen finden | Hintergrundaktualisierung und Aktualisierung beim Öffnen | Letzten erfolgreichen Abruf zeigen; keinen festen Minutentakt garantieren. |
| Dateien laden | Hintergrund-URLSession | Transferstatus, Speichergrenzen und Netzpräferenz anzeigen. |
| Inhalte auswerten | Geplante Verarbeitung oder nutzerinitiierte fortgesetzte Aufgabe | Fortschritt sichern, Abbruch verkraften, Wartegrund benennen. |

Apple dokumentiert sowohl systemgesteuerte Hintergrundaufgaben als auch fortgesetzte Aufgaben, die durch eine Nutzeraktion im Vordergrund beginnen. Letztere sind keine allgemeine Erlaubnis für unbegrenzte, unsichtbare Daueranalyse. Hintergrunddownloads sind davon zu unterscheiden. [S14–S16]

Der Entwurf verwendet eine persistente Jobwarteschlange mit getrennten Schritten und Wiederaufnahmepunkten. Standardmäßig werden neue Inhalte nach den Einstellungen des Abos vorbereitet. Ein großes Archiv wird nicht ohne ausdrückliche Auswahl geladen und analysiert.

Wichtige Anzeigen sind „Wartet auf WLAN“, „Wartet auf günstige Gerätebedingungen“, „Transkription unterbrochen“, „PCC-Kontingent erreicht“, „Transkript fehlt“ und „Analyse abgeschlossen“. Eine unterbrochene Aufgabe darf nicht automatisch als abgeschlossen gelten.

Ein optionaler Mac kann später die Verarbeitung übernehmen und Ergebnisse synchronisieren, wenn er verfügbar ist. Ein Mac ist dabei weder zwingender Master noch ein ständig verfügbarer Dienst. Synchronisation und Rechenleistung sind getrennte Fähigkeiten; PCC ersetzt den Scheduler nicht.

## 10. Zwei unabhängige Warteschlangen

**Als Nächstes hören** enthält Folgen oder ausgewählte Originalpassagen, die der Nutzer abspielen möchte.

**Für mich auswerten** enthält Inhalte, deren Wissen erschlossen werden soll. Ein Abo kann automatisch hier hineinliefern, ohne die Hörwarteschlange zu verändern.

Pro Abo werden unabhängig voneinander festgelegt: neue Folgen verfolgen, automatisch analysieren und Audio offline bereithalten. Analyse kann temporär einen Download benötigen, auch wenn die Audiodatei nach erfolgreicher Verarbeitung nicht dauerhaft aufbewahrt werden soll.

Die Analysepolitik kennt „Neue Folgen vollständig“, „Nur ausgewählte Folgen“ und „Nach Interessen vorsortieren“. Die interessenbasierte Vorsortierung kann ohne bereits vorhandenen Volltext relevante Inhalte übersehen; diese Einschränkung muss sichtbar sein. Eine Option zur vollständigen Analyse neuer Folgen bleibt deshalb erhalten.

## 11. Markdown als echtes Arbeitsformat

Export ist nicht nur „Chattext kopieren“. Die App exportiert eine vollständige, nachvollziehbare Wissensnotiz.

**Exportobjekte:** eine Folge, eine einzelne Erkenntnis, ein Chatresultat, eine Sammlung oder ein Vergleich mehrerer Folgen.

**Inhalt:** Titel, stabile Identität, Quelle, Veröffentlichungsdatum, Erstellungsdatum der Analyse, Verarbeitungsbasis, Abdeckung, Kurzfassung, Erkenntnisse, Belegstellen, eigene Notizen und offene Fragen. Bei Mehrfolgen-Ergebnissen kommen Quellenumfang und Zuordnung einzelner Aussagen hinzu.

Standardmäßig exportiert die App verdichtete Erkenntnisse und notwendige Belegausschnitte, nicht automatisch fremde vollständige Transkripte oder Audiodateien. Erweiterte Exporte richten sich nach den verfügbaren Nutzungsrechten.

Ein appinterner Zeitlink kann zusätzlich zur normalen Quellenreferenz angeboten werden. Außerhalb der App bleiben der Folgentitel und die lesbare Zeitangabe erhalten. Bei reinen Textquellen ohne Zeitbezug werden Absatzkennungen verwendet.

Private Feed-Token und Zugangsdaten werden nicht in geteilte Dateien übernommen. Das Interessenprofil wird nicht standardmäßig mitexportiert. Ein erneuter Export überschreibt keine vom Nutzer ergänzten Notizen ohne kontrollierte Zusammenführung oder Rückfrage.

Ein separates Beispieldokument im Paket zeigt die Struktur. Es enthält absichtlich keine vorgetäuschten Podcast-Aussagen.

## 12. Soll-Architektur um BrainSpeak

Die folgenden Namen beschreiben fachliche Zuständigkeiten, nicht nachgewiesene vorhandene BrainSpeak-Module.

| Modul | Verantwortung |
|---|---|
| Source Adapters | RSS, YouTube-Referenzen, Einzeldateien, Quellenauflösung und Capability-Flags |
| Subscription & Import | Abos, Einzelimporte, OPML und Archiv-Auswahl |
| Media Pipeline | Download, Dateiversion, Audioaufbereitung und Wiederaufnahme |
| Transcription | Herausgebertext, Apple-Spracherkennung, Zeitbezug und Sprachverfügbarkeit |
| Knowledge Core | Abschnitte, Aussagen, Belege, Index, Notizen und Quellenabdeckung |
| Apple Intelligence Router | Lokale Aufgaben, PCC-Aufgaben, Verfügbarkeit, Kontingente und Qualitätsgrenzen |
| Interest Profile | Bestätigte Themen, vermutete Interessen, Feedback und Relevanzbegründungen |
| Player | Wiedergabezustand, Audioausgabe, Kapitel, Originalpassagen und Hörwarteschlange |
| Background Coordinator | Persistente Jobs, Priorisierung, Pausieren, Wiederaufnahme und Ressourcenregeln |
| Markdown Export | Portable Wissensartefakte, sichere Metadaten und Quellenreferenzen |

Es soll genau eine Instanz die Audio-Session und den Wiedergabezustand kontrollieren. Eine Analysepipeline darf nicht einen zweiten konkurrierenden Player eröffnen. Mikrofon-/Live-Aufnahmefunktionen einer möglichen BrainSpeak-Basis werden für Podcast-Import nicht vorausgesetzt und müssen dafür nicht gestartet werden.

### Minimale Datenobjekte

`Source`, `Subscription`, `Episode`, `MediaVersion`, `TranscriptSegment`, `Chapter`, `Claim`, `EvidenceReference`, `Interest`, `Collection`, `ChatScope`, `InsightNote` und `ProcessingJob`.

Die Kennung einer Folge wird nicht allein aus einer veränderlichen Download-URL gebildet. Audiofassung und Folge bleiben unterscheidbar. Eine RSS- und eine YouTube-Fassung können verbunden sein, ohne als identisch zu gelten. Sprecheridentitäten werden nicht allein aus unsicherer automatischer Zuordnung als Tatsachen übernommen.

## 13. Erster vollständiger Produktumfang

Die erste Version sollte den gesamten Weg von der Quelle zur nutzbaren Erkenntnis abdecken, statt viele Player-Sonderfunktionen vor den Wissenskern zu stellen.

**Enthalten:** RSS-Abos, Einzelimport, Audio- und Kapitelwiedergabe, Hintergrunddownloads/-aktualisierung, dateibasierte Analyse, persönliche Vorab-Karte, Chat mit einer Folge/einer Auswahl/allen analysierten Folgen, sichtbare Quellen, editierbare Interessen und Markdown-Export. YouTube ist von Anfang an als Quellenart vorgesehen, jedoch mit den beschriebenen Grenzen je verfügbarem Inhalt. PCC wird nur bei tatsächlich vorhandener Berechtigung aktiviert.

**Spätere Erweiterungen:** komfortable geräteübergreifende Verarbeitung, Apple-Watch-/CarPlay-Spezialoberflächen, persönliche Text-to-Speech-Briefings und kontinuierlich gepflegte Themendossiers. Ein generiertes Briefing bleibt von Originalaudio unterscheidbar; Stimmen der Sprecher werden nicht nachgebildet.

### Frühe technische Nachweise

Vor einer umfangreichen Oberfläche sind drei Dinge praktisch nachzuweisen: BrainSpeak-Codezugang und Integrationspunkte, PCC-Berechtigung für das konkrete Entwicklerkonto sowie die Analyse einer langen RSS-Folge inklusive präziser Rücksprünge ins Audio. Parallel wird geprüft, welche YouTube-Quellen tatsächlich eine zulässige Inhaltsgrundlage liefern.

## 14. Abnahmekriterien

| Szenario | Erwartetes Ergebnis |
|---|---|
| Eine Folge wurde noch nie gehört. | Sie kann trotzdem vollständig erschlossen und befragt werden. |
| Ein Nutzer fragt nach einer Aussage. | Die Antwort führt zu einer vorhandenen Passage, nicht zu einer erfundenen Zeitmarke. |
| Nur ein Teil einer Auswahl ist analysiert. | Der Chat benennt die Lücke und behauptet keine Vollständigkeit. |
| Ein YouTube-Video liefert nur Metadaten. | Die App zeigt einen begrenzten Zustand und keine scheinbare Inhaltsanalyse. |
| Der Nutzer wechselt während der Analyse die App. | Erledigter Fortschritt bleibt erhalten; Fortsetzung folgt den verfügbaren Systemmöglichkeiten. |
| PCC ist gesperrt, offline oder ausgeschöpft. | Der Status ist sichtbar; Player und vorhandener Wissensbestand funktionieren weiter. |
| Eine personalisierte Empfehlung ist falsch. | Der Nutzer kann ihre Begründung sehen und das betreffende Interesse korrigieren. |
| Ein Feed ändert die Audiofassung. | Alte Zeitmarken werden nicht stillschweigend als weiterhin exakt ausgegeben. |
| Eine Erkenntnis wird exportiert. | Markdown enthält Quelle, Beleg und Analysegrundlage, aber keine Feed-Zugangstoken. |
| Die Audio-Datei wird aus Speichergründen gelöscht. | Wissen bleibt gemäß Nutzerwahl erhalten; Wiedergabe-/Offline-Status wird korrekt angepasst. |

**Erfolgsmessung:** bestätigter Nutzen von Erkenntnissen, Belegtreue, Korrekturhäufigkeit, Zeit bis zur ersten nutzbaren Erkenntnis, Anteil vorbereiteter neuer Folgen und zuverlässige Wiederaufnahme. Hörminuten sind kein vorrangiges Erfolgsziel.

## 15. Zusammenfassende Produktbeschreibung

BrainSpeak Podcasts macht aus abonnierten Audio- und Videoquellen einen persönlichen, nachvollziehbaren Wissensbestand. Die App zeigt schon vor dem Abspielen, warum eine Folge relevant sein könnte und – nach tatsächlicher Inhaltsanalyse – welche Aussagen sie enthält. Nutzer können hören, gezielt zu Fundstellen springen, einzelne Folgen oder ganze analysierte Sammlungen befragen und Erkenntnisse in Markdown weiterverwenden. Die Personalisierung bleibt transparent und korrigierbar. BrainSpeak bildet den Kern; klassische Player-Funktionen orientieren sich ergänzend an YourPods. Apple Intelligence verarbeitet Inhalte lokal, während berechtigter PCC-Zugriff anspruchsvollere Synthesen ermöglicht.

## Quellen und Recherchegrenzen

Alle Quellen wurden am 19. September 2026 konsultiert. Dokumentierte Funktionen sind keine eigenen Laufzeitmessungen. Die Quellenlage zur PCC-Nutzung ist die aktuelle Dokumentation, nicht der ältere Stand von WWDC25. Einige Apple-Detailseiten sind JavaScript-basiert; ihre indexierten Inhalte wurden ergänzend zu den zugänglichen WWDC26-Seiten verwendet.

- **S1 — YourPods README:** `https://github.com/asecretcompany/yourpods-source/blob/main/README.md`
- **S2 — YourPods Spec Compliance:** `https://github.com/asecretcompany/yourpods-source/blob/main/SPEC_COMPLIANCE.md`
- **S3 — TranscriptService:** `https://github.com/asecretcompany/yourpods-source/blob/main/YourPods/YourPods/Services/TranscriptService.swift`
- **S4 — ChapterService:** `https://github.com/asecretcompany/yourpods-source/blob/main/YourPods/YourPods/Services/ChapterService.swift`
- **S5 — Lizenzhinweise:** `https://github.com/asecretcompany/yourpods-source/blob/main/NOTICE.md`
- **S6 — Apple: Adding server-side intelligence with Private Cloud Compute:** `https://developer.apple.com/documentation/FoundationModels/adding-server-side-intelligence-with-private-cloud-compute/`
- **S7 — Apple WWDC26: Build with the new Apple Foundation Model on Private Cloud Compute:** `https://developer.apple.com/videos/play/wwdc2026/319/`
- **S8 — Apple: Accessing Private Cloud Compute:** `https://developer.apple.com/private-cloud-compute/`
- **S9 — Google: YouTube channel Atom feed:** `https://developers.google.com/youtube/v3/guides/push_notifications`
- **S10 — YouTube API Services Developer Policies:** `https://developers.google.com/youtube/terms/developer-policies`
- **S11 — YouTube Captions: download:** `https://developers.google.com/youtube/v3/docs/captions/download`
- **S12 — Apple WWDC25: SpeechAnalyzer:** `https://developer.apple.com/videos/play/wwdc2025/277/`
- **S13 — Apple: SpeechAnalyzer file input:** `https://developer.apple.com/documentation/speech/speechanalyzer/analyzesequence(from:)`
- **S14 — Apple WWDC25: Finish tasks in the background:** `https://developer.apple.com/videos/play/wwdc2025/227/`
- **S15 — Apple: Performing long-running tasks on iOS and iPadOS:** `https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados/`
- **S16 — Apple: Downloading files in the background:** `https://developer.apple.com/documentation/foundation/downloading-files-in-the-background`
- **S17 — YourPods BackgroundRefreshService:** `https://github.com/asecretcompany/yourpods-source/blob/main/YourPods/YourPods/Services/BackgroundRefreshService.swift`
- **S18 — Apple AVFoundation:** `https://developer.apple.com/av-foundation/`
- **S19 — Apple: What's new in Apple Intelligence:** `https://developer.apple.com/apple-intelligence/whats-new/`

**Nicht lesbar:** `https://github.com/GodModeAI2025/BrainSpeak`. Kein bestätigter Commit und keine aktuelle Quellcodeanalyse in dieser Sitzung.
