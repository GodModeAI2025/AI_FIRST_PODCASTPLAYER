# Breadcrumb-Trail — vom Hören zum kuratierten Wissensgraphen

## Produktvertrag
Jede bewusst abgeschlossene Hör-, Fokus- oder Mixer-Session **bietet** einen sinnvollen nächsten Schritt statt einer Sackgasse. Die Karte ist überspringbar; Ende heißt nicht endloses Weiterhören. Referenzen FR-103–FR-120, US16.

> **Welche Frage nimmst du mit?**
> „Wann lohnt sich Local-first trotz Betriebsaufwand?“
> Vertiefen — 4 verfügbare Quellen · Parken — Wissenslandkarte sichern · Verwerfen

Die vier Quellen im Beispiel sind nur dann sichtbar, wenn vier eindeutige, zugängliche Quellen im ausgewählten Bestand tatsächlich gefunden wurden. Sonst wird die tatsächliche Zahl oder „Keine weitere belegte Quelle gefunden“ ausgegeben. Der Claim „4“ kommt aus dem Resolver, nicht aus frei generiertem Text.

## Session und Grenzen
Eine `KnowledgeSession` referenziert die Ausgangsfrage, den Scope-Snapshot, tatsächlich herangezogene Evidence-IDs, die ursprüngliche Wiedergabequeue und den Verlauf gewählter Zweige. Sie ist keine Liste aller privaten Hörereignisse. Playertelemetrie bleibt eine eigene sparsame Domäne.

| Ereignis | Folge |
|---|---|
| Letzter Fokusclip fertig / Budget verbraucht | einmalig Abschlussangebot vorbereiten und bei aktiver Oberfläche anzeigen |
| Nutzer wählt Session beenden | Audio stoppen, Checkpoint sichern, Abschluss anbieten |
| Pause / Kopfhörertrennung / Anruf | pausieren; keine neue Abschlusskarte |
| Sleep Timer | Wiedergabe ruhig stoppen; nicht sprechen oder aufwecken; Fortsetzen/Abschließen beim nächsten Öffnen anbieten |
| App im Hintergrund oder OS beendet | persistent suspendieren; keine Garantie einer Abschlussausführung im Hintergrund |
| Kontingent/Netz/Quellproblem | Zustand erklären; lokal belegbare Karte nutzen oder später fortsetzen |
| Einzelne Folge in normaler Queue endet | dezenten Zwischenabschluss vormerken; keine normale Queue ungefragt blockieren |

In einer explizit gewählten langen normalen Hörqueue gilt der Abschluss auf Sessionebene. Der Nutzer kann zusätzlich Kapitel/Folge bewusst abschließen. Nicht jede technische Trackgrenze ist eine neue Lernsession.

## Entscheidung 1 — Vertiefen
Die Karte zeigt die konkrete Folgefrage und eine Quellenliste mit Titel, inhaltlichem Bezug, Datum, Analyse-/Timingstatus und verfügbaren Originalstellen. Der Nutzer kann Frage, Auswahl und Zeitbudget ändern. Bereits verwendete Quellen werden von neuen getrennt; „neu für dich“ wird nur gegenüber dem App-Bestand behauptet.

`Vertiefen` eröffnet eine neue **Kindsession** mit `parentSessionID` und Kante `deepens`. Es startet weder Audio noch Zusatzdownloads außerhalb der bestätigten Policy. „Diese 6 Minuten hören“ kann als explizite zweite Aktion den geprüften Hörplan starten. Der vorherige Pfad bleibt auffindbar; eine neue Kindsession endet wieder überspringbar. Kein Autoplay-Kreislauf.

## Entscheidung 2 — Parken
Parken heißt: das bisher Gelernte samt verbleibender Frage wiederverwendbar ablegen. Die lokale gespeicherte Karte enthält:

- Ausgangsfrage, knappe quellengebundene Erkenntnisse und offene Anschlussfragen.
- Eigene Notizen getrennt von KI-Ableitungen; Gegensätze bleiben als Gegensätze bestehen.
- Originalquellen, Evidence-IDs, Medien-/Transkriptrevision, Zeiten und sichere Links.
- Beziehungen zwischen Frage, Aussage, Beleg, Session und Themen.

Es gibt getrennte Status `lokal gesichert`, `Export vorbereitet`, `Export wartet`, `exportiert` und `Export fehlgeschlagen`. Eine auf der Watch vorgemerkte Parkaktion ist nicht schon im externen Tool angekommen.

**Portable Ausgabe:** ein Markdown-Hauptdokument mit YAML-Frontmatter und relativen Links, optional einzelne Knotennotizen, `graph.json` mit stabilem Schema und `map.mmd` als Mermaid-Landkarte. Das Paket muss ohne eine spezielle kommerzielle Graphdatenbank lesbar bleiben. Markdown ist für Obsidian-ähnliche Werkzeuge gedacht, aber ein beliebiger gewählter Dateienordner genügt.

**Ablauf des Exports:** Vorschau/Redaction → Zieleinwilligung über System-Dateiauswahl → Snapshot einfrieren → atomar lokal schreiben → separat erlaubten Export kopieren → Manifest/Checksum prüfen → Commitstatus persistieren. Bei Abbruch bleibt ein wiederholbarer Job mit gleicher Export-ID. Fremde Benutzernotizen nicht überschreiben; geänderte bestehende Exporte als Konflikt/Version erhalten.

Dateizugriff ist plattformspezifisch: im gewählten Sicherheitsbereich bleiben, langlebige Freigaben nur wenn unterstützt, keine ungefragte Suche in fremden Vaults und kein Zugriff auf Ordner allein aufgrund eines Pfads im Chat. Optionaler MCP-Abruf nutzt denselben erlaubten Snapshot. Sonar behauptet keine native Integration mit jedem Wissens-Tool.

## Entscheidung 3 — Verwerfen
Standardbedeutung: **diesen vorgeschlagenen Wissenspfad nicht in die kuratierte Sammlung übernehmen**. Medien, Abo, ursprüngliche Highlights und eigene Notizen bleiben unverändert. Die Aktion ist weder eine Bewertung des Themas noch ein Standpunktwechsel.

Unmittelbares Undo stellt den Vorschlag wieder her. Späteres Zurückholen ist während der lokalen, sichtbar konfigurierten Aufbewahrungsfrist möglich; danach kann der Pfad aus noch erlaubten Quellen erneut vorgeschlagen werden. Der Entwurf verwendet 30 Tage lokale Undo-Aufbewahrung als veränderbaren Produktdefault, nicht als rechtliche Vorgabe. „Jetzt endgültig löschen“ ist eine getrennte bestätigte Datenaktion. Kein negativer Feedbackscore wird aus Verwerfen abgeleitet.

## Datenmodell und Aussagequalität
Knoten: `question`, `claim`, `evidence`, `note`, `topic`, `session`. Kanten: `asks`, `supportedBy`, `contradicts`, `qualifies`, `differentAssumptions`, `deepens`, `derivedFrom`, `annotates`, `about`, `usedIn`. Semantische Kanten tragen Herkunft (`user`, `model`, `system`), Reviewstatus und Belege.

`curated` heißt bewusst aufbewahrt. `userReviewed` heißt vom Nutzer als passende Beziehung geprüft. Weder bedeutet, dass die Quelle wahr ist. Aussagen bleiben Quellenmeinung, Ableitung oder eigene Notiz. Eine Modellkante `contradicts` ist zuerst `proposed`; der Nutzer kann sie korrigieren. `supportedBy` verweist auf Beleg, nicht auf Wahrheitssiegel.

