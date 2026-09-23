# Beta-Feedback zur ersten TestFlight-Runde

**Wer das schreibt und woher er es weiß.** Ich habe die App nicht bedient —
es gibt hier kein Gerät und keinen Compiler. Das hier ist deshalb kein
Testbericht, sondern eine Durchsicht der Nutzerpfade im Quelltext mit der
Frage: *was erlebt der erste Tester?*

Das trennt die Befunde in zwei Sorten, und ich halte sie getrennt:

- **Belegt** — im Code nachlesbar, unabhängig vom Gerät.
- **Zu messen** — Mechanismus klar, Ausmaß nicht. Steht als Frage, nicht
  als Behauptung.

Reihenfolge nach dem, was einen Tester zuerst trifft.

---

## 1. Die Erfolgsmeldung erscheint nie · belegt · behoben

Beim Hinzufügen einer Quelle:

```swift
activity = "Link wird geprüft …"
defer { activity = nil }
…
activity = "„\(added.title)“ aufgenommen · \(added.episodeCount) Folgen gefunden"
```

Das `defer` läuft beim Verlassen der Funktion — also **nach** der
Erfolgsmeldung. Sie wird gesetzt und sofort wieder gelöscht. Der Tester
sieht „Link wird geprüft …", dann nichts.

Genau dasselbe bei „Feeds werden aktualisiert": das Ergebnis („3 neue
Folgen" / „Keine neuen Folgen") ist unsichtbar. Der Nutzer zieht zum
Aktualisieren, sieht kurz einen Text, und weiß danach nicht, ob etwas
passiert ist.

Das betrifft die beiden häufigsten Handlungen der App.

## 2. Heruntergeladene Medien gehen ins iCloud-Backup · belegt · behoben

Die Dateien landen unter Application Support, und nirgends steht
`isExcludedFromBackup`. Folgen:

- Das iCloud-Backup des Testers wächst um jede analysierte Folge. Bei
  einer Obergrenze von 2 GB **pro Datei** ist das kein Randfall.
- Apples Data Storage Guidelines verlangen ausdrücklich, dass
  nachladbare Inhalte vom Backup ausgenommen werden. Das ist ein
  bekannter Ablehnungsgrund im App Review — er würde also nicht erst
  einen Tester ärgern, sondern die Freigabe kosten.

## 3. Es gibt keinen Weg, Speicher wieder freizugeben · belegt · halb behoben

Gelöscht wird eine Mediendatei nur, wenn der Download fehlschlägt. Es gibt
keine Übersicht, keinen „Folge entfernen"-Befehl, kein automatisches
Aufräumen und keine Obergrenze über alle Dateien hinweg.

Wer zehn Folgen erschließt, hat mehrere Gigabyte auf dem Gerät und als
einzige Möglichkeit, sie loszuwerden: die App löschen. Das ist die Art
Befund, die in einer Beta als „App frisst meinen Speicher" zurückkommt.

**Das ist eine Produktentscheidung, keine Zeile Code.** Zu klären: Wird
die Audiodatei nach der Analyse überhaupt noch gebraucht? Belege und
Transkript liegen danach in der Datenbank; fürs Abspielen der
Originalstelle wird die Datei gebraucht. Also: behalten und verwalten, oder
verwerfen und bei Bedarf neu laden?

**Gebaut ist die Hälfte, die diese Frage offen lässt:** ein
Speicher-Abschnitt in den Einstellungen beider Plattformen mit Gesamtgröße,
Liste je Folge, Löschen einzeln und gesamt, und einem eigenen Eintrag für
Reste abgebrochener Downloads. Darunter steht, was Löschen kostet — die
Audiodatei — und was nicht: Notizen, Belege und Hörzustand bleiben, und die
Wiedergabe meldet eine fehlende Datei von selbst als „Medium nicht
verfügbar".

**Nicht gebaut: eine Regel, die von selbst aufräumt.** Genau die wäre die
Antwort auf die offene Frage, und die gehört dir.

## 4. Der Download liest Byte für Byte · Mechanismus belegt, Ausmaß zu messen

`SafeHTTP.save` iteriert über `URLSession.AsyncBytes`:

```swift
for try await byte in stream {
    total += 1
    …
}
```

Das ist **eine asynchrone Iteration pro Byte.** Eine 50-MB-Folge sind 50
Millionen Durchläufe, eine 200-MB-Folge 200 Millionen.

Ich habe das selbst so gebaut, um die Größengrenze *während* der
Übertragung durchzusetzen statt danach — und ich habe den Preis im
Quelltext vermerkt, aber nicht gemessen. Für einen Tester heißt das
womöglich: der Fortschritt bleibt lange stehen, das Gerät wird warm, der
Akku fällt.

