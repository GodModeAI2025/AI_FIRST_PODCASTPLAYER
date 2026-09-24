# Plan: PodcastAI einfacher machen

Stand 24. September 2026, Grundlage: Sprachnotiz des Product Owners und Durchsicht von integration/0.8.

Ich habe nur gelesen, nichts geändert, gebaut oder gestartet. Im SDK habe ich nachgeprüft: `UseCase.contentTagging` (FoundationModels.swiftinterface:283), `GenerationGuide.anyOf` (:1425) und `DynamicGenerationSchema(name:anyOf:)` (:3166) gibt es. `ImageCreator` ist ab 27.0 als veraltet markiert, lässt sich aber noch bauen (ImagePlayground.swiftinterface:342-355).

## 1. Zielbild

Man abonniert einen Podcast oder YouTube-Kanal. Die App zeigt danach dessen Metadaten: Cover, Autor, Rubriken, Folgen- und Staffelnummer, Datum und Dauer. Beim Aktualisieren kommen die Metadaten neu an. Eine Folge öffnet sich mit Cover und Kapitelliste. Jedes Kapitel trägt seine Tags, seine Fakten und seinen Transkriptausschnitt, und neben jedem Kapitel steht „Original öffnen“. Liefert der Feed keine Kapitel, bildet die App eigene Abschnitte und kennzeichnet sie als abgeleitet. Tags tippt niemand mehr ein. Sie stammen aus dem Inhalt, und jedes Tag hat zwei Knöpfe: Plus heißt folgen, Minus heißt stumm. Aus einem Tag oder einer Kombination wie „Datenschutz und USA“ entsteht ein eigener Podcast. Er besteht aus ungehörten Kapiteln verschiedener Quellen, und jede Ausgabe dauert höchstens 20 Minuten. Bleibt mehr übrig, gibt es Teil 2 und Teil 3. Jede Ausgabe beginnt mit einer Übersicht, wie viele neue Aussagen es je Kapitel gibt. Ein Widget zeigt, was neu ist und welche Themen gerade quer über die Abos angesagt sind. Im Hintergrund arbeitet die App, wenn iOS sie lässt, und setzt nach einem Abbruch dort fort, wo sie stand. Darf sie nicht weiterarbeiten, sagt eine lokale Mitteilung das. Audio bleibt nur so lange, wie die Einstellungen es festlegen. Für alles andere dient es nur als Grundlage fürs Transkript.

Eine Grenze gilt für YouTube: Die App bekommt dort keinen Ton (`Services.swift:139-151`). Transkript, Fakten und Kapitel-Tags gibt es für YouTube deshalb nur, wenn der Feed ein Transkript mitliefert oder ein passender Audio-Podcast existiert (`PodcastCounterpart`, `Services.swift:606-660`). Andernfalls bleibt es bei Metadaten und Beschreibungskapiteln.

## 2. Was wegfällt oder zusammengelegt wird

- **Interessen per Freitext:** Die Eingabefelder `Views.swift:1655` („z. B. Datenschutz“), `:1842` (neues Thema im Feed-Blatt) und das Stichwortfeld `:1727` fallen weg. `InterestEditView` (`:1704`) wird zu einer Tag-Seite. Dort sieht man Treffer und Synonyme, kann Tags zusammenlegen und Plus oder Minus wählen.
- **Interessenarten:** „Vorhaben“ und „Frage“ (`Views.swift:179-180`, `InterestKind`) verschwinden aus der Oberfläche. Die Felder bleiben im Schema.
- **Einstellung „Interessen vorschlagen“** (`SettingsView.swift:303`) und die flüchtigen Vorschläge von `InterestSuggester` (im Speicher, `AppModel.swift:2233`, Ablehnungen in UserDefaults `:2285-2297`): An ihre Stelle tritt die Tag-Wolke. Ein Minus-Tag ersetzt die Ablehnung und gleicht über iCloud ab.
- **`TopicTagger` beim Anzeigen** (`TopicTags.swift:1-14`): Er liefert künftig nur noch Kandidaten für die Klassifizierung. „Kurz gesagt“ liest gespeicherte Tags.
- **Zwei Player:** `FocusPlayerView` (`Views.swift:2011`) und `EpisodePlayerView` (`ListeningViews.swift:1423`) werden zu einem Player mit Kapitel-Scrubbing, und eine Ausgabe verhält sich darin wie eine Folge.
- **Relevanz über Stichworte** (`RelevanceScorer`): Sie läuft nur noch als Rückfall ohne Apple Intelligence. Die Auswahl richtet sich nach Kapitel-Tags.
- **„Nicht relevant“ als Beleg-Kennung** (`AppModel.swift:366, 2755`) geht in Minus auf.

