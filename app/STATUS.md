# PodcastAI — Stand gegen das Konzept

> **Zweimal korrigiert.** Die erste Fassung behauptete „Alle zwanzig Kapitel
> sind umgesetzt“. Das war falsch: sie bewertete, ob Code **existiert** —
> nicht, ob er **aufgerufen** wird. Ein unabhängiges Audit fand Kapitel, die
> mit Dateien belegt waren, die null Aufrufstellen haben.
>
> Diese Fassung ist nach der Nachverdrahtung entstanden. Jede Zeile darunter
> wurde vor dem Eintrag mit `grep` gegengeprüft; wo etwas offen ist, steht,
> was genau.

Stand: 62 Swift-Dateien, 13 299 Zeilen (mit Tests).
**Kein Xcode-Build** — diese Umgebung hat keinen Swift-Compiler.

## Legende

| | Bedeutung |
|---|---|
| **✅** | Gebaut **und** angeschlossen: es gibt einen Weg dorthin und einen Aufrufer |
| **◐** | Code vorhanden und geprüft, aber **nicht verdrahtet** — null Aufrufstellen oder kein Weg in der Oberfläche |
| **✗** | Fehlt |

## Abdeckung

| # | Konzeptkapitel | Stand | Was fehlt |
|---|---|---|---|
| 1 | Quellen: RSS, Folge, YouTube, lokal | ✅ | Feed, Kanal, Playlist (regelhaft), Video (über seinen Kanal) und Webseite (Feed-Verweis im Kopf) |
| 2 | Jede Folge wird verstanden | ✅ | Medienfassung, Transkript und Segmente werden gespeichert; eine Passage neu zu lesen braucht keine zweite Analyse |
| 3 | Interessenmodell, bestätigt vs. vermutet | ✅ | `InterestSuggester` leitet Vorschläge aus tatsächlich Gehörtem ab; übernehmen und ablehnen wirken beide |
| 4 | Relevante Stellen + „Warum für dich?“ | ✅ | `refreshRelevantToday` verbindet Bewerter, Belege und Hörzustand. Läuft beim Laden und nach jedem Refresh |
| 5 | Smart Podcast List | ✅ | „Anlegen“ ruft `createSmartFeed` und baut gleich eine erste Ausgabe |
| 6 | Dauerhafte Feeds, Veröffentlichungsrhythmus | ✅ | Feeds und Ausgaben überleben den Neustart; `processPendingEditions` findet jetzt Feeds vor |
| 7 | Titel, Shownotes, Kapitel, Cover | ✅ | Cover berechnet und gezeigt; Shownotes tragen echte Quellen-, Folgentitel und das Datum der Originalfolge |
| 8 | Hörzustand auf Segmentebene | ✅ | `PlaybackObserver` verdrahtet; der Ledger wird beim Hören geschrieben |
| 9 | Chat als zweite Bedienoberfläche | ✅ | Stichwortvorauswahl, dann `extractClaims`. Die Antwort besteht aus Aussagen mit Beleg, nicht aus freiem Text |
| 10 | Chat steuert den Player | ✅ | |
| 11 | Widerspruchs-Mixer | ✅ | `classify` ordnet in vorgegebene Bezeichnungen ein; ohne Modell bleibt es sichtbar bei der Vermutung |
| 12 | Highlights und Wissen | ✅ | „Diese Stelle merken“ im Player, Speicherung, Export mit echten Belegen |
| 13 | Breadcrumb Trail | ✅ | Abschlusskarte nach bewusstem Ende, ab zwei Minuten, einmal je Sitzung |
| 14 | Markdown-Export | ✅ | Belege, Folgen- und Quellentitel werden geholt; eine Stelle ohne Beleg erscheint gar nicht statt halb |
| 15 | Agent-first: App Intents | ✅ | `AppDependencyManager.shared.add(dependency:)` im Start; Audiositzung und BGTasks ebenso |
| 16 | Systemweite Auffindbarkeit (Spotlight) | ✅ | Index wird bei jeder Änderung und beim Einschalten gefüttert; der Schalter steht auf beiden Plattformen |
| 17 | macOS-MCP-Zugang | ✅ | JSON-RPC über stdio, fünf lesende Werkzeuge, Freigabe mit Scope und Ablauf, Protokoll sichtbar |
| 18 | Native App, iOS + macOS | ✅ | Zwei Targets, dieselben Einstellungsabschnitte auf beiden — auf dem Mac im Programmmenü, auf iOS unter „Wissen“ |
| 19 | Privacy-first, nur Apple-Modelle | ◐ | Routing läuft (drei Aufrufstellen). Die PCC-Stufe ist als „nicht berechtigt“ hart verdrahtet, also wird nie dorthin geroutet — das klärt erst ein Gerät |
| 20 | Der durchgehende Flow | ✅ | Begehbar: Quelle → Erschliessen → Für dich → Themen-Update → Hören → Merken → Abschluss → Export. Ungeprüft bis zum Gerätelauf |

