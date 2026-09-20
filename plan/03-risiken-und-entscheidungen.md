# Risiken und offene Entscheidungen

Dieses Dokument enthält, was den Plan zum Kippen bringen kann, und die Entscheidungen, die **vor M1** fallen müssen.

> **Revidiert am 2026-09-20 nach dem BrainSpeak-Ist-Audit** → [04-brainspeak-audit.md](04-brainspeak-audit.md).
> R1 ist geschlossen. Drei neue Risiken (R10–R12) und zwei neue Entscheidungen (D7, D8) sind hinzugekommen.

---

## 1. Top-Risiken

Bewertung: Auswirkung × Eintrittswahrscheinlichkeit auf Basis des heutigen Kenntnisstands. „Frühwarnsignal“ ist das,
woran man den Eintritt erkennt, bevor er teuer wird.

### R1 — BrainSpeak-Checkout unzugänglich · ✅ **geschlossen am 2026-09-20**

Der Checkout liegt vor und ist auditiert. MIT-Lizenz, vier Plattform-Targets, 11 145 Zeilen Swift, eine externe
Abhängigkeit (`KeyboardShortcuts`, nur macOS). Formal offen bleibt allein der Bezug auf einen echten Checkout mit
Commit und Branch — die Lieferung war ein ZIP ohne `.git`. Das ist Buchhaltung, kein Risiko mehr.

*Ersetzt durch:* R10, R11, R12.

### R2 — PCC-Entitlement wird nicht oder spät erteilt · hoch × mittel

Mehrfolgenvergleich, große Synthesen und der Watch-Weg hängen an Private Cloud Compute. Das Entitlement gehört dem
konkreten Entwicklerkonto und hat Vorlaufzeit.

*Gegenmaßnahme:* D2 sofort anstoßen, nicht erst in M4. Die Architektur trennt bereits On-Device und PCC über den
`AppleModelRouter`; fehlende Berechtigung ist ein ehrlicher Funktionszustand, **kein** Anlass für einen fremden
Anbieter (Constitution IV). Produktseitig heißt das: der Mehrfolgenvergleich wird in R2 ggf. als „nicht verfügbar“ gezeigt.
*Frühwarnsignal:* T003 schließt ohne erteilte Berechtigung.

### R3 — Exakte Segmentgrenzen halten in der Realität nicht · hoch × mittel

Versprechen V2 steht und fällt mit sauberen Ein- und Ausstiegen. Bekannte Fallen: Zeitbeobachter sind kein
Sicherheitsendanschlag, veraltete Callbacks nach Quellenwechsel, nicht seekbare oder unzuverlässig alignierte Streams,
Verhalten bei 1,5- und 2-facher Geschwindigkeit.

*Gegenmaßnahme:* GATE-PLAY in M6 statt am Ende (Abweichung A2). `forwardPlaybackEndTime` plus Lifecycle-/Session-Token
sind im Plan bereits vorgesehen. Ein Stream, der nicht exakt seekbar ist, wird nicht als exakt verkauft.
*Frühwarnsignal:* T102 zeigt Abweichungen über einer festzulegenden Toleranz.

### R4 — Hörhistorie auf Segmentebene wird zu spät ernst genommen · sehr hoch × mittel

Wenn T025 nur einen `played`-Bool schreibt, ist Versprechen V4 verloren: persönliche Ausgaben wiederholen Gehörtes,
und das Produkt verliert genau das Vertrauen, das es aufbauen soll. Nachrüsten heißt Historie verwerfen — das Paket
sieht dafür ausdrücklich `historyQuality=unknown` vor.

*Gegenmaßnahme:* T025 ist in M2 als Meilensteinkern markiert, nicht als Nebenaufgabe. GATE-LEDGER prüft die globale
Intervallvereinigung über Feeds und Geräte hinweg.
*Frühwarnsignal:* In M2 entsteht kein Intervallmodell, sondern ein Fortschrittsfeld.

### R5 — Umfang: 266 Aufgaben sind für ein kleines Team sehr viel · hoch × hoch

Das Paket ist vollständig, aber nicht auf ein erstes Release zugeschnitten. US15/US16 (Mixer und Breadcrumb) allein
sind 60 Aufgaben — 23 % des Gesamtumfangs für zwei Funktionen, die kein Nutzer beim ersten Start braucht.

*Gegenmaßnahme:* D3 entscheiden. Die Meilensteinstruktur ist so geschnitten, dass R3 (nach M8a) bereits ein
vollständiges Produktversprechen zeigt. M9b ist ohne Bruch verschiebbar.
*Frühwarnsignal:* Nach vier Monaten ist R2 nicht erreicht.

