# Feature Detail: Smart Podcast List / persönliche Themen-Feeds
Version 1.3 · 2026-09-20 · normativer Zusatz zu FR-121–FR-144 und US17–US20.

## 1. Produktentscheidung
Eine Smart Podcast List ist ein gespeicherter persönlicher Feed, nicht bloß eine temporäre Queue. Er enthält veröffentlichte persönliche Ausgaben (`PersonalEpisode`) mit eigenem Titel, Shownotes, Cover und unveränderlichem Segmentmanifest. Die Audioinhalte bleiben Referenzen auf zugängliche Originalmedien. Das Abspielen vermittelt eine zusammenhängende Folge, ohne eine neue Audiodatei, einen öffentlichen RSS-Server oder generierte Sprache vorauszusetzen.

V1 ist ein privater, app-interner Feed. Öffentliche RSS-Veröffentlichung oder Audio-Redistribution ist kein implizites Feature. JSON-/Markdown-Export beschreibt Quellen und Zusammenstellung. Die bestehenden Quellenfähigkeiten und Originalwiedergaberegeln gelten unverändert.

## 2. Konfiguration und Lernen
`SmartPodcastFeed` enthält Nutzername/Titel, topicIDs oder ausdrücklich formulierte Frage, Quellen-Scope, Profilrevision, Lernfreigabe, ungehört-Filter, Ausgabemodus, Zeitbudget, Sortierung und Aktualisierungspolitik. Die im Gespräch genannten Themen iOS/Mobile, Google/KI, EnBW und Datenschutz sind konfigurierbare Beispiele.

Die initiale Einrichtung verlangt keine psychologische Befragung. Bestätigte Interessen können übernommen werden. Auf Play erfolgt keine wiederkehrende Interessenfrage. Späteres Lernen aus gespeichertem Feedback ist optional und korrigierbar. Aus Nicht-Hören wird kein Desinteresse abgeleitet. Eine politische Themenwahl führt zu sachbezogener, neutraler Quellenzusammenstellung, nicht zu Meinungsprofilen oder politischer Überredung.

Getrennte Feeds pro Thema und ein gemeinsamer „Mein Themen-Update“-Feed sind möglich. Abonnements, Analysequeue und Hörqueue bleiben separate Objekte. Der Feed durchsucht ausschließlich seinen freigegebenen Bestand; er führt keine unangekündigte Websuche aus.

## 3. Zwei Betriebsarten
### 3.1 Episodenfokus
Die Originalfolge bietet „Ganz hören“, „Für mich relevante Stellen“ und Kapitel-/Belegsprünge. Auswahl beruht auf aktuellem bestätigtem Profil oder explizitem Chatwunsch. Einmal Play genügt für die geordnete Abschnittsfolge. Beim Verlassen kann die Originalfolge an der vorherigen oder aktuellen Originalposition weiterlaufen.

### 3.2 Persönliche Folgen über mehrere Quellen
Im Bereich „Für dich → Meine Podcasts“ erscheint jeder gespeicherte Themenfeed wie eine Sendung. Seine Ausgaben sind eigenständige Objekte, z. B. „Datenschutz · Ausgabe 8“. Sie sind analysierbar/befragbar als Auswahl ihrer Originalbelege, ohne Shownotes als neue Primärquelle zu indexieren.

**Alles Ungehörte:** Ein Exhaustive-Coverage-Lauf durchsucht alle analysierten, erlaubten Inhalte im gewählten Scope. Treffer werden nicht durch Top-k abgeschnitten. Technische Seiten-/Ausgabelimits erzeugen Folgeausgaben bzw. einen expliziten Restbestand, niemals eine falsche Vollständigkeit. „Alle passenden Stellen aus 28 analysierten Folgen; 6 Folgen noch nicht analysiert“ ist eine zulässige Darstellung.

**Kuratierte Ausgabe:** Ein Nutzerbudget begrenzt aktive Hörzeit. Nicht ausgewählte, ungelesene oder ungespielte Inhalte bleiben Kandidaten. Sortierung ist nachvollziehbar: Themengruppen, dann gewählte Aktualität bzw. Originalreihenfolge; Quellenvielfalt wird berücksichtigt, ohne Mehrheitsansichten vorzutäuschen. Widerspruchs-Mixer bleibt ein eigener freiwilliger Modus.