## 3. Datenmodell

Es gilt Regel 5 aus AGENTS: alles optional oder mit Standardwert, kein `.unique`, keine Pflichtbeziehungen. Das Schema wird nur ergänzt, und danach geht es über `initializeCloudKitSchema` (`LibraryStore.swift:57`) nach Production.

| Änderung | Form |
|---|---|
| `StoredInterest` wird Tag | neu: `stanceRaw = "follow"` (follow, mute, neutral), `normalizedKey = ""`, `originRaw` bekommt `"detected"`, `firstSeenAt: Date?`. `keywords` dient künftig für Synonyme (Aliasse). Kein Feld wird umbenannt. |
| neues `@Model StoredChapterTag` | `identifier`, `episodeIdentifier`, `mediaVersionIdentifier`, `chapterStartMs`, `chapterEndMs`, `interestIdentifier`, `confidence`, `matchedKnown`, `sourceIdentifier`, `publishedAt`, `createdAt`, `transcriptRevisionValue`, alle mit Standardwert. Die Verknüpfung läuft über Kennungen wie bei `StoredFact`. |
| JSON-Kapitel | kommen beim ersten Laden in das bestehende `StoredEpisode.chaptersData` (heute nur `chapterCache`, `AppModel.swift:2956-2969`). Ohne diesen Schritt bleibt die Klassifizierung lückenhaft. |
| Metadaten | `StoredSource.summary`, `categories`; `StoredEpisode.episodeNumber`, `season`, `author`, `keywords`, alle optional |
| Kapitel an Fakt und Beleg | **kein Feld.** Die Zuordnung rechnet der Code zur Laufzeit aus `startMs` und den Kapitelgrenzen. Dafür ist keine Migration nötig. |
| Themenfeed | Im Codable-Payload von `StoredSmartFeed` kommt `matchMode` dazu, Standard `any`. |
| Ausgabe | Das Manifest bekommt `part: Int = 1` und `overviewEntries`. |

`StoredChapterTag` muss in `modelTypes` (`LibraryStore.swift:43-49`), in `removeDuplicates` (`:281`), in `removeEpisode` und in `removeSource` aufgenommen werden. „Folge löschen“ nimmt die Kapitel-Tags mit, „Audio entfernen“ lässt sie stehen.

**Migration:** Bestehende Interessen werden an Ort und Stelle zu Tags mit `follow` und bekommen ihren `normalizedKey`. Liefern zwei Interessen denselben Schlüssel, legt `removeDuplicates` sie zusammen. Vorhandene `topicIDs` in Themenfeeds bleiben gültig, alte Feeds laufen also weiter. Alte Ausgaben sind unveränderliche Manifeste und bleiben, wie sie sind.

## 4. Klassifizierung je Kapitel

**Abschnitte:** Grundlage sind die Kapitel aus dem Feed: Podlove, JSON und neu die Zeitmarken in Shownotes und YouTube-Beschreibungen, alle mit `.original`. Fehlen sie, schneidet der Code Abschnitte von 4 bis 10 Minuten an Belegegrenzen. Er schneidet dort, wo der Satzvektor (`NLEmbedding`, `PassageRanker.swift:122-127`) zwischen zwei Belegen am stärksten springt. Solche Abschnitte tragen `Provenance.derived` und heißen in der Oberfläche „Abschnitt 3“. Grenzen und Zeiten legt nur der Code fest (Regel 3).