Graph kann fachliche Zyklen enthalten, etwa zwei gegensätzliche Aussagen. Die **Session-Abstammung** muss hingegen azyklisch sein. Unterschiedliche Schreibweisen desselben Themas dürfen zusammengeführt werden; Aussagen mit verschiedenen Bedingungen nicht still verschmelzen. Jede Zusammenführung bewahrt Alias-/Herkunfts-IDs und ist rückgängig machbar.

## Vier Plattformen
**iPhone:** überspringbare Endkarte, Quellen als aufklappbare Liste, vertraute Dateienfreigabe. **iPad:** Frage/Graph/Quellen nebeneinander, Listenalternative und optional native Pencil-Notizen nur als explizite Erweiterung. **Mac:** native Wissensansicht, Tastaturbefehle, Inspector, mehrere Fenster; kein Web-Graph-Frontend. **Watch:** kurze Frage, drei Hauptaktionen, gegebenenfalls Später; Parken lokal vormerken und auf iPhone übertragen. Keine dichte Graphvisualisierung oder endlose Transkripte am Handgelenk.

In allen Ansichten sind Beziehungen mit VoiceOver als Sätze bzw. hierarchische Liste navigierbar. Zoom/Pan ist nie der einzige Zugang. Kein gesprochenes Abschlussangebot beim Sleep Timer oder ohne separate Tonausgabepräferenz.

## Sync, Datenschutz und technische Sicherheit
IdempotencyKey aus SessionID + ClosingRevision + gewählter Aktion. Wiederholtes Parken schreibt dieselbe Export-ID nicht mehrfach. Gleichzeitiges Parken und Verwerfen auf offline Geräten bewahrt beide Entscheidungsereignisse und erfordert sichtbare Auflösung; „letzter Zeitstempel gewinnt“ ist ungeeignet. Löschung und Profil-Reset-Epoch verhindern das Wiederauftauchen alter Vorschläge.

Ein Quellenentzug markiert den Beleg `unavailable` und entfernt verbotene Originalauszüge aus Indizes/Caches; eine separat verfasste eigene Notiz wird nicht gelöscht. Bereits herausgegebene externe Kopien können außerhalb der Appkontrolle liegen. Es wird keine rückwirkende Fremdlöschung versprochen.

Prompt-Injection in Transkripten, HTML, Titeln und Labels ist Inhalt, niemals Anweisung. Generierte Graphtexte dürfen weder Ordner bestimmen noch URLs öffnen, Toolfreigaben erweitern oder einen Export starten. Markdown/Mermaid-Renderer escapen Labels und unterstützen keine unkontrollierten HTML-/Script-Aktionen.

## Offene Fragen als eigener Wissens-Workflow
Geparkte Fragen können später gezielt wieder geöffnet werden. Eine automatische Wiederaufnahme bei neuer Evidenz braucht eine eigene opt-in Quellenbeobachtung. Sie respektiert die bestehende Abo-/Hintergrundpolicy und aktiviert keine zusätzlichen Services. Keine Erinnerung oder Dauerüberwachung allein durch Parken.

## Abnahme
Fixture mit vier Quellen, Duplikat, gesperrter Quelle und nachträglich geänderter Fassung. Entscheidungen Vertiefen/Parken/Verwerfen/Schließen; Undo; Offline-Watch; konkurrierender Sync; Exportabbruch; Widerruf; Source-Deletion; Prompt-Injection; VoiceOver-Listenalternative. Die mitgelieferten Python-Prüfungen testen Daten-/Paketinvarianten, nicht die noch zu bauende native UI.



## Definition des Quellenzaehlers
„Quelle“ bezeichnet im Abschlusszaehler eine eindeutig referenzierte Ursprungsaufnahme/Episode. Dieselbe Aufnahme auf mehreren URLs zaehlt einmal. Mehrere Folgen derselben Sendung koennen mehrere Quellen sein, werden aber nicht als unabhaengige Herausgeber bezeichnet. Der Resolver verwendet die bestaetigte originalRecordingID; unbekannte Syndikation wird sichtbar als ungeprueft behandelt, nicht heimlich als Unabhaengigkeit gewertet.