## 4. Veröffentlichung und Zustände
`collecting → candidate → ready → published → inProgress → completed/archived` ist die logische Folge. Datenmodell trennt publicationState von consumptionState. `awaitingAnalysis`, `nothingNew`, `sourceUnavailable` und `partialCoverage` sind fachliche Zustände, keine generischen Fehler.

1. Ein neues/finalisiertes Analyseergebnis oder eine explizite Aktualisierung löst Kandidatenprüfung aus.
2. Evidence-IDs, Scope, Medienrevision, verfügbare native Audiowiedergabe und Zeitbezug werden geprüft.
3. Die globale abgespielte Intervallmenge und explizite Ausschlüsse werden abgezogen.
4. Offene, bereits in anderen persönlichen Ausgaben reservierte Kernaussagen werden nicht erneut als neue Ausgabe veröffentlicht; bestehende Ausgaben können in mehreren Themenansichten verlinkt werden.
5. Eine semantische Ähnlichkeit allein ist keine Dublette: verschiedene Originalaussagen oder Gegenpositionen bleiben unterscheidbar. Echte Audio-/Evidence-Dubletten benötigen überprüfte Identität.
6. Der Publisher bildet eine persistierte Batch-ID aus Feed-ID, Policyrevision und sortierten Medien-/Beleg-/Kernbereich-Identitäten. Sie hängt nicht von Uhrzeit, Titel oder zufälliger Modellausgabe ab. Innerhalb eines Profils sichert zusätzlich eine globale Reservierung gegen doppelte Veröffentlichung.
7. Aus dem finalisierten Manifest entstehen belegte Shownotes, Titel, Dauer und Chapter-Mapping. Ein Fallback-Cover ist sofort vorhanden. Erst dann wird die Ausgabe atomar publiziert.
8. Optionale lokale Benachrichtigung folgt nach Commit, höchstens einmal pro Ausgabe. Neue Folgen starten niemals Ton; Hintergrundausführung garantiert keinen festen Veröffentlichungszeitpunkt.

Bereits veröffentlichte/gestartete Ausgaben werden nicht unsichtbar umgeschnitten. Nachträgliche Quellenverluste erzeugen einen sichtbaren Zustandswechsel. Eine bewusst gewünschte Restfassung erhält neue Revision, neue Shownotes und neuen PlaybackGrant. Reines Coverwechseln verändert die Audioidentität nicht. Bereits auf einem anderen Gerät gehörte Stellen werden beim Start angezeigt; „Nur Rest hören“ ist eine explizite abgeleitete Wiedergabeansicht, keine heimliche Umschreibung der veröffentlichten Ausgabe.

## 5. Segmentgenauer Hörverlauf
Die globale `ListeningLedger` speichert pro konkreter MediaVersion tatsächlich abgespielte Halbintervalle `[startMs,endMs)` in Originalmedienzeit. Events entstehen aus bestätigter Wiedergabe, nicht aus der höchsten Seekposition. Pausieren, Buffering, Scrubbing, Überspringen und Hintergrundanalyse füllen keine Intervalle. Wiedergaberate verändert Wandzeit, nicht Originalzeit. „Gehört“ ist UI-Kurzform für dokumentierte Wiedergabe, kein Nachweis von Aufmerksamkeit.

Überlappende Intervalle werden vereinigt. Wiederholung zählt nicht doppelt. Eine vollständig abgespielte persönliche Ausgabe markiert nur ihre Originalintervalle, niemals automatisch ganze Originalfolgen. Manuelles „als erledigt markieren“/„bekannt“ besitzt eigene Felder und kann Kandidaten unterdrücken, erzeugt aber keine erfundenen Hörintervalle.

Zwei Filter sind explizit wählbar:
- `unheardSegments`: Reststellen auch aus bereits begonnenen Originalfolgen.
- `neverStartedEpisodes`: Nur Quellenfolgen ohne dokumentierte Wiedergabe; unbekannte ältere Historie wird als solche angezeigt.