**Ablauf je Kapitel:**
1. *Kandidaten ohne Modell:* Es zählen Tags, denen jemand folgt, alle bekannten Tags, Namen aus `NLTagger` (Orte, Organisationen, `MentionExtractor.swift:436`) und die Hauptwörter aus `TopicTagger`. Die Kandidaten werden über den Satzvektor gegen den Kapiteltext gerankt, die besten 20 bleiben. Stumme Tags bleiben Kandidaten, damit sie gezählt werden, sie tauchen nur nirgends auf.
2. *Bekannte Klassen gezielt prüfen:* Das geschieht in einer Session mit `SystemLanguageModel(useCase: .contentTagging)`. Das Schema ist `DynamicGenerationSchema(anyOf: kandidaten)`, als Liste mit höchstens 5 Einträgen. Das Modell gibt damit nur vorhandene Kennungen zurück. Das Muster steht schon in `classify(_:against:labels:)` (`KnowledgeExtractor.swift:255-315`), und der Transkripttext bleibt Lesekontext, nicht Anweisung (Regel 2).
3. *Allgemeine Klasse finden:* Ein optionales Feld „Oberbegriff“ mit Längen- und Mustervorgabe (`.pattern`). Den Vorschlag schickt der Code zuerst noch einmal durch Schritt 2 gegen alle bekannten Tags. Erst wenn kein Tag passt, entsteht ein neues Tag mit `origin = detected` und `neutral`. Es erscheint in der Wolke, sobald es in zwei Quellen vorkommt.

**Normalisieren und Zusammenlegen:** Der Schlüssel entsteht aus Kleinschreibung, ohne diakritische Zeichen, als Lemma über `NLTagger .lemma` und ohne Leerzeichenvarianten („iOS 27“ = „ios27“). Für Länder gilt die ISO-Kennung. `Locale(identifier: "de").localizedString(forRegionCode: "US")` liefert „Vereinigte Staaten“, dieselbe Abfrage auf Englisch „United States“, und „USA“ steht in einer kleinen festen Liste. Die drei Schreibweisen führen so auf `region:US`. Alles Übrige geht über Aliasse in `keywords`. Bei englischen Folgen übersetzt `OnDeviceTranslation.swift` den Vorschlag vor dem Abgleich. Liegen zwei Tags im Vektor sehr nah beieinander, legt der Code sie nicht selbst zusammen. Er zeigt „Zusammenlegen?“ auf der Tag-Seite. `SensitiveTopicPolicy` (`TopicTags.swift:204`) prüft jedes neue Tag.

**Tempo und Kosten:** Die Klassifizierung läuft nur auf dem Gerät, in derselben Warteschlange wie die Fakten, direkt danach. PCC braucht es für eine Auswahl aus 20 Kandidaten nicht. Es kostet Netz und Kontingent und brächte hier keine bessere Auswahl. Lange Kapitel teilt der Code nach `tokenCount(for:)` auf, wie bei `factChunkSize` (`AppModel+Knowledge.swift:1328`). Die Teile werden vereinigt. Messwerte zur Geschwindigkeit fehlen. Deshalb kommt eine Eval nach dem Muster der Antwortmessung (`PODCASTAI_TAG_EVAL=1`), die `.general` gegen `.contentTagging` vergleicht. Sie misst Treffer je Kapitel und Sekunden je Kapitel.

## 5. Generierte Podcasts

- **Auswahl:** Ein Themenfeed besteht aus Tags und einem Modus: *eines davon* oder *alle* (UND auf Kapitelebene). Kandidaten sind Kapitel mit passendem `StoredChapterTag`, die das Ledger als ungehört führt und die in keiner Ausgabe dieses Feeds stecken. Minus-Tags schließen Kapitel aus. `RelevanceScorer` greift nur, wenn es noch keine Kapitel-Tags gibt.
- **Teil 2 möglich machen:** Heute hängt es an drei Stellen. Der `batchKey` umfasst alle ungehörten Treffer (`PersonalEpisodePublisher.swift:185-196`), daraus folgt `.alreadyPublished` (`AppModel.swift:2064`). `maximumPerInterest = 25` greift vor dem Ledger (`RelevanceScorer.swift:87, 131-136`). Und `applyBudget` wirft den Rest weg (`PersonalEpisodePublisher.swift:400-429`). Veröffentlichte Kapitel fliegen vor Schlüssel und Budget aus den Kandidaten, die Grenze rückt hinter das Ledger, und der Rest wird zu Teil 2, 3 usw.
- **Reihenfolge und Schnitt:** Das bewährte „Folge für Folge“ (`playbackOrder`) bleibt, die neueste Quelle kommt zuerst. Ein Kapitel geht ganz hinein, wenn es in 20 Minuten passt. Ist es länger, nimmt der Code die Belege mit Tag-Treffer und 6 s Vorlauf.
- **Übersicht am Anfang:** Kapitel 0 ist eine Karte ohne Ton: je Abschnitt Quelle, Datum und die Zahl neuer Aussagen (Fakten, deren `evidenceID` im Abschnitt liegt, `EditionCoverage`, `SmartPodcastFeed.swift:284-317`). Die Karte kommt auch in die Shownotes (`ShownotesBuilder.swift:23-48`). Ein gesprochenes Intro über `AVSpeechSynthesizer` wäre möglich, ohne Regel 4 zu berühren. Den Text baut dann der Code, nicht ein Modell.
- **Cover:** Je Ausgabe entsteht ein Bild über `ImageCreator` aus den Tags und den zwei häufigsten Namen, erzeugt im Vordergrund beim Zusammenstellen. Scheitert das oder läuft die App im Hintergrund, kommt das Layoutcover (`CoverView.swift:235-300`). Die API ist veraltet und bekommt deshalb keine weiteren Funktionen.
- **Eigene Rubrik:** Der Tab „Themen-Updates“ bleibt. Ausgaben sehen aus wie Folgen und laufen im gemeinsamen Player.
- **Zum Original:** `originalPosition(forVirtual:)` (`SmartPodcastFeed.swift:257`) hat bisher keinen Aufrufer. Es wird an Kapitelzeilen (`Views.swift:1053-1110`) und an die Quellkarte (`:2237-2270`) gebunden und öffnet die Folge an der Stelle über `playEpisode(_:at:)` (`AppModel.swift:2784`).
- **Regel 1:** Keine Ausgabe startet Ton (`PersonalEpisodePublisher.swift:12-13`). Daran ändert sich nichts.