### R6 — Hintergrundanalyse liefert weniger, als das Konzept nahelegt · mittel × hoch

„BrainSpeak versteht neue Inhalte“ klingt nach Nacht-Pipeline. Real sind BGAppRefresh und BGProcessing opportunistisch,
ContinuedProcessing braucht eine vorangehende Nutzeraktion im Vordergrund, und Thermal State, Low Power Mode und
Speichergrenzen halten Arbeit an Checkpoints an.

*Gegenmaßnahme:* GATE-BG früh in M3. Produktseitig Abdeckung als sichtbaren Zustand zeigen statt Vollständigkeit zu
suggerieren. Der Mac darf Batcharbeit übernehmen, bleibt aber optional.
*Frühwarnsignal:* T106 zeigt, dass eine typische Folge im Hintergrund nicht fertig analysiert wird.

### R7 — YouTube-Rechtslage schneidet Kapitel 1 kleiner als erhofft · mittel × mittel

Ein Atom-Feed bedeutet keinen Audiozugang. Verboten sind versteckte Extraktion, Scraping geschützter Captions und
Hintergrund-IFrames. Ohne Transkript gibt es kein Wissen und keinen Fokus — der YouTube-Teil kann in der Praxis auf
Metadaten plus sichtbaren offiziellen Player zusammenschrumpfen.

*Gegenmaßnahme:* D5 entscheiden, GATE-YT früh in M9a. Gefundene und tatsächlich analysierbare Folgen werden getrennt
gezählt — das ist bereits gefordert und sollte auch in der Oberfläche sichtbar sein.

### R8 — Vier Plattformen werden unterschätzt · mittel × hoch

Constitution VIII verbietet ausdrücklich das hochskalierte iPhone-Layout auf Mac und iPad und die Chat-Textwand auf
der Watch. Das ist Designarbeit, keine Anpassung von Breakpoints. US8 und US9 haben zusammen nur 13 Aufgaben — das ist
der am dünnsten geschnittene Teil des Pakets.

*Gegenmaßnahme:* Designarbeit für iPad, Mac und Watch parallel ab M3 starten, nicht erst in M8b. Die vier
Plattformbeschreibungen unter `design/platforms/` sind die Vorlage.

### R9 — Modellausgabe umgeht die Policy · hoch × niedrig

Das Risiko ist im Paket bereits sauber adressiert (Modell wählt IDs, Code löst auf; kein Profil hat Player-,
Keychain-, Dateisystem- oder freien Netzwerkzugriff; RSS und Tool-Ergebnisse sind untrusted Daten). Es bleibt in der
Liste, weil eine einzige Abkürzung unter Termindruck genügt, um es zu realisieren.

*Gegenmaßnahme:* Punkt 3 der Definition of Done — Rechte-, Scope- und Freigabeentscheidungen liegen in Swift-Policy,
nie in einem Prompt. Deterministische Policy-Tests vor den Adaptern.

### R10 — Die Erwartung kippt in eine der beiden falschen Richtungen · hoch × mittel

Das Paket beschreibt durchgehend eine **Erweiterung**. Der Audit zeigt einen zweigeteilten Befund, und **beide**
Verkürzungen davon sind gefährlich:

* *„Es ist ja nur eine Diktier-App, wir fangen bei null an.“* — Falsch. Die Verstehens-Pipeline existiert:
  persona-gefilterte Relevanzextraktion, strukturierte `@Generable`-Ausgaben, Kontextfensterverwaltung,
  Injection-Härtung, idempotente und wiederaufnehmbare Artefakte ([04 §2a](04-brainspeak-audit.md)). Wer das neu
  baut, wirft Wochen weg und verliert Eigenschaften, die im Bestand bereits richtig gelöst sind.
* *„Wir bauen auf BrainSpeak auf, das meiste steht schon.“* — Ebenfalls falsch. Quellen, Mediathek, segmentgenaue
  Wiedergabe, Index, Chat, Fokus, Export, App Intents, Spotlight und Hintergrundverarbeitung sind sämtlich Neubau.

*Gegenmaßnahme:* Die Formulierung in Constitution II und `plan.md` schärfen — Wiederverwendung betrifft die
**Sprach-, KI-, Verstehens-, Persistenz- und Plattformschicht**, nicht die Produktdomäne. Die ausgefüllte
Integrationskarte ([04 §5](04-brainspeak-audit.md)) benennt je Zuständigkeit erweitern / ersetzen / neu und ist die
verbindliche Referenz gegen beide Verkürzungen.
*Frühwarnsignal:* Eine Schätzung, die M1 als „Anpassung“ führt — oder ein Ticket „Faktenextraktion implementieren“.