Beim Abzug gehörten Materials dürfen keine sinnentstellenden Halbsätze entstehen. Restkerne werden an verifizierten Satz-/Themen-Grenzen neu verankert; dafür sind neue Evidence-IDs bzw. überprüfte Untersegmentbelege erforderlich. Notwendiger wiederholter Kontext erscheint als `contextReplay`, nicht als angeblich neuer Inhalt. Kein pauschaler 90%-Schwellwert darf den Rest als vollständig gehört ausgeben. Sehr kleine Restfragmente werden als Rest/kontextabhängig dargestellt oder nach expliziter Policy archiviert, nie stillschweigend verschluckt.

Offline-Sync vereinigt Wiedergabeereignisse anhand stabiler Event-IDs und MediaVersion. Bei explizitem Historienreset steigt die Epoch; ältere Events dürfen nicht wieder erscheinen. Bei fehlender Revisionsgleichheit findet keine Übertragung von Zeiten zwischen Podcast-/YouTube-/Werbefassungen statt.

## 6. Originalaudio und Zeitachsen
Jeder Segmentdatensatz referenziert Episode, MediaVersion, TranscriptRevision, Evidence-ID, coreRange und playbackRange. `playbackRange` darf geprüften Kontext ergänzen. Innerhalb der persönlichen Ausgabe wird ein virtueller Medienzeitbereich gespeichert. Die Abbildung ist stückweise linear: `original = playbackStart + (personalTime - virtualStart)`. Wiedergabegeschwindigkeit bleibt Aufgabe des zentralen Players.

Kapitelgrenzen und Segmentfolge sind aus dem Manifest berechnet, nicht vom LLM erfunden. Kontextpausen wären separat explizit zu modellieren; V1 fügt keine gesprochenen oder künstlichen Audiobrücken ein. Quellenübergänge werden sichtbar und screenreader-kompatibel angezeigt. Ton startet nach dem gültigen Grant einmalig; Folgesegmente benötigen keine wiederholte Nutzerabfrage.

Der Player zeigt zwei Zeiten: Gesamtposition der persönlichen Ausgabe und aktuelle Originalposition. Medienfernsteuerung/Now Playing zeigt den persönlichen Folgentitel plus aktuelle Originalquelle. Ein Quellenlink führt zu „Im Original weiterhören“. Tatsächliche lückenlose Audioübergänge sind ein Geräte-/Netztest, kein Versprechen für beliebige Streams.

## 7. Text und Shownotes
Apple Intelligence erstellt Titel und Shownotes ausschließlich aus den im Manifest verknüpften Originalbelegen. Jeder Absatz/Kapiteleintrag führt Evidence-IDs. Verfügbare, analysierte, passende und enthaltene Quellen werden getrennt gezählt. Die Beschreibung darf keine größeren Analyseumfänge behaupten, als dem Manifest zugrunde liegen.

Originaldatum, Datum der persönlichen Veröffentlichung und Zeitpunkt der Analyse sind verschiedene Felder. Alte Quellen werden nicht als aktuelle Unternehmens-/Produktneuigkeit dargestellt. Sprecher werden nur benannt, wenn verlässlich in Metadaten/Transkript belegt; andernfalls lautet die Anzeige nur Originalfolge/Quelle.

KI-Text steht außerhalb des Originalaudio-Kanals. Originalaussagen werden weder nachgesprochen noch mit erfundenen Moderationen vermischt. Ein modellunabhängiger, aus Kapitelbezeichnungen erzeugter Shownotes-Fallback ermöglicht Publikation auch bei temporär fehlender Inferenz; er wird entsprechend gekennzeichnet.

## 8. Cover-Pipeline, Apple 27
Quellen: [A27–A30] im Quellenregister; neu verifiziert 2026-09-20.

**Automatisch:** `NativeCoverRenderer` erzeugt aus Feed-ID, Ausgaben-ID, Titel und freigegebenen Themen-Symbolen ein deterministisches quadratisches Cover. Kein Bildmodell nötig. Optional dient ein zuvor freigegebenes Feedmotiv als Hintergrund; native Typografie ergänzt Ausgabennummer und Titel. Dies darf nicht als neu von Image Playground generiertes Episodenbild bezeichnet werden.