## 6. Trends und Statistik

- **Neu:** Je Tag zählt die App Fakten in Kapiteln mit diesem Tag, die erschienen sind, seit die Tag-Seite zuletzt offen war, und die ungehört sind. Die Zahl steht in der Tag-Wolke und im Kopf von „Für dich“.
- **Angesagt:** Die App vergleicht ein 7-Tage-Fenster nach Erscheinungsdatum mit dem Wochenschnitt der vier Wochen davor. Angesagt ist ein Tag, wenn das Verhältnis mindestens 3 beträgt, mindestens 3 verschiedene Quellen es tragen und mindestens 5 Kapitel dazukommen. Das ist reine Zählung über `StoredChapterTag` ohne Modell. Stumme Tags zählen mit, werden aber nicht gezeigt.
- **Widget:** Eine neue Widget-Extension für iOS und macOS mit App Group. Beide Entitlements und `project.yml` bekommen `application-groups`, danach `xcodegen generate`. Nach jeder Auswertung schreibt die App einen kleinen JSON-Schnappschuss und ruft `WidgetCenter.reloadTimelines(ofKind:)` auf. Push für Widgets fällt weg, weil es keinen Server gibt.

## 7. Hintergrund und Fortsetzen

- **Was iOS 27 hergibt:** Transkripte tragen nur unter `BGContinuedProcessingTask`, und der muss im Vordergrund beginnen (`BackgroundContinuation.swift`). `BGProcessing` (`com.podcastai.analysis`) braucht Strom und übernimmt Fakten, Klassifizierung und Themen-Updates. `BGAppRefresh` aktualisiert nur noch Feeds und startet keinen Transkript-Worker mehr (Risiko heute: `BackgroundWork.swift:77-126`, `work.cancel()` erreicht `analysisTask` nicht). Im `expirationHandler` kommt `analysisTask?.cancel()` dazu. Der Fortschritt meldet sich innerhalb des Transkripts fein, nicht mehr in festen Stufen (`:66-71`).
- **Fortsetzen:** Das Transkript speichert beim Batch-Schnitt (`ContentPipeline.swift:161-171`) einen Prüfpunkt mit `analyzedRangesFlat` (`Models.swift:187`). Beim Neustart gehen `startingAt:` und eine Überlappung an `TranscriptAssembler.merge`. `analysisQueue` mit `automaticallyQueued` landet in UserDefaults, damit von Hand Angefordertes einen Neustart übersteht. Fakten sichern fertige Abschnitte vor `return .cancelled` (`AppModel+Knowledge.swift:1060, 1092`). Die Klassifizierung merkt sich pro Folge das letzte fertige Kapitel lokal.
- **Downloads:** Audio kommt über eine eigene `URLSessionConfiguration.background` mit `resumeData`. Die Prüfungen aus `SafeHTTP` (Ziel, Größe, `RedirectGuard`) wandern in den Delegaten. Mobilfunk regeln `allowsExpensiveNetworkAccess` und `allowsConstrainedNetworkAccess`.
- **Lokale Mitteilung:** In `didEnterBackground` (`AppModel+Knowledge.swift:1551`) prüft die App: Ist die Warteschlange voll und kein Continued-Task aktiv, oder ist er abgelaufen? Dann sagt `UNUserNotificationCenter`: „Transkripte pausieren, bis du PodcastAI öffnest.“ Um die Erlaubnis fragt die App beim ersten von Hand angeforderten Transkript. Dieselbe Erlaubnis dient für „Neue Ausgabe da“ (`notificationsEnabled`, `SmartPodcastFeed.swift:95`, bisher ungelesen).
- **Audio:** `AudioRetention` (`AudioRetention.swift:91-106`) erfüllt den Wunsch schon. Eine Änderung: `prefetchNewestEpisodes` lädt nur, wenn „Neueste Folge je Podcast behalten“ an ist.

