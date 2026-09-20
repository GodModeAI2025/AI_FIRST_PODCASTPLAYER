# Risiken und offene Entscheidungen

Dieses Dokument enthält, was den Plan zum Kippen bringen kann, und die sechs Entscheidungen, die **vor M1** fallen müssen.

---

## 1. Top-Risiken

Bewertung: Auswirkung × Eintrittswahrscheinlichkeit auf Basis des heutigen Kenntnisstands. „Frühwarnsignal“ ist das,
woran man den Eintritt erkennt, bevor er teuer wird.

### R1 — BrainSpeak-Checkout bleibt unzugänglich · hoch × real eingetreten

Der Connector lieferte wiederholt 404 ([research-limitations.md](../references/research-limitations.md)). Daraus folgt
**kein** Rückschluss auf privat, gelöscht oder umbenannt — aber Constitution II („BrainSpeak bleibt die Basis“) ist
ohne lesbaren Checkout nicht erfüllbar, und jede Aufwandsschätzung bleibt Spekulation.

*Gegenmaßnahme:* D1 entscheiden. Bis dahin sind Spezifikationsarbeit, Domainmodell und Testinfrastruktur (T005–T010)
trotzdem produktiv — sie hängen nicht am Altcode. Blockiert ist nur die **Integration**.
*Frühwarnsignal:* T004 kann keine reale Mappingtabelle füllen.

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

---

## 2. Entscheidungen, die jetzt fallen müssen

| # | Entscheidung | Warum jetzt | Empfehlung |
|---|---|---|---|
| **D1** | **Zugang zum BrainSpeak-Checkout** herstellen — oder per ADR auf Greenfield umstellen | M0 ist sonst nicht abschließbar; die Architektur unterscheidet sich erheblich | Zugang herstellen. Scheitert das binnen zwei Wochen, ADR „Greenfield“ schreiben und Constitution II ändern, statt die Frage offen mitzuschleppen |
| **D2** | **PCC-Entitlement beantragen** | Vorlaufzeit; M4 hängt daran | Sofort beantragen, unabhängig von D1 |
| **D3** | **Umfang für das erste Release**: alle 144 FR oder Schnitt nach M8a | Bestimmt, ob R3 oder R5 das Ziel ist | Schnitt nach M8a (R3). M9b (60 Aufgaben) als 1.1 — das Produktversprechen ist bei R3 vollständig belegbar |
| **D4** | **Smart Podcast List vorziehen** (Abweichung A1) | Ändert die Reihenfolge von 48 Aufgaben | Ja. Abhängigkeitstechnisch sauber, und es validiert das Konzept früher |
| **D5** | **YouTube-Tiefe**: nur Metadaten plus sichtbarer offizieller Player, oder mehr? | Bestimmt, ob YouTube-Inhalte in Wissen und Fokus einfließen können | Zuerst Metadaten plus sichtbaren Player, mit klar sichtbarer Zählung „gefunden vs. analysierbar“. Rechtliche Prüfung vor M9a |
| **D6** | **Die drei Konzeptlücken**: FR-145–147 aufnehmen oder per ADR ausschließen | Zwei davon (Onscreen-Kontext, Kadenz) sind später teuer | FR-146 und FR-147 aufnehmen, FR-145 bewusst zurückstellen und im Konzepttext als „nicht in 1.0“ benennen |

---

## 3. Was dieser Plan ausdrücklich nicht behauptet

* Keine der 266 Aufgaben ist umgesetzt. `status` steht überall auf `not_started`.
* Das erfolgreiche Paket-Validierungsskript prüft Dokumente, Schemata und Fixtures — **keinen** Apple-Build,
  **keinen** Gerätetest, **keine** Modellinferenz.
* Die Kalenderangaben in [01-umsetzungsplan.md](01-umsetzungsplan.md) §8 sind ein Szenario unter benannten Annahmen,
  keine Zusage. Ohne M0 gibt es keine belastbare Schätzung.
* Die Konzeptbilder unter `design/images/` sind Illustration, keine Screenshots einer laufenden App. Ihr fiktiver
  Folgentext darf nicht in Fixtures oder Tatsachenbehauptungen wandern.
* FR-145–147 sind Vorschläge aus der Lückenanalyse, keine beschlossenen Anforderungen.