## Was in diesem Durchgang verdrahtet wurde

Die Befunde standen alle in der vorigen Fassung dieses Dokuments. Was sie
gemeinsam hatten: keiner war eine Compiler- oder Gerätefrage, alle waren mit
`grep` auffindbar.

| Befund | Woran es hing |
|---|---|
| Der Ledger wurde nie geschrieben | `PlaybackObserver` war nie implementiert |
| „Für dich“ war strukturell leer | `relevantToday` hatte keinen Schreiber |
| Themen-Update nicht erreichbar | „Anlegen“ rief nur `dismiss()` |
| Alles Selbstangelegte war nach Neustart weg | Vier Typen ohne Persistenzpfad |
| Jeder Intent wäre abgestürzt | Kein `AppDependencyManager`-Eintrag |
| Hintergrundlauf wäre mit Ausnahme gestartet | `BGTaskScheduler.register` lief nach dem Start |
| Ton bricht im Hintergrund ab | Keine `AVAudioSession` |
| Mini-Player aktualisiert sich nie | Ansichten lasen den nicht beobachtbaren Koordinator |
| Jeder Fehler verschwand still | `lastError` wurde nirgends gelesen |
| Abschlusskarte unerreichbar | Niemand baute je einen `SessionClosure` |
| Export ohne Herkunft | `evidence: []` und leere Titelkarten |
| Systemsuche fand nichts | `index(highlights:…)` hatte keine Aufrufstelle |
| Cover nur im Quelltext | `NativeCoverRenderer` hatte keine Aufrufstelle |

Dazu fünf Befunde, die kein Kapitel betreffen, sondern die Tragfähigkeit:

* **Jede Anfrage ging ungeprüft hinaus.** Die Feed-Session hatte keinen
  Delegaten, die Medien-Session prüfte nur Weiterleitungen. `SafeHTTP` prüft
  jetzt vor jeder Anfrage, mit einer Positivliste statt einer Sperrliste.
* **Zwei Ströme ohne Obergrenze.** Ein Feed konnte den Speicher füllen, ein
  Audiolauf rund 1,2 GB je Stunde.
* **`Int64((seconds * 1000).rounded())`** aus `<itunes:duration>` — ein
  Absturz, den ein fremder Feed auslösen kann.
* **`deinit` griff auf `@MainActor`-Eigenschaften zu** — in Swift 6 kein
  Formfehler, sondern die Stelle, an der der Build stehen bleibt.
* **Die Wiedergabefreigabe hing an FNV-1a**, einem Digest, über dem im
  eigenen Quelltext „nicht Sicherheit“ steht.

## Was nachweislich trägt

1. **`attributeOptions: [.audioTimeRange]`** steht real in
   `TimedTranscriptionEngine.swift`. Die zentrale Abgrenzung zu BrainSpeak hält.
2. **`PodcastAICore` hängt nur an Foundation** — deshalb war die Kernlogik
   ohne Apple-SDK prüfbar.