## 8. KI-Wahl

Ich empfehle, bei Apple Intelligence zu bleiben. Die Klassifizierung ist eine Auswahl aus einer Liste, und dafür bringt das SDK geführte Ausgabe mit Laufzeitlisten und einen eigenen Anwendungsfall mit. Schnell und genau wird das Tagging vor allem durch die Vorsortierung ohne Modell. Ein größeres Modell ändert daran wenig. Ein mitgeliefertes 1 bis 3 B-Modell über MLX oder Core ML kostet etwa 0,7 bis 2 GB (Schätzung) und eigene Prompt-Pflege je Modell. Dazu kommen GPU-Last, Lizenzprüfung und die Rücknahme der Zusage „nur Apple“ in README und Datenschutzseite. Sein Vorteil wäre Durchsatz auf großen Archiven und Tags auf Geräten ohne Apple Intelligence. Seit 27 ließe es sich hinter dieselbe Session-API setzen (`LanguageModel`, FM:1483; `LanguageModelSession(model:)`, FM:1126). Eigene Adapter für Apples Modell gibt es in 27 nicht mehr (FM:508-515). Ein Mittelweg ist ein kleines Core-ML-Embedding-Modell unter 100 MB nur für das Ranking in Schritt 1. Das formuliert nichts, gilt aber streng gelesen als „anderes Modell“. Regel 4 in AGENTS.md ändert nur der Product Owner.

## 9. Etappen

**0.9 Fundament (L)**
- Umfang: Metadaten parsen und beim Refresh aktualisieren (`FeedParser.swift`, `Services.swift:351-390`, `limitationReason` zurücksetzen). JSON-Kapitel persistieren, Kapitel aus Beschreibungen lesen, `img`/`url` in `ChapterFile`. Publisher-Transkripte über `timedTranscriptURL` zuerst nutzen. Folgenseite nach Kapiteln gliedern (Zuordnung zur Laufzeit), „Original öffnen“ überall. Transkript-Prüfpunkt, Warteschlange persistieren, Fakten bei Abbruch sichern. BGAppRefresh entschärfen, lokale Mitteilung.
- Risiko: Doppelte Segmente beim Zusammenführen nach dem Fortsetzen. Unklar ist auch, wie SpeechAnalyzer eine Suspendierung verträgt.
- Test: `swift test` mit Feed-Fixtures (Kategorien, Zeitmarken, VTT), Zuordnung Kapitel zu Fakt, Merge mit Überlappung. UI-Test für „Original öffnen“. Fortsetzen nur auf dem Gerät: Transkript starten, App beenden, neu öffnen.

**0.10 Tags (L)**
- Umfang: Schemaänderungen aus Abschnitt 3 samt Migration, abgeleitete Abschnitte, Klassifizierungs-Pipeline (`PodcastAIIntelligence`, neu `ChapterClassifier`, `TagNormalizer` in `PodcastAIKnowledge`). Tag-Wolke mit Plus und Minus (`TopicTagRow`, `ListeningViews.swift:1078ff`), Freitextfelder weg, Tag-Seite, Tag-Eval.
- Risiko: CloudKit-Schema nach Production. Tag-Explosion, falls die Normalisierung zu locker ist. Qualität auf Deutsch ist unbekannt.
- Test: Normalisierer (USA, Vereinigte Staaten, iOS 27), Migration an einer Kopie einer 0.8-Datenbank, Löschregeln mit `StoredChapterTag`, UI-Test Plus/Minus, Eval mit Modell auf Wunsch.