### R11 — Fehlende Herkunftsbindung wird zu spät bemerkt · sehr hoch × mittel

Zwei zusammenhängende Befunde. `SpeechTranscriber` wird mit `attributeOptions: []` erzeugt, `TranscriptionResult`
trägt nur Text, ein `isFinal`-Flag und eine Wanduhrzeit. Und die Extraktion endet in
`markdownBullets: String` — Prosa ohne `EvidenceID` und ohne Zeitbereich. Versprechen V1 und V2 stehen beide darauf.
Entsteht in M3 auch nur eine Charge Segmente, Claims und Evidence ohne Herkunft, ist jedes darauf aufbauende
Artefakt wertlos und muss neu erzeugt werden — inklusive der Analysekosten.

**Besonders tückisch:** `Utterance.t` existiert und *sieht aus wie* eine Zeitangabe, ist aber Wanduhrzeit seit
Sessionstart. Wird eine Datei schneller als Echtzeit eingelesen, liefert dieser Wert plausible, aber falsche
Zeitcodes. Ein falscher Timecode ist schlimmer als ein fehlender: er fällt erst beim Hören auf.

*Gegenmaßnahme:* Abweichung A5 — Herkunftsbindung ist die **erste** Aufgabe in M3, vor Segmenten und Claims. Neues
GATE-TIME, das ausdrücklich gegen eine Datei prüft, die schneller als Echtzeit analysiert wurde. Der Eingriff selbst
ist überschaubar: Zeitattribute anfordern, `CMTimeRange` durchreichen, `@Generable`-Ausgabetypen von String auf
Claims mit `EvidenceID` umstellen.
*Frühwarnsignal:* In M3 entstehen Claims, bevor `validation/transcript-timing.md` existiert.

### R12 — Versionssprung 26 → 27 wird als Buildeinstellung behandelt · hoch × mittel

BrainSpeak steht auf macOS 26.0, iOS 26.0, **watchOS 11.0**, Xcode 26, Swift 6.2. Das Paket fordert 27.0 auf allen
vier Plattformen, Xcode 27 und Swift 6.4 im Swift-6-Sprachmodus. Das hebt die Mindesthardware an, schließt
Bestandsnutzer aus und ist damit eine Produktentscheidung. Der watchOS-Wert ist zusätzlich in sich auffällig und
könnte bedeuten, dass die Watch nie mitgezogen wurde.

*Gegenmaßnahme:* D7 vor M1 entscheiden, mit ausdrücklichem ADR. GATE-SDK klärt anschließend, welche der im Paket
vorausgesetzten 27er-Symbole real existieren.
*Frühwarnsignal:* Der erste 27er-Build scheitert an Symbolen, für die es keine 26er-Entsprechung gibt.

### R13 — Die bestehende Diktier-App und ihre Nutzer werden vergessen · hoch × hoch

BrainSpeak ist kein Prototyp. Es gibt einen App-Store-Freigabe-Check, TestFlight-Verteilung, eine
`AppStoreExportOptions.plist`, echte Nutzerdaten in `iCloud.com.brainspeak.app` — und eine **bereits durchgeführte
Migration** des Datenmodells („real on-disk migration from the prior model, 2 MB byte-exact backfill/restore“,
`docs/AUDIO_SYNC.md`). Der Plan behandelt BrainSpeak bisher ausschließlich als Codebasis, nie als laufendes Produkt.

Das kollidiert direkt mit D8: eine Migration von der SwiftData-CloudKit-Spiegelung auf CKSyncEngine betrifft nicht
abstrakte Records, sondern die Aufnahmen bestehender Nutzer. Und es kollidiert mit D7: ein Sprung auf 27.0 sperrt
diese Nutzer aus, solange sie auf 26 sind.

*Gegenmaßnahme:* D9 entscheiden, **vor** D7 und D8 — denn D9 bestimmt deren Antwort. Solange unklar ist, ob die
Diktier-App weiterlebt, sind beide Migrationsfragen nicht sauber entscheidbar.
*Frühwarnsignal:* Ein Migrationsplan, der nur von „Records“ spricht und keine Nutzerzahl nennt.

---

## 2. Entscheidungen, die jetzt fallen müssen