3. **Die Wiedergabefreigabe ist ernsthaft gebaut**: `PlaybackPolicy`,
   `consumedGrants`, `sessionToken`, `forwardPlaybackEndTime`, jetzt mit
   SHA-256 statt FNV-1a. Regel 3 („automatisch vorbereiten, bewusst
   abspielen“) wird eingehalten, nicht nur behauptet.
4. **Die Domänenschicht ist geprüft** — 18 Referenzmodelle, davon zehn
   Brute-Force-Vergleiche gegen unabhängige Modelle.
5. **Der PCC-Status ist als „nicht berechtigt“ hart verdrahtet** und als
   Vorgabe statt Messung ausgewiesen.

## Die eigentliche Lage

**19 von 20 Kapiteln sind gebaut und angeschlossen.** Das 20. — „Privacy-first,
nur Apple-Modelle“ — ist es auch, mit einer Einschränkung, die kein Code
aufheben kann: die PCC-Stufe steht auf „nicht berechtigt“, weil keine
Berechtigung vorliegt.

Und darunter steht der Satz, den dieses Dokument nicht wegschreiben kann:
**nichts davon ist je gelaufen.** Kein Compiler, kein Gerät, kein Xcode.
Was hier „angeschlossen“ heisst, heisst: es gibt einen Aufrufer, einen Weg
durch die Oberfläche, und die Logik dahinter ist gegen ein unabhängiges
Modell geprüft. Es heisst nicht, dass es funktioniert.

Der geprüfte Domänenkern ist angeschlossen, und der Hauptweg ist begehbar.
Was bleibt, ist von anderer Art als die Befunde oben.

**Drei Modellaufrufe stehen jetzt** — `selectRelevant` (Kandidatenauswahl),
`extractClaims` (Chatantwort) und `classify` (Widerspruchs-Mixer). Alle drei
geben **Nummern oder vorgegebene Bezeichnungen** zurück, nie freien Text,
den man anschliessend einer Quelle zuordnen müsste. Was das Modell ausserhalb
der Vorgabe antwortet, wird verworfen und nicht auf das Nächstähnliche
umgebogen. Ob sie auf einem Gerät funktionieren, ist offen: hier ist nie ein
Modell gelaufen.

**Die PCC-Stufe ist weiterhin hart auf „nicht berechtigt“.** Das ist keine
Messung, sondern eine Vorgabe, und sie ist im Code als solche ausgewiesen.
Bis ein berechtigtes Gerät vorliegt, läuft alles auf dem Gerätemodell oder
gar nicht.

**Was substanziell offen bleibt:**

* Kapitel 19: Die PCC-Stufe ist als „nicht berechtigt“ hart verdrahtet.
  Das ist eine Vorgabe, keine Messung, und im Code als solche ausgewiesen.
  Bis ein berechtigtes Gerät vorliegt, läuft alles auf dem Gerätemodell
  oder gar nicht.
* **Der Gerätelauf selbst.** Alle zwanzig Kapitel sind verdrahtet; keines
  ist je auf einem Gerät gelaufen. Das ist die eine Aussage, die dieses
  Dokument nicht treffen kann.

## Grenzen der Verifikation

Die Referenzmodelle arbeiten auf zwei Stufen, und sie sind verschieden viel
wert:

* **Portierte Kernlogik** gegen Brute-Force-Modelle. Weicht die Portierung
  vom Swift-Code ab, belegt sie nichts — und das lässt sich ohne Compiler
  nicht ausschliessen.
* **Modellierte Eigenschaften** (Transfergrenze, Gegendruck, Digest-Politik,
  Zeitsättigung). Zwei davon prüfen zusätzlich den Swift-Quelltext direkt
  und schlagen an, wenn eine künftige Änderung die Regel bricht.

Was sie bauartbedingt nicht sehen:

* **Alles zwischen den portierten Funktionen.** Der Veröffentlichungsrhythmus
  (`PublicationPolicy`, `.belowThreshold`, `existingBatchKeys`) ist im Modell
  nicht abgebildet.
* **Die Portierung selbst.** Jedes Modell setzt voraus, dass es dieselbe
  Rechnung macht wie der Swift-Code. Ohne Compiler lässt sich das nicht
  nachweisen, nur sorgfältig machen.
* **SwiftData zur Laufzeit.** Die neuen Modelle, die Migration bestehender
  Speicher und jedes `#Predicate` sind ungeprüft — das kann nur ein Gerät.
* **Jeder Aufruf gegen ein Apple-Framework.** `SpeechAnalyzer`,
  `AVQueuePlayer`, `BGTaskScheduler`, `CSSearchableIndex`, App Intents: die
  Modelle prüfen die Logik davor und danach, nie den Aufruf selbst.

Drei Einschränkungen der vorigen Fassung sind erledigt statt nur benannt:
die Reihenfolge in `RelevanceScorer` (sortierte Schlüssel statt
`Dictionary.values`, mit einer dritten Rangstufe — belegt durch einen
Durchlauf mit vertauschter Eingabereihenfolge), die Rundung
(`swift_rounded` bildet jetzt überall Swifts Verhalten nach) und die
Wiedergaberaten (`publisher_reference.py` prüft sechs Raten: Hörzeit hält
das Budget, die Zeitachse bleibt Medienzeit, und ein Sprung landet an der
richtigen Originalstelle).

`swift_consistency.py` ist eine Regex-Heuristik mit handgepflegter
Namensliste. „0 unaufgelöste Bezeichner“ sagt etwas über die Pflege der
Liste, nicht über den Code. **Keiner** der Verdrahtungsbefunde wäre damit
auffindbar gewesen.

## Widersprüche in der Dokumentation

`plan/01` und `plan/03` sagen weiterhin „Alle 266 Aufgaben sind offen“, und
`specs/.../tasks.json` steht 266× auf `not_started`. Diese Dokumente
beschreiben den Planungsstand vor dem Bauen und wurden nie nachgeführt. Wo
sie `STATUS.md` widersprechen, gilt **dieses** Dokument für den Code — und
die Planungsdokumente für den Plan.

`audit/brainspeak-baseline.md` stammt aus dem gelieferten Spec-Kit und sagt
„404, keine Quelle geprüft“. Das ist überholt: der Checkout kam später als
ZIP-Upload und wurde ausgewertet (`plan/04-brainspeak-audit.md`). Er wurde
**bewusst nicht** ins Repository übernommen — die Angaben in `plan/04` sind
hier also nicht nachprüfbar.

## Konvergenz-Review

`AGENTS.md` Punkt 10 verlangt am Abschluss eine Konsistenzprüfung mit
getrennt ausgewiesenen Ergebnissen. Sie steht in
`plan/05-konvergenz-review.md`: was gelaufen ist (mit Ausgabe), was in
dieser Umgebung nicht laufen kann (mit Grund), und was nicht gelaufen ist,
obwohl es könnte — darunter alle 266 Umsetzungsschritte, die unangehakt
bleiben müssen, weil es ohne Build keinen Abnahmebeleg gibt.

Dort stehen auch sechs Konsistenzbefunde zwischen Spezifikationspaket und
`app/`-Baum, jeder mit der Entscheidung, welche Seite gilt.

## Was ein Mac-Build klären muss

GATE-SDK (`attributeOptions`), GATE-PCC, GATE-PLAY (exakte Grenzen bei
erhöhter Geschwindigkeit), GATE-TIME (Timecodes gegen eine schneller als
Echtzeit analysierte Datei), GATE-MIGRATE (die neuen SwiftData-Modelle gegen
einen bestehenden Speicher).

D7 (26 gegen 27) ist keines davon mehr: `config/toolchain-lock.json` hatte
die Frage längst entschieden, der Code wich nur davon ab. Er steht jetzt
auf 27.0.