**0.11 Generierte Podcasts (L)**
- Umfang: Feeds aus Tag-Sets mit UND, Kandidaten auf Kapitelebene, Teile zu 20 Minuten, Übersichtskarte, Cover je Ausgabe, gemeinsamer Player, Sprung ins Original (`PersonalEpisodePublisher`, `RelevanceScorer`, `Views.swift:510-1110, 2011ff`, `TopicCoverArtwork.swift`).
- Risiko: Das Player-Zusammenlegen berührt `PlaybackCoordinator` und Siri-Wege.
- Test: Publisher-Tests (kein Kapitel zweimal, Teil 2 entsteht, UND filtert, Budget hält 20 min). UI-Test Ausgabe öffnen, Kapitel antippen, Original öffnet.

**0.12 Trends, Widget, Hintergrund-Downloads (M)**
- Umfang: Trendzählung, „Neu“-Zahlen, Widget-Extension mit App Group, Hintergrund-URLSession, Mitteilung „Neue Ausgabe“.
- Risiko: Die Sicherheitsprüfungen im Download-Delegaten dürfen nicht schwächer werden. Neue Targets in `project.yml`.
- Test: Trendzählung mit festen Daten, Widget-Snapshot, Download-Abbruch und Wiederaufnahme auf dem Gerät.

## 10. Offene Entscheidungen

1. **Regel 4, fremdes Modell:** Vorschlag: bei Apple bleiben, erst nach der Tag-Eval neu bewerten.
2. **Embedding-Modell für die Vorsortierung:** Vorschlag: nein, `NLEmbedding` reicht vorerst.
3. **Cover über das veraltete `ImageCreator`:** Vorschlag: behalten, mit Layoutcover als Rückfall, keine neuen Funktionen darauf bauen.
4. **Gesprochenes Intro:** Vorschlag: nein, sichtbare Übersichtskarte.
5. **Trendschwellen:** Vorschlag: 7 Tage, Faktor 3, mindestens 3 Quellen, mindestens 5 Kapitel.
6. **Vorhaben und Fragen als Interessenart:** Vorschlag: in der Oberfläche ausblenden, im Schema behalten, vorhandene Einträge zu Tags machen.
7. **Neue Tags sichtbar ab:** Vorschlag: ab zwei Quellen.
8. **Ausgabenlänge:** Vorschlag: fest 20 Minuten, in den Feed-Einstellungen änderbar.
9. **`RelevanceScorer` als Rückfall:** Vorschlag: ja, für Geräte ohne Apple Intelligence.
10. **YouTube ohne Ton:** Vorschlag: auf der Folgenseite offen sagen, dass es dort nur Metadaten und Beschreibungskapitel gibt, außer es gibt ein Publisher-Transkript oder einen passenden Audio-Podcast.

## 11. Ergänzungen aus der Gegenprüfung