| # | Entscheidung | Warum jetzt | Empfehlung |
|---|---|---|---|
| ~~D1~~ | ~~Zugang zum BrainSpeak-Checkout~~ | ✅ **erledigt am 2026-09-20** — Checkout liegt vor und ist auditiert | Nur noch: Audit an einem echten Checkout mit Commit/Branch gegenprüfen |
| **D2** | **PCC-Entitlement beantragen** | Vorlaufzeit; M4 hängt daran | Sofort beantragen, unabhängig von D1 |
| **D3** | **Umfang für das erste Release**: alle 144 FR oder Schnitt nach M8a | Bestimmt, ob R3 oder R5 das Ziel ist | Schnitt nach M8a (R3). M9b (60 Aufgaben) als 1.1 — das Produktversprechen ist bei R3 vollständig belegbar |
| **D4** | **Smart Podcast List vorziehen** (Abweichung A1) | Ändert die Reihenfolge von 48 Aufgaben | Ja. Abhängigkeitstechnisch sauber, und es validiert das Konzept früher |
| **D5** | **YouTube-Tiefe**: nur Metadaten plus sichtbarer offizieller Player, oder mehr? | Bestimmt, ob YouTube-Inhalte in Wissen und Fokus einfließen können | Zuerst Metadaten plus sichtbaren Player, mit klar sichtbarer Zählung „gefunden vs. analysierbar“. Rechtliche Prüfung vor M9a |
| **D6** | **Die drei Konzeptlücken**: FR-145–147 aufnehmen oder per ADR ausschließen | Zwei davon (Onscreen-Kontext, Kadenz) sind später teuer | FR-146 und FR-147 aufnehmen, FR-145 bewusst zurückstellen und im Konzepttext als „nicht in 1.0“ benennen |
| **D7** | **Plattformversionen**: 27.0 überall wie gefordert, oder zunächst auf 26.0 bleiben? Dazu: ist `.watchOS(.v11)` ein Fehler? | Bestimmt Mindesthardware, Bestandsnutzer und welche APIs überhaupt zur Verfügung stehen · **hängt an D9** | 27.0 nur, wenn GATE-SDK zeigt, dass die vorausgesetzten Symbole wirklich 27er-exklusiv sind. Sonst auf 26.0 starten und den Sprung als eigenen Meilenstein planen — mit ADR, weil es Constitution III berührt |
| **D9** | **Produktzukunft der Diktier-App**: wird BrainSpeak zum Wissensplayer umgebaut, oder entstehen **zwei Produkte** auf gemeinsamem `BrainSpeakKit`? | Bestimmt die Antwort auf D7 und D8; es gibt Bestandsnutzer mit Daten in iCloud und eine laufende TestFlight-Verteilung | **Zwei Produkte auf gemeinsamem Kit.** Der Wissensplayer bekommt eigene Bundle-ID und eigenen CloudKit-Container; `BrainSpeakKit` wird um Zeitbezug und Claims erweitert und von beiden genutzt. Damit entfällt die riskanteste Migration (D8 betrifft dann nur neue Records) und D7 kann der Player allein auf 27.0 gehen, ohne Bestandsnutzer der Diktier-App auszusperren |
| **D8** | **Syncarchitektur**: SwiftData-Auto-Spiegelung behalten oder auf CKSyncEngine migrieren? | Constitution IX und ADR-0003 verbieten beides nebeneinander; die Auto-Spiegelung erzwingt optionale Felder ohne Unique-Constraints · **hängt an D9** | Migrieren, wie das Paket es vorsieht — aber den Migrationspfad für bestehende iCloud-Aufnahmen im selben Beschluss festlegen und als GATE-MIGRATE prüfen. Ohne Migrationsplan die Entscheidung **nicht** treffen |

---

## 3. Was dieser Plan ausdrücklich nicht behauptet

* Keine der 266 Aufgaben ist umgesetzt. `status` steht überall auf `not_started`.
* Das erfolgreiche Paket-Validierungsskript prüft Dokumente, Schemata und Fixtures — **keinen** Apple-Build,
  **keinen** Gerätetest, **keine** Modellinferenz.
* Die Kalenderangaben in [01-umsetzungsplan.md](01-umsetzungsplan.md) §8 sind ein Szenario unter benannten Annahmen,
  keine Zusage. Ohne M0 gibt es keine belastbare Schätzung.
* Die Konzeptbilder unter `design/images/` sind Illustration, keine Screenshots einer laufenden App. Ihr fiktiver
  Folgentext darf nicht in Fixtures oder Tatsachenbehauptungen wandern.
* Der BrainSpeak-Audit beruht auf **Lesen des gelieferten ZIP**, nicht auf einem Build. Es wurde nichts kompiliert,
  nichts ausgeführt und nichts am Checkout verändert. Das ZIP enthält kein `.git`, daher sind Commit und Branch
  nicht belegbar.
* FR-145–147 sind Vorschläge aus der Lückenanalyse, keine beschlossenen Anforderungen.