**Image Playground:** `CoverArtworkCoordinator` bereitet einen kurzen Motivvorschlag aus nicht sensiblen belegten Themen vor. Nutzeraktion „Cover gestalten“ präsentiert `imagePlaygroundSheet`. Apple beschreibt außerdem `ImagePlaygroundOptions`, `imagePlaygroundGenerationStyle` und die Verfügbarkeitsprüfung `supportsImageGeneration`. Der Stil wird auf Apple-Stile begrenzt; `.externalProvider` ist ausgeschlossen, Personalisierung für Personenbilder deaktiviert. Die genaue API-Signatur wird im 27er-SDK-Compile-Gate geprüft, nicht durch erfundene Methoden ersetzt. [A27, A30]

Der Completion-URL verweist auf eine temporäre Datei. Ergebnis vor Abschluss der Session atomar in den App-Assetstore kopieren, Dateityp/-größe prüfen, Hash und Thumbnail erzeugen, dann Coverrevision speichern. Bei Abbruch bleibt das native Cover. Veröffentlichung/Audioplayback wartet nicht auf Bildgenerierung. [A30]

`ImageCreator` darf nicht als Hintergrund-Worker eingesetzt werden: eingestellt ab iOS/iPadOS/macOS 27; `init()` ist als nicht unterstützt dokumentiert. Es gibt in diesem Entwurf daher keinen unsichtbaren automatischen Image-Playground-Coverjob und keinen Umweg über private APIs/Shortcuts-Automation. [A28, A29]

Image-Playground-Verfügbarkeit ist getrennt von Foundation-Models-/PCC-Textberechtigung zu prüfen. Keine neue angebliche Image-Playground-Entitlement-Voraussetzung erfinden. Die Watch zeigt übertragene Assets und bietet einen sichtbaren Handoff zum Vollclient; sie führt keine angenommene lokale Image-Playground-Generierung aus. [A30]

## 9. Plattformen, Synchronisierung, Exporte
iPhone: integrierte Feedkarten, Ausgabenliste, nativer Player, Cover-Sheet. iPad: Feed-/Ausgaben-/Quellinspector im adaptiven Layout. Mac: native Sidebar, Bibliotheksjobs, Shownote-/Manifestinspector und Cover-Sheet. Watch: Ausgaben auswählen, vorbereitete Originalabschnitte hören, Kapitel wechseln, Originalquelle sehen und später zum Original springen; Cover wird synchronisiert.

CloudKit speichert Feedkonfiguration, unveränderliche Manifestrevisionen, kleine Shownotes-/Coverreferenzen und Ledger-Events. Kein dauerhafter Master; Offline-Doppelentwürfe werden vor Benachrichtigung soweit möglich, spätestens beim Sync, deterministisch zusammengeführt. Die App verspricht keine exakt-einmal Auslieferung über mehrere Offline-Geräte. Dieselbe Segmentidentität wird aber nach Merge nicht doppelt als neuer Inhalt geführt.

Markdown-Export einer Ausgabe enthält Titel, Inhalt, Originalquellen, Original- und persönliche Timecodes, Analyseabdeckung, Hinweis auf KI-Zusammenstellung und Coverherkunft. Manifest-JSON bleibt maschinenlesbar. Keine signierten/private Feed-URLs, Gerätekontodaten oder ungefragten ganzen Originaltranskripte exportieren. Eine Vorschau des Exports zählt nicht als Hören.

## 10. End-to-End-Abnahme (geplant, nicht ausgeführt)
Testkorpus: drei konfigurierte Themen und ein überlappendes Datenschutzthema; mehrere Medien mit präzisen Testzeitbereichen, eine teils gehörte Quelle, eine unanalysierte und eine nur im sichtbaren Webplayer abspielbare Quelle.

Eine persönliche Ausgabe enthält nur neue, passende, nativ abspielbare Originalsegmente. Nach tatsächlichem Abspielen eines Segments ist dieses im anderen Feed nicht erneut neu. Ein Scrub zum Ende verändert das nicht. Nach erneutem Refresh ohne neue Evidence entsteht keine Ausgabe. Neue passende Evidence erzeugt genau eine weitere logische Ausgabe; Originalveröffentlichungsdatum bleibt sichtbar. Auf Play werden Originalsegmente nacheinander abgespielt; beim Start per Sync/Notification bleibt es stumm. Ein Abbruch des Coverdialogs verhindert weder Veröffentlichung noch Wiedergabe. Ein bereits gestartetes Manifest wird bei neuem Material nicht verändert.