- **0.9:** Fakten decken jedes Kapitel ab, mit einer Quote je Kapitel statt `evenlySpaced` über die ganze Folge. `factLimit` wird je Kapitel skaliert.
- **0.9:** Hintergrund-Downloads. Den Redirect nach dem Laden über `task.currentRequest.url` bzw. `response.url` prüfen, Größe und MIME-Typ in `didFinishDownloadingTo` kontrollieren, bei einem Verstoß die Datei löschen. Mobilfunk über `allowsCellularAccess` und `allowsExpensiveNetworkAccess`.
- **0.9/0.10:** Alle Schemaänderungen (Metadaten und `StoredChapterTag`) gehen gemeinsam in einem Deploy nach Production.
- **0.10:** Kennung von `StoredChapterTag` deterministisch aus Medienfassung, Kapitelstart und Tag-Schlüssel.
- **0.10:** Beim Zusammenlegen von Tags werden `interestIdentifier` und `topicIDs` auf die überlebende Kennung umgeschrieben.
- **0.10:** Der „Oberbegriff“ wird nur aus Kandidaten gewählt, die der Code erzeugt hat. Das Modell formuliert keine freien Labels (Regel 3).
- **0.10:** Backfill-Klassifizierung der Bibliothek, neueste Folgen zuerst, fortsetzbar.
- **0.10:** Für `BGProcessing` eine eigene leichte Aufgabe für das Tagging ohne `requiresExternalPower`, falls die Messung das trägt.
- **Offene Entscheidung:** Heißt Minus „nicht folgen“ oder „stumm“?
- **Offene Entscheidung:** Gibt es neben den Tags einen Kurztext je Kapitel?
- **Offene Entscheidung:** PCC als Rückfall fürs Tagging, wenn das Gerätemodell fehlt oder zu langsam ist?
- **0.11:** Teil 2 und der Sprung ins Original direkt nach 0.9. Die Player optisch angleichen, das Zusammenlegen später.
- **0.11:** Ausgaben ohne KI-Cover bekommen es beim nächsten Wechsel in den Vordergrund.
- **0.11:** Kopf mit Statistik im Tab „Themen-Updates“ (neue Aussagen je Tag seit dem letzten Hören).
- **0.12:** Ein automatischer Feed „Angesagt“ aus den Trend-Tags. Auch er startet keinen Ton (Regel 1).
- **Hinweis Wiedergabe:** Nach „Audio nach dem Transkript entfernen“ spielen Ausgaben aus dem Stream (`playbackURL`, `app/Apps/Shared/Services.swift:755-756`). Offline laufen sie also nicht, und wenn die Quelle andere Werbung einfügt, verschieben sich die Zeiten. `mediaVersionIdentifier` muss vor dem Einfügen einer Stelle geprüft werden.
## 12. Entscheidungen des Product Owners (24. September 2026)

1. Plus heißt: dem Tag folgen. Minus heißt: dem Tag nicht mehr folgen. Das Tag bleibt sichtbar und neutral, es wird nur nicht mehr gesammelt. Ein eigenes „stumm“ gibt es nicht.
2. Je Kapitel gibt es neben den Tags einen Satz, worum es geht, als Zusammenfassung gekennzeichnet.
3. Fehlt das Gerätemodell oder ist es zu langsam, erzeugt Private Cloud Compute die Tags. Abschaltbar wie heute.
4. Die App bleibt bei Apple Intelligence. Nach der Tag-Messung in 0.10 wird neu bewertet.

## 13. Erweiterung: einzelne Folgen und YouTube besser abonnieren

Stand heute: Ein direkter Audiolink landet in der Sammelquelle „Einzelne Folgen“ (`Services.swift:333`). Ein YouTube-Video, eine Playlist oder ein @-Name führt zum ganzen Kanal (`SourceResolver.swift:18-38`). Eine einzelne Folge aus Apple Podcasts, aus dem Katalog oder aus einem abonnierten Feed lässt sich nicht allein holen, und ein YouTube-Video nicht ohne seinen Kanal.

### Einzelne Folgen

- **Überall „Nur diese Folge“:** Im Katalog, in der Podcast-Vorschau vor dem Abonnieren und bei eingefügten Links gibt es neben „Abonnieren“ den Knopf „Nur diese Folge“. Die Folge kommt in die Bibliothek, ohne dass der Podcast abonniert wird.
- **Links, die eine Folge meinen:**
  - Apple Podcasts mit `?i=<Folgenkennung>`: Lookup über `itunes.apple.com/lookup?id=…&entity=podcastEpisode`, dann die Folge im Feed über `guid` oder Audioadresse suchen.
  - Direkte Audio- und Videodateien wie heute.
  - Folgenseiten von Podcast-Hostern (Podigee, Podlove, Transistor, Libsyn und andere): Die Seite nennt Feed und Folge (`og:audio`, `<enclosure>`, `podcast:guid`). Der Code sucht die Folge im Feed.
  - Overcast und Pocket Casts: Die Links führen über die Folgenseite zum Feed.
  - YouTube-Video: siehe unten, „Nur dieses Video“.