**Zu messen beim ersten Gerätelauf:** Dauer und CPU-Last für eine Folge
von ~60 MB, verglichen mit der reinen Netzzeit.

**Wenn es sich bestätigt**, ist der Weg `URLSessionDownloadTask` mit einem
Delegaten, der in `didWriteData` die Grenze prüft und bei Überschreitung
abbricht. Das behält die Grenze *während* der Übertragung und überlässt
das Schreiben dem System. Es ist umständlicher — aber wenn die Messung
schlecht ausfällt, ist es die richtige Umständlichkeit.

## 5. Analyse: kein Abbruch, kein Hintergrund · belegt · behoben

Nach „Erschliessen" gibt es keinen Abbruch. Das Transkribieren einer
90-Minuten-Folge dauert; wer versehentlich die falsche Folge erwischt hat
oder das Haus verlassen will, kann nur die App beenden — und weiß nicht,
was dann mit dem halben Ergebnis passiert.

Die Pipeline war auf Abbruch vorbereitet (`Task.checkCancellation` im
Transkriptionslauf), es fehlte nur der Knopf und das Festhalten der Task —
die Oberfläche warf einen losgelösten `Task` an und vergaß ihn.

**Behoben,** mit einer eigenen Stufe „abgebrochen" statt „fehlgeschlagen":
es ist nichts kaputt, es wurde gewollt.