- **Ordnung:** Einzelne Folgen stehen unter ihrem echten Podcast mit Cover und Titel, gekennzeichnet als „nicht abonniert“. Die Sammelquelle „Einzelne Folgen“ bleibt nur für Dateien ohne erkennbaren Podcast. Aus jeder solchen Folge lässt sich der Podcast später mit einem Tipp abonnieren. Die schon geladenen Folgen bleiben dabei erhalten.
- **Gleich behandelt:** Transkript, Fakten, Kapitel, Tags, Chat und Themen-Podcasts gelten auch für einzelne Folgen. Einzelne Folgen wählt der Nutzer bewusst aus, deshalb laufen sie in der Warteschlange vor dem Archiv. Die Regeln für den Ton gelten wie bei allen anderen Folgen.
- **Teilen in die App:** Eine Share Extension auf iOS und Mac übernimmt Links aus Apple Podcasts, YouTube, Safari und anderen Apps: „An PodcastAI senden“. Dazu kommen Audiodateien aus Dateien und AirDrop. Die Erweiterung legt nichts an. Sie übergibt den Link an die App, und die zeigt die Vorschau mit „Abonnieren“ oder „Nur diese Folge“. Dafür braucht es ein neues Target und eine App Group, dieselbe wie für das Widget.
- **Datenmodell:** Kein neues `@Model`. `StoredSource` bekommt `isSubscribed: Bool = true`, damit ein Podcast mit einzelnen Folgen nicht als Abo zählt: keine automatische Aktualisierung und kein Abo-Export. Das Feld ist additiv und geht mit demselben Schema-Deploy wie die Tags nach Production.

### YouTube besser abonnieren

- **Jeder Link führt zum Kanal:** `youtube.com/watch`, `youtu.be`, `/shorts/`, `/live/`, `music.youtube.com`, `/@name`, `/channel/UC…`, `/c/…`, `/user/…` und Playlists. Die Vorschau zeigt Kanalbild, Name, Beschreibung und die neuesten Videos. Zur Auswahl stehen „Kanal abonnieren“, „Nur dieses Video“ und, falls vorhanden, „Passenden Audio-Podcast abonnieren“ (heute `PodcastCounterpart`). Den Audio-Podcast empfiehlt die App zuerst, weil es nur mit Ton Transkript, Fakten und Tags gibt.
- **Playlists abonnieren:** Eine Playlist ist eine eigene Quelle mit Feed `feeds/videos.xml?playlist_id=`. Heute führt eine Playlist zum Kanal.
- **Abos übernehmen:** Import der Datei `subscriptions.csv` aus Google Takeout (YouTube-Abos). Die Liste zeigt, welche Kanäle einen Audio-Podcast haben. Man wählt aus und abonniert alles auf einmal. Ohne Google-Konto und ohne Schlüssel.
- **Suche nach Kanälen:** Ohne API-Schlüssel gibt es keine offizielle YouTube-Suche. Die App sucht deshalb den Namen im Katalog, also bei Apple und Podcast Index, und bietet gefundene Audio-Podcasts an. Einen YouTube-Kanal abonniert man über seinen Link oder über das Teilen aus der YouTube-App. Die Share Extension macht das zum normalen Weg.
- **Mehr aus dem Feed holen:** Der YouTube-Feed liefert nur die 15 neuesten Videos. Die App speichert jedes gesehene Video, damit die Liste über die Zeit wächst. Ältere Videos lassen sich nicht nachladen, und die Kanalseite sagt das.
- **Kapitel aus der Beschreibung:** Zeitmarken wie `00:00 Intro` in der Videobeschreibung werden zu Kapiteln mit Tags und Satz je Kapitel (siehe 0.9).
- **Ohne Ton bleibt es bei Metadaten:** YouTube liefert der App keinen Ton, und die App lädt ihn auch nicht über Umwege. Das gilt wegen der Nutzungsbedingungen. Die Kanalseite sagt klar, was es gibt: Titel, Beschreibung, Kapitel, Tags aus Titel und Beschreibung, Abspielen in der YouTube-App. Transkript und Fakten gibt es nur über den passenden Audio-Podcast.

### Einordnung in die Etappen

- **0.9:** „Nur diese Folge“ im Katalog, in der Vorschau und bei Folgenlinks von Apple und Hostern. Einzelne Folgen unter ihrem echten Podcast. YouTube-Links aller Formen mit Vorschau und den drei Möglichkeiten, Playlists als Quelle, Kapitel aus Beschreibungen.
- **0.10:** Das Feld `isSubscribed` kommt in denselben Schema-Deploy wie die Tags.
- **0.12:** Die Share Extension mit derselben App Group wie das Widget, dazu der Import von Takeout-Abos.

### Offene Entscheidung

- **YouTube-Untertitel als Transkript:** YouTube bietet Untertitel an, aber nicht über eine offizielle, schlüssellose Schnittstelle. Vorschlag: nicht nutzen und bei „nur Metadaten, Transkript über den Audio-Podcast“ bleiben.