**Und danach nachgezogen** (Rückmeldung: „Erschliessen muss auch im
Hintergrund klappen"). Der Knopf hieß erst „Von vorn erschliessen", weil
das die Wahrheit war. Jetzt heißt er **„Weiter erschliessen"**, weil die
Pipeline tatsächlich fortsetzt — siehe Abschnitt „Erschliessen im
Hintergrund" unten.

## 6. Der Startbildschirm schickt in die falsche Richtung · belegt · behoben

Die App öffnet auf „Für dich". Ohne Interessen steht dort:

> „PodcastAI zeigt dir erst dann relevante Stellen, wenn es weiß, wonach du
> suchst. Themen legst du unter ‚Interessen' an."

Richtig — aber nicht der erste Schritt. Interessen ohne Quellen ergeben
nichts. Die tatsächliche Reihenfolge ist: **Quelle → Folge erschließen →
Interessen → Für dich.** Dass „Erschliessen" ein eigener, bewusster
Schritt ist, steht nirgends auf dem ersten Bildschirm.

Ein Tester, der den Hinweis befolgt, legt Themen an, kehrt zurück, sieht
„Nichts Neues" — und hält das für kaputt.

**Behoben:** vier leere Zustände statt zwei, in der Reihenfolge der
tatsächlichen Kette. Jeder nennt genau den nächsten Schritt, und wo der in
einem anderen Bereich liegt, führt ein Knopf dorthin statt ihn nur zu
erwähnen. Der zweite Zustand ist der, den bisher niemand erwähnt hat:
**Abonnieren lädt nichts herunter und wertet nichts aus** — Erschliessen ist
eine eigene, bewusste Handlung.

## 7. Zwei gleichzeitige Vorgänge löschen sich die Anzeige · belegt · teilweise behoben

`activity` ist **ein** String für die ganze App. Sechs Stellen setzen ihn,
alle mit `defer { activity = nil }`. Wer eine Folge erschließt und
nebenbei Feeds aktualisiert, sieht die Meldung des einen Vorgangs
verschwinden, sobald der andere fertig ist.

Der Fortschritt je Folge (`stages`) ist davon nicht betroffen — der ist
korrekt je Folge geführt. Es geht nur um das Band oben.

**Halb behoben.** Die beiden Stellen aus Befund 1 räumen jetzt mit einer
Marke auf: wer inzwischen eine neuere Meldung gesetzt hat, behält sie. Die
vier übrigen Stellen (Analyse, Ausgabe, Chat) benutzen weiterhin `defer`
und räumen fremde Meldungen ab. Sie gleich mitzuziehen wäre möglich, aber
die eigentliche Frage ist eine andere: **ein Band für die ganze App ist
für nebenläufige Vorgänge die falsche Form.** Das ist ein Umbau, keine
Zeile — und er gehört erst gemacht, wenn aus Befund 4 feststeht, wie lange
eine Analyse überhaupt dauert.

---

## Erschliessen im Hintergrund

Rückmeldung nach der ersten Runde: *„Erschliessen der Folgen muss auch im
Hintergrund klappen."* Richtig — und es tat es an keiner Stelle.

**Was tatsächlich fehlte,** war mehr als ein Schalter:

- Der Analyse-Hintergrundtask war registriert und baute persönliche
  Ausgaben. Erschlossen hat er nie etwas.
- Die Analyse hing an der Oberfläche: wer die App verliess, verlor den Lauf.
- Ein abgebrochener Lauf fing von vorn an. Bei einer 90-Minuten-Folge und
  Fenstern von Minuten heisst das: sie wird **nie** fertig.

**Die Ursache lag tiefer als erwartet.** `LibraryStore.save(transcript:)`
liess ein vorhandenes Transkript unangetastet, mit der Begründung, eine
Neuanalyse bekomme eine neue Kennung. Das stimmte nicht:
`TranscriptAssembler.finish` bildet sie als `"<mediaVersionID>|<locale>"` —
ohne Revision. **Jede Neuanalyse wurde still verworfen.** Ein Zwischenstand
liess sich damit gar nicht speichern.

**Gebaut:**

| Stück | Warum |
|---|---|
| Prüfpunkte alle 5 Minuten Medienzeit | Ein Abbruch kostet höchstens diesen Abstand |
| Fortsetzen ab dem gesicherten Stand | Ohne das kommt eine lange Folge nie an |
| Mediendatei wird nicht erneut geladen | Sonst kostet jede Fortsetzung einen zweiten Download |
| Persistente Warteschlange | Ein Hintergrundlauf startet in einem frischen Prozess und muss erfahren, was offen ist |
| `beginBackgroundTask` beim Verlassen | Kauft ~30 s, um den nächsten Prüfpunkt zu erreichen — **nicht**, um fertig zu werden |
| `BGProcessingTask` arbeitet die Schlange ab | Das Fenster, in dem lange Arbeit erlaubt ist |
| Fehlerzähler je Auftrag | Eine kaputte Folge blockiert sonst jedes Fenster |

**Was ausdrücklich nicht gebaut ist:** Weiterrechnen im
Audio-Hintergrundmodus. Der ist für Wiedergabe da. Ihn für Dauerarbeit zu
benutzen ist der klassische Weg aus dem App Store — und unredlich gegenüber
dem Akku.

`analysisqueue_reference.py` prüft die Eigenschaft über 5 000 Zufallsfälle
mit zufälligen Fensterlängen: jede Folge wird fertig, nichts geht zurück,
die Reihenfolge hält, eine kaputte Folge blockiert nicht. Mit Gegenbeweis —
ohne Prüfpunkte wird eine 90-Minuten-Folge in 20-Minuten-Fenstern nie fertig.

**Die bekannte Grenze, ausdrücklich:** ein Fenster, das kürzer ist als der
Prüfpunktabstand, bringt nichts voran. Das ist der Grund, warum der Abstand
nicht grösser sein darf — und eine Zahl, die erst ein Gerätelauf bestätigen
kann. Sie hängt an Befund 4: wenn der Download tatsächlich so langsam ist
wie befürchtet, ist der erste Prüfpunkt unerreichbar weit weg.

---

## Was ich nicht beurteilen kann

Ehrlichkeitshalber getrennt, weil es die Hälfte der interessanten Fragen ist:

- **Ob überhaupt etwas übersetzt.** Nichts davon ist je durch einen
  Compiler gelaufen.
- **Wie gut die Transkription ist.** `SpeechAnalyzer` mit
  `attributeOptions: [.audioTimeRange]` ist die zentrale Wette dieser App.
  Ob die Timecodes auf die Sekunde stimmen, zeigt erst ein Gerät.
- **Ob die Modellantworten taugen.** Chat und Widerspruchs-Mixer rufen
  FoundationModels; hier ist nie ein Modell gelaufen.
- **Wie lange eine Analyse dauert.** Ohne diese Zahl ist nicht zu sagen, ob
  „Erschliessen" eine Handlung von Sekunden oder von einer Stunde ist —
  und davon hängt die ganze Bedienführung ab.

## Reihenfolge für die nächste Runde

Stand: 1, 2, 5 und 6 sind behoben, 3 und 7 zur Hälfte. Offen bleibt:

1. Nummer 4 **messen**, bevor irgendetwas anderes optimiert wird. Wenn der
   Download quälend langsam ist, erlebt der Tester nichts anderes.
2. Nummer 3 entscheiden — die einzige Produktfrage in dieser Liste. Die
   Verwaltung steht; es fehlt die Regel, ob überhaupt automatisch
   aufgeräumt werden soll.
3. Nummer 7 ganz lösen, wenn aus Nummer 4 feststeht, wie lange Vorgänge
   dauern — davon hängt ab, ob ein Band überhaupt die richtige Form ist.
4. Zwischenstand sichern, damit aus „Von vorn erschliessen" ein „Weiter"
   werden kann. Lohnt sich erst, wenn Nummer 4 zeigt, wie teuer ein Neuanfang
   wirklich ist.
