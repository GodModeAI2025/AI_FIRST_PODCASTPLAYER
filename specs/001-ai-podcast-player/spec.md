# Feature Specification: BrainSpeak AI-First Podcast Player

**Feature Branch:** `001-ai-podcast-player`  
**Created:** 2026-09-19  
**Status:** Implementierungsentwurf, produktseitig spezifiziert; technische Nachweise offen.

## Input und verbindlicher Umfang

BrainSpeak als Hauptbasis; RSS-Podcasts und YouTube-Referenzen abonnieren oder einzeln aufnehmen; Audio, Kapitel, Hintergrundaktualisierung; Audio unabhängig vom Hören analysieren; Chat über eine/mehrere/alle Folgen nur mit Apple Intelligence/PCC; Interessen lernen und korrigieren; Timecode-gesteuerte Originalsequenzen aus Chat oder persönlichem Fokus; Markdown-Export. Ausschließlich native Apps für iOS, iPadOS, watchOS und macOS 27.

## User Scenarios & Testing

### US1 — Eine ungehörte Folge verstehen (Priority: P1)

Eine zugängliche Folge importieren und Wissen daraus gewinnen, ohne sie abzuspielen.

**Independent Test:** Eine lokale synthetische Audiodatei plus Transkript reicht als unabhängige Testbasis.

**Acceptance Scenarios:**

1. **Given** Eine neue Folge ist ungehört und besitzt zugängliches Audio; **When** ich starte Auswerten; **Then** die App zeigt Verarbeitung und danach belegte Erkenntnisse; heard bleibt false.

2. **Given** Nur Metadaten sind vorhanden; **When** ich öffne Verstehen; **Then** die Vorschau ist als Metadatenbasis gekennzeichnet und enthält keine erfundenen Inhaltsbehauptungen.

3. **Given** Die Sprachanalyse ist nicht möglich; **When** ich drücke Play; **Then** verfügbares Originalaudio spielt unabhängig vom KI-Status.

### US2 — Quellen abonnieren oder einzelne Inhalte aufnehmen (Priority: P1)

RSS, YouTube-Kanalhinweise und einzelne Medien in einer Mediathek organisieren.

**Independent Test:** RSS-/Atom-/OPML-Fixtures lassen sich ohne Serverabonnement einspielen.

**Acceptance Scenarios:**

1. **Given** Ein Episodenlink wird geteilt; **When** ich wähle Nur diese Folge; **Then** es entsteht kein Abo.

2. **Given** Ein Abo existiert; **When** eine neue Folge wird entdeckt; **Then** sie gelangt gemäß Einstellung in die Analysequeue, nicht automatisch in die Hörqueue.

3. **Given** YouTube liefert keinen autorisierten Inhalt; **When** ich nehme das Video auf; **Then** Ansehen bleibt möglich; Analyse ist eingeschränkt statt vorgetäuscht.

### US3 — Vollwertig hören und Kapitel nutzen (Priority: P1)

Audio mit gesperrtem Bildschirm, Queue, Geschwindigkeit, Kapiteln und Wiederaufnahme hören.

**Independent Test:** Eine bekannte lokale Audiodatei mit Kapitel-Fixture ist unabhängig testbar.

**Acceptance Scenarios:**

1. **Given** Eine Folge läuft; **When** das Gerät wird gesperrt; **Then** die freigegebene Audiowiedergabe bleibt bedienbar.

2. **Given** Ich höre einen Beleg aus dem Chat; **When** ich wähle Zur bisherigen Wiedergabe; **Then** die vorherige Queue und Position sind erhalten.

3. **Given** Kopfhörer werden getrennt; **When** das System meldet einen Routenwechsel; **Then** Wiedergabe pausiert und startet nicht unbemerkt über Lautsprecher.

### US4 — Mit einer Folge oder vielen Folgen sprechen (Priority: P1)

Fragen an diese Folge, eine Auswahl, Sammlung oder alle analysierten Folgen stellen.

**Independent Test:** Ein lokaler, synthetischer Index mit zwei Folgen und bekannten Belegen genügt.

**Acceptance Scenarios:**

1. **Given** Nur zwei von drei gewählten Folgen sind erschlossen; **When** ich frage nach Gemeinsamkeiten; **Then** Antwort benennt Abdeckung und zitiert nur zugängliche Belege.

2. **Given** Keine passende Evidenz existiert; **When** ich stelle eine Frage; **Then** die App benennt die Lücke statt eine Antwort zu erfinden.

3. **Given** Ich verlange alle genannten Risiken; **When** die App erstellt eine Antwort; **Then** sie verwendet einen Coverage-Lauf oder kennzeichnet das Ergebnis ausdrücklich als unvollständig.

### US5 — Aus einem Chat relevante Originalstellen hören (Priority: P1)

Mit „Spiele mir die Stellen zu X“ eine geprüfte Fokusliste erhalten und starten.

**Independent Test:** Golden Evidence-IDs und ein MediaVersion-Fixture liefern reproduzierbare Zeitbereiche.

**Acceptance Scenarios:**

1. **Given** Drei validierte Belege passen zur Frage; **When** ich bitte um Wiedergabe; **Then** die App zeigt Reihenfolge, Originalzeiten, Gesamtdauer und Kontext.

2. **Given** Der Request lautet ausdrücklich Spiele mir ...; **When** ein passender Plan ist geprüft; **Then** er darf als Wiedergabeauftrag starten; bloßes Erkläre ... darf das nicht.

3. **Given** Ein Segment verweist auf eine andere Medienfassung; **When** ich starte die Liste; **Then** die Stelle wird gesperrt oder neu abgeglichen, nie still falsch angesprungen.

### US6 — Eine interessenbasierte Fokus-Sitzung hören (Priority: P1)

Passende Sequenzen automatisch zusammenstellen und innerhalb bewusst aktivierten Hörens fortsetzen.

**Independent Test:** Deterministische Kandidaten und ein bestätigtes Profil erlauben Tests ohne Modell.

**Acceptance Scenarios:**

1. **Given** Personalisierung und Fokus-Autofortsetzung sind aus; **When** neue Empfehlungen treffen ein; **Then** kein Ton startet.

2. **Given** Ich aktiviere eine Fokus-Sitzung mit Zeitbudget; **When** der aktuelle Abschnitt endet; **Then** die nächste validierte Passage startet mit sichtbarem Quellenwechsel.

3. **Given** Das Zeitbudget ist zu klein für sinnvollen Kontext; **When** die App erstellt eine Liste; **Then** sie liefert weniger Inhalt und erklärt die Grenze, statt einen Satz mitten in der Aussage abzuschneiden.

### US7 — Interessen verstehen und korrigieren (Priority: P1)

Bestätigte Themen, Vorhaben und offene Fragen pflegen und aus Feedback lernen lassen.

**Independent Test:** Ein leeres Profil plus explizites Feedback reicht für einen unabhängigen Test.

**Acceptance Scenarios:**

1. **Given** Ein Interesse ist nur vermutet; **When** ich öffne Warum empfohlen; **Then** Vermutung, Gründe und Korrektur sind erkennbar.

2. **Given** Ich wähle Bereits bekannt; **When** die nächste Vorschau erscheint; **Then** Neuigkeitswert ändert sich; Wichtigkeit wird nicht gleichgesetzt.

3. **Given** Ich lösche das Profil samt Lernhistorie; **When** alte Events werden synchronisiert; **Then** der Löschstand verhindert unbemerkten Wiederaufbau.

### US8 — Nahtlos auf iPad und Mac arbeiten (Priority: P1)

Quellen, Transkript, Chat und Erkenntnisse parallel nutzen, mit Tastatur und mehreren Fenstern.

**Independent Test:** Preview-Fixtures testen alle Fenstervarianten unabhängig von PCC.

**Acceptance Scenarios:**

1. **Given** Auf iPad steht ein breites Fenster bereit; **When** ich öffne eine Folge; **Then** Navigation, Inhalt und optionaler Inspector teilen den Raum adaptiv.

2. **Given** Auf Mac sind zwei Fenster geöffnet; **When** ich starte im zweiten Fenster einen Beleg; **Then** ein zentraler Player übernimmt, nicht zwei konkurrierende Audiostreams.

3. **Given** Ein Fenster wird schmal; **When** ich arbeite weiter; **Then** Informationen werden navigierbar statt abgeschnitten.

### US9 — Auf der Watch Erkenntnisse und Fokusaudio nutzen (Priority: P1)

Vorbereitete Sequenzen unabhängig hören, kurze Fragen stellen und Feedback geben.

**Independent Test:** Ein vorbereiteter Watch-Pack plus simulierte Erreichbarkeit reicht.

**Acceptance Scenarios:**

1. **Given** Ein Watch-Pack ist vollständig übertragen; **When** iPhone und Netzwerk fehlen; **Then** lokales Fokusaudio und gespeicherte Erkenntnisse bleiben verfügbar.

2. **Given** PCC ist auf der Watch verfügbar und freigegeben; **When** ich stelle eine kurze Frage; **Then** Antwort nutzt den begrenzten lokalen Evidence-Pack oder einen ausdrücklich vermittelten Scope.

3. **Given** PCC und Telefon fehlen; **When** ich frage nach nicht lokal enthaltenem Wissen; **Then** die App zeigt fehlende Verfügbarkeit, nicht eine scheinbare Vollbibliotheksantwort.

### US10 — Über Geräte und Neustarts hinweg zuverlässig bleiben (Priority: P1)

Bibliothek, Wissen und bestätigte Fokuslisten optional synchronisieren, ohne Pflicht-Master.

**Independent Test:** Zwei lokale Stores und Fake-CloudKit-Events testen Konflikte deterministisch.

**Acceptance Scenarios:**

1. **Given** Zwei Geräte arbeiten offline; **When** beide synchronisieren später; **Then** stabile IDs und Konfliktregeln verhindern Datenverlust oder Dubletten.

2. **Given** Ein Gerät hat eine alte Hörposition; **When** neuerer Nutzerfortschritt liegt vor; **Then** alte Daten setzen die Position nicht unbemerkt zurück.

3. **Given** Ein Job wird beendet; **When** die App startet erneut; **Then** sie setzt am letzten atomaren Checkpoint fort.

### US11 — Wissen als Markdown mitnehmen (Priority: P1)

Folgen, Aussagen, Chats und Vergleiche mit Quellen exportieren.

**Independent Test:** Ein Export-Fixture mit privater Feed-URL liefert einen unabhängigen Sicherheitstest.

**Acceptance Scenarios:**

1. **Given** Eine Erkenntnis enthält Belege; **When** ich exportiere Markdown; **Then** Quelle, lesbare Originalzeit und Analysegrundlage sind enthalten.

2. **Given** Ein Feed-Link enthält ein Geheimnis im Pfad; **When** ich exportiere; **Then** kein Geheimnis erscheint; sichere kanonische Quelle oder nur interne Referenz.

3. **Given** Ich exportiere auf der Watch; **When** kein Dateidialog steht im Design bereit; **Then** der Exportauftrag wird sichtbar an einen Vollclient übergeben oder gespeichert, nie als fertige Datei behauptet.

## Functional Requirements

MUSS-Anforderungen sind verbindlich. MUST NOT-Grenzen in der Constitution haben Vorrang. Die vollständige maschinenlesbare Zuordnung steht in `requirements.json`.

### Source

- **FR-001** [US2]: Die App MUSS RSS-Feeds, kanonische YouTube-Kanal-Atomfeeds und einzelne berechtigt verfügbare Medien aufnehmen; Quellentyp und Fähigkeiten separat darstellen.

- **FR-002** [US2]: Die App MUSS Abo, Autoanalyse, Autoqueue und dauerhaften Offline-Download unabhängig konfigurieren; Autoanalyse kann temporäre Downloads auslösen und erklärt dies.

- **FR-003** [US2]: Die App MUSS Einzelfolgenimport, Share-Import und OPML-Import/-Export ohne implizites Abo unterstützen; Duplikate anhand stabiler Quell-/Folgenidentitäten behandeln.

- **FR-004** [US2]: Die App MUSS RSS enclosure/GUID, Redirects, Feedwechsel, ETag/Last-Modified, Publisher-Kapitel und Transkriptquellen verarbeiten; signierte Medien-URLs nicht durch pauschales Query-Stripping beschädigen.

- **FR-005** [US2]: Die App MUSS YouTube nur als sichtbare offizielle Wiedergabe oder externes Öffnen anbieten; Vollanalyse nur mit gesondert autorisiertem Text/Audio; keine Audioextraktion aus YouTube-Streams.

- **FR-006** [US2]: Die App MUSS bei Quellzugang, Sprache, Format, Account oder Rechten konkrete capability reasons anzeigen; öffentlich erreichbar ist nicht pauschal eine Rechtefreigabe.

- **FR-007** [US2]: Die App MUSS archivnachladen begrenzen: zunächst gewählte aktuelle Folge, historische Zeiträume nur bewusst; Anzahl, Speicher und Netzwerkbedarf soweit bekannt anzeigen.

- **FR-008** [US2]: Die App MUSS private Feeds mit Keychain-referenzierten Geheimnissen behandeln; keine Rohcredentials in CloudKit-Fachdaten, KI-Kontext oder Export; neue Geräte können erneute Anmeldung benötigen.

### Playback

- **FR-009** [US3]: Die App MUSS native Audio-Wiedergabe, Pause, Seek, Geschwindigkeit, Sleep Timer, Queue, Kapitel sowie Wiederaufnahme anbieten; Analyse darf Abspielen nicht blockieren.

- **FR-010** [US3]: Die App MUSS herausgeberkapitel, in der Datei enthaltene Kapitel und KI-Kapitel mit Herkunft und Konfliktauflösung zeigen; bei Fassungszweifeln nicht blind Zeiten übernehmen.

- **FR-011** [US3]: Die App MUSS eine zentrale Wiedergabeinstanz pro Gerät/Prozess mit Now Playing, Remote Commands, Unterbrechungen, Bluetooth/AirPlay und Kopfhörertrennung integrieren, soweit Plattform unterstützt.

- **FR-012** [US3]: Die App MUSS hörposition, tatsächlich gehörte Zeitintervalle, KI-Verarbeitung und gelesene Erkenntnisse getrennt speichern; Fokus-Sprünge markieren keine vollständige Folge als gehört.

- **FR-013** [US3]: Die App MUSS aus einer Quelle oder Chat-Fundstelle zur bisherigen Queue/Position zurückkehren; Focus Session überschreibt die normale Queue nicht.

### Ingestion

- **FR-014** [US1]: Die App MUSS geeigneten Publisher-Text oder Audio-Dateitranskription verwenden; Titel/Shownotes allein niemals als analysierter Vollinhalt behandeln.

- **FR-015** [US1]: Die App MUSS dateibasierte Apple-Sprachanalyse mit verwalteten Sprachassets, Streaming/Chunk-Verarbeitung, finalisierten zeitbezogenen Segmenten und persistenter Wiederaufnahme durchführen.

- **FR-016** [US1]: Die App MUSS medienfassung und Transkriptrevision unveränderlich identifizieren; echte Bytehashes nach vollständigem Download getrennt von schwachen Servermetadaten führen.

- **FR-017** [US1]: Die App MUSS analyseabdeckung als Vereinigung bearbeiteter Medienintervalle bzw. explizite Textabdeckung berechnen; Fehler, Werbefassungen und fehlende Abschnitte sichtbar halten.

- **FR-018** [US1]: Die App MUSS claims, neutrale Zusammenfassung, persönliche Relevanz, offene Fragen und Evidence-IDs getrennt erzeugen; nur geprüfte strukturierte Ergebnisse persistieren.

- **FR-019** [US1]: Die App MUSS transkript ohne Zeitbezug als nutzbares Textwissen zulassen, aber zeitgenaue Wiedergabe dafür deaktivieren; unbestätigte Sprecher nicht benennen.

- **FR-020** [US1]: Die App MUSS verarbeitungsjobs priorisieren, pausieren, abbrechen, fortsetzen und nach Fehlern begrenzt wiederholen; höchstens definierte Parallelität pro Gerät und Arbeitsart.

### Knowledge

- **FR-021** [US4]: Die App MUSS chat-Scope explizit auf Folge, Auswahl, Sammlung oder alle analysierten Folgen setzen; Anzahl verfügbarer, ausgewählter und verwendeter Quellen unterscheiden.

- **FR-022** [US4]: Die App MUSS antworten nur aus erlaubten Evidence-IDs des gewählten Scopes erzeugen; Toolergebnisse nochmals gegen Scope, Löschstand, Revisionsstand und Zugriffsrechte prüfen.

- **FR-023** [US4]: Die App MUSS aussagen, Ableitungen und eigene Notizen visuell und im Export unterscheiden; Vollständigkeit und Unsicherheit ohne unkalibrierte Prozent-Konfidenz darstellen.

- **FR-024** [US4]: Die App MUSS explizit umfassende Fragen über einen Coverage-Lauf aller ausgewählten analysierten Dokumente abarbeiten; Top-k-Suche allein darf keine Vollständigkeit behaupten.

- **FR-025** [US4]: Die App MUSS auf keine Evidenz, widersprüchliche Quellen, unvollständige Analyse und Modellfehler mit unterscheidbaren Ergebniszuständen reagieren.

- **FR-026** [US4]: Die App MUSS nur Apple-Modelle benutzen; lokale und PCC-Verfügbarkeit, Nutzereinwilligung, Kontingent und Kontextgrenzen vor und während einer Anfrage berücksichtigen.

- **FR-027** [US4]: Die App MUSS gesprächsverlauf versionieren und verdichten; konkrete Evidence-Verweise außerhalb der bloßen Chat-Historie speichern; Modellwechsel ändert den Scope nicht.

### Focus

- **FR-028** [US5]: Die App MUSS aus explizitem Chat-Wiedergabewunsch ein PlaylistProposal aus bestehenden Evidence-IDs erzeugen; keine vom Modell erfundenen Originalzeiten oder Medien-URLs akzeptieren.

- **FR-029** [US5]: Die App MUSS evidence-IDs deterministisch zu Start/Ende und Kontextintervallen derselben Medienfassung auflösen; ungültige, unzeitgestempelte und veraltete Belege sperren.

- **FR-030** [US5]: Die App MUSS fokus-Vorschau mit Originalquelle, Zeitspanne, Relevanzgrund, Kontextzugabe, Reihenfolge, Originalzeit/aktiver Hörzeit und fehlenden Inhalten anzeigen.

- **FR-031** [US5]: Die App MUSS vor Start einen kurzlebigen geräte-/sessionspezifischen PlaybackGrant prüfen; explizites Spiele ... kann den Start autorisieren, eine Wissensfrage allein nicht.

- **FR-032** [US5]: Die App MUSS segmentwiedergabe am geprüften Ende begrenzen und den nächsten Start nur nach erfolgreichem Seek/Load und gültigem Grant auslösen; Race Conditions idempotent behandeln.

- **FR-033** [US6]: Die App MUSS relevante Segmente mit Nutzerbudget, Themenbezug, Neuigkeitswert, Quellenvielfalt und Kontextbedarf auswählen; überlappende Stellen zusammenführen und Wiederholungen vermeiden.

- **FR-034** [US6]: Die App MUSS autofortsetzung nur innerhalb einer bewusst aktivierten Focus Session zulassen; neue Hintergrundempfehlungen, Boot, Sync oder Push dürfen niemals unaufgefordert Ton starten.

- **FR-035** [US6]: Die App MUSS explizite Zeitbudgetgrenze einschließlich Kontext, Pausen und gewählter Geschwindigkeit berücksichtigen; bei unzureichendem Budget weniger liefern statt Semantik abzuschneiden.

- **FR-036** [US6]: Die App MUSS jederzeit ganze Folge, mehr Kontext, Skip, Stop, Zurück und Gründe anbieten; ein Quellenwechsel ist sichtbar und optional kurz haptisch, kein irreführender nahtloser Sprecherzusammenschnitt.

- **FR-037** [US6]: Die App MUSS fokuslisten als referenzielle Wiedergabepläne speichern, nicht neue urheberrechtlich unklare Audio-Mashups exportieren; lokale Watch-Kopien nur im erlaubten Medienumfang.

### Interest

- **FR-038** [US7]: Die App MUSS bestätigte Interessen, automatisch vorgeschlagene Interessen, aktuelle Vorhaben und offene Fragen getrennt bearbeiten und anzeigen.

- **FR-039** [US7]: Die App MUSS personalisierung opt-in anbieten; explizites Feedback stärker als indirekte Signale werten; Nicht gehört nicht mit Nicht relevant gleichsetzen.

- **FR-040** [US7]: Die App MUSS warum empfohlen mit konkreter Interessen-/Fragezuordnung darstellen; Bereits bekannt, Mehr davon, Nicht relevant und Nicht aus dieser Quelle getrennt behandeln.

- **FR-041** [US7]: Die App MUSS vorschläge zur Profiländerung prüfen lassen; keine sensiblen Persönlichkeits-, Gesundheits- oder politischen Präferenzprofile aus Inhalten ableiten.

- **FR-042** [US7]: Die App MUSS neuigkeitswert ausschließlich relativ zu gespeichertem bzw. ausdrücklich bekanntem Wissen bezeichnen; neutrale chronologische Ansicht und relevante Gegenpositionen erhalten.

- **FR-043** [US7]: Die App MUSS profil, Verlauf und Lernsignale separat löschbar machen; Reset-Epoch/Tombstones verhindern unbemerkten Wiederaufbau durch verspätete Sync-Events.

### Reliability

- **FR-044** [US10]: Die App MUSS jobs/Teilresultate vor Systemende atomar sichern und beim Neustart fortsetzen; keine endlose Retry-Schleife bei Rechte-/Modell-/Sprachfehlern.

- **FR-045** [US10]: Die App MUSS refresh, Hintergrunddownload, Audiowiedergabe und KI-Verarbeitung getrennt planen; iOS/iPadOS-Background-Gates und echte Ressourcenzustände beachten.

- **FR-046** [US10]: Die App MUSS optionalen privaten CloudKit-Sync für Bibliothek, Wissen, bestätigte Profile und Fokuslisten bereitstellen; lokaler Modus bleibt ohne iCloud nutzbar.

- **FR-047** [US10]: Die App MUSS konflikte für Hörposition, Annotationen, Reihenfolge, Löschung und generierte Artefakte explizit behandeln; LWW allein und größte Hörsekunde sind kein universeller Konfliktlöser.

- **FR-048** [US10]: Die App MUSS keinen permanenten Master benötigen; größere Analysen auf jedem geeigneten Vollclient erlauben; CloudKit nicht als exakt-einmal Jobbroker oder Instant-RPC darstellen.

- **FR-049** [US10]: Die App MUSS app-Daten, Mediencache, Analysecache und Nutzer-Exporte getrennt verwalten; Medien löschen kann Wissen erhalten; Gesamtlöschung entfernt auch Index, Artefakte und synchronisierte Daten gemäß Scope.

### Platforms

- **FR-050** [US8]: Die App MUSS iOS/iPadOS/watchOS/macOS als native 27er-Targets liefern; gemeinsame Domain und plattformspezifische Shells statt Catalyst oder skaliertem Telefonlayout.

- **FR-051** [US8]: Die App MUSS iPad mit adaptiver Mehrspaltenansicht, Inspector, Drag/Drop, Tastatur und fensterbreitenabhängiger Navigation ausstatten.

- **FR-052** [US8]: Die App MUSS mac mit Sidebar, Table/List, Inspector, Menübefehlen, mehreren Fenstern, Dateiimport/-export und einem prozessweiten Player ausstatten.

- **FR-053** [US9]: Die App MUSS watch mit Tagesfokus, Segmentplayer, kurzen Erkenntnissen, Interesse-Feedback, Widget/Smart-Stack-Einstieg und gespeichertem Offline-Pack ausstatten.

- **FR-054** [US9]: Die App MUSS kurze Watch-Fragen über freigegebenes PCC mit lokalem Evidence-Pack oder sichtbaren Companion-Auftrag unterstützen; keinen lokalen Vollbibliotheksindex oder dauerhafte Watch-Transkription voraussetzen.

- **FR-055** [US9]: Die App MUSS watchConnectivity-Handoff/Dateitransfer mit Zustand und Wiederaufnahme implementieren; unerreichbares iPhone und unvollständige Packs sind sichtbare Zustände.

- **FR-056** [US8]: Die App MUSS app Intents für Folge/Fokus starten, Stelle merken, Frage vorbereiten und Wissen öffnen bereitstellen; stabile IDs, Intent-Policies und entitlements prüfen.

- **FR-057** [US8]: Die App MUSS dynamic Type, VoiceOver, Reduce Motion/Transparency, hohen Kontrast, Tastaturbedienung und barrierefreie Zeitcodes auf jeder Plattform prüfen.

### Export

- **FR-058** [US11]: Die App MUSS markdown für Folge, Claim, Chatantwort, Vergleich und Sammlung mit YAML-Metadaten, Analyseumfang, Quellen, Originalzeiten und eigenen Notizen erzeugen.

- **FR-059** [US11]: Die App MUSS geheimnisse auch in URL-Pfaden entfernen; nur allowlist-basierte kanonische öffentliche Quellen ausgeben, andernfalls sichere interne Referenz mit lesbarer Quellenbezeichnung.

- **FR-060** [US11]: Die App MUSS exportvorschau, sicheren Dateinamen, stabile UTF-8-Kodierung, atomisches Schreiben, überschaubare Einzeldatei oder Asset-freies ZIP für Sammlungen bieten; Volltranskripte nicht standardmäßig exportieren.

- **FR-061** [US11]: Die App MUSS von der Watch einen nachvollziehbaren Export-/Save-Auftrag an Vollclients vermitteln; fertige Dateien erst nach Bestätigung der Erstellung anzeigen.

### Security

- **FR-062** [US10]: Die App MUSS externe Texte und Metadaten als untrusted data behandeln; keine daraus stammenden Anweisungen für Tools, Netzwerk, Profiländerungen, Sync oder Exporte ausführen.

- **FR-063** [US10]: Die App MUSS logs lokal, datensparsam und mit Privacy-Redaktion erzeugen; keine Audio-/Transkript-/Promptinhalte in Telemetrie, kein Third-Party-Analytics-SDK.

- **FR-064** [US10]: Die App MUSS parser-, URL-, Redirect-, Dateigrößen-, MIME-, Archiv- und Dekodiergrenzen erzwingen; keine automatischen Zugriffe auf lokale Netze/Loopback aus fremden Feeds.

### Quality

- **FR-065** [US4]: Die App MUSS modell-/Prompt-/Indexversionen dokumentieren und Apple Evaluations plus deterministische Referenz-/Policy-Tests vor Freigabe ausführen; Ergebnisse nicht nur visuell beurteilen.

- **FR-066** [US8]: Die App MUSS brainSpeak-Ist-Audit und Apple-SDK-Compile-Probes vor Integration abschließen; neue Framework-Symbole nicht aus unbestätigten Erinnerungen implementieren.

## Edge Cases

Dynamische Werbung verändert dieselbe enclosure-URL; Publisher-Transkript gehört zu einer anderen Schnittfassung; Seek endet hinter einer Segmentgrenze; alte Session-Callbacks treffen nach Stop ein; CloudKit liefert ein gelöscht geglaubtes Profilereignis spät; Gerät ist offline und besitzt nur Metadaten; Watch-Pack enthält Belegtext aber keine Audiodatei; ein Kapitel überlappt die Dateidauer; Sprachassets fehlen; Download endet ohne vollständige Datei; finale Speech-Segmente ersetzen vorläufige Segmente; Podcast enthält Prompt Injection; signed URLs laufen ab; Scope ändert sich während einer Antwort; PCC-Quota endet zwischen Vorschau und Antwort; Medienlaufzeit ist unbekannt; Nutzer ändert Geschwindigkeit innerhalb einer Budget-Session; Quelle ist später entzogen oder nicht mehr verfügbar.

## Key Entities

Source, Subscription, Episode, MediaVersion, TranscriptRevision, TranscriptSegment, Chapter, Claim, Evidence, InterestProfile, InterestSignal, ChatScope, ChatTurn, PlaylistProposal, PlaybackPlan, PlaybackGrant, FocusSession, ListenEvent, ProcessingJob, WatchPack, InsightNote, ExportArtifact, SyncEnvelope. Begriffe und Invarianten stehen in `data-model.md`.

## Success Criteria — Zielwerte, nicht Messergebnisse

| ID | Messbarer Zielwert | Nachweis |
|---|---|---|
| SC-001 | 100 % persistierter Claims mit gültiger Evidence-ID und erlaubtem Scope. | Schema-/Referenztests und Evals |
| SC-002 | 0 Tonstarts ohne expliziten Auftrag oder gültige aktive Fokusfreigabe. | Policy-/Race-Tests |
| SC-003 | 100 % gesperrter Fokusstarts bei falscher Medienfassung, fehlendem Timing oder entzogenem Zugriff. | Negativfixtures |
| SC-004 | 100 % Budgeteinhaltung in deterministischen Playlisttests einschließlich Kontext und Transitionen. | Timeline-Tests |
| SC-005 | Mindestens 90 % menschlich als ausreichend kontexttreu bewertete Clips im kuratierten Evaluationssatz. | Blindreview; getrennt von automatischen Judges |
| SC-006 | Mindestens 95 % korrekt belegte substanzielle Antwortaussagen im kuratierten, manuell gelabelten Satz. | Human Review plus Prüfskripte |
| SC-007 | Vollständige Wiederaufnahme ohne Verlust finaler Segmente in allen definierten Abbruchtests. | Fault Injection |
| SC-008 | Kernbedienung in allen vier Plattformen mit VoiceOver bzw. Tastatur ausführbar. | Geräte-/UI-Testmatrix |
| SC-009 | 0 Feed-/URL-/Keychain-Geheimnisse im Export- und Log-Leak-Testkorpus. | Adversarial Tests |
| SC-010 | Erste brauchbare Erkenntnis kann ohne Abspielen und ohne Kontozwang für lokale Nutzung gewonnen werden. | End-to-end-Szenario |

## Annahmen und Prioritäten

Alle vier Plattformen sind Releaseumfang, nicht spätere Optionen. P1 bezeichnet hier die Bedeutung für das Gesamtprodukt, nicht dass jede Story vor ihren technischen Abhängigkeiten implementiert werden kann. Vertikale Lieferung erfolgt gemäß `tasks.md`.

Lokaler Betrieb ist Standard; iCloud-Sync und PCC-Übermittlung werden getrennt eingerichtet. Ungeprüfte BrainSpeak-Integration, realer SDK-Build und Account-Entitlement sind Gates. Ein privates Feed-Abo und sein Bearbeitungsrecht werden nicht automatisch auf YouTube übertragen.

## Nicht im Umfang

Kein universeller YouTube-Downloader, kein DRM-/Paywall-Bypass, keine Drittanbieter-LLMs, kein Team-SaaS, keine Android-/Web-App, kein Catalyst, keine Stimmenklone, kein Audio-Mashup-Export, kein Zwang zum permanenten Mac-Server und keine alte Betriebssystem-Kompatibilität. Live-Mikrofonaufnahme/Fotos/Meeting-Funktionen der BrainSpeak-Basis werden nicht zum Podcast-MVP aufgebläht.


## Ergänzungen aus den Nutzerunterbrechungen — verbindlich

### US12 — Highlights, Suche und wiederverwendbare Transkripte (Priority: P1)

**Independent Test:** Ein lokales Transcript-/Highlight-Fixture genügt; Translation bleibt optionale P2-Erweiterung.

- **FR-074**: Eine relevante Stelle mit einer nativen Aktion aus Player, Transkript, Watch oder App Intent als Highlight sichern; Headset-Aktion nur bei tatsächlich öffentlicher unterstützter API und ausdrücklichem Mapping.
- **FR-075**: Highlights als eigenständige versionierte Wissensobjekte mit Originalauszug, Evidence-IDs, eigener Notiz, separater KI-Kurzfassung, Tags und Herkunft verwalten.
- **FR-076**: Finale Transkripte als SRT, WebVTT, TXT und strukturiertes JSON exportieren; Sprecher- und Wortzeitdaten nur mit vorhandenem belegtem Alignment, sonst explizit unbekannt.
- **FR-077**: Semantische und exakte Suche über den freigegebenen erschlossenen Bestand einschließlich ungehörter Folgen anbieten; indexiert, analysiert und gehört bleiben getrennte Zähler.
- **FR-078**: Suchindex als erneuerbares Derivat behandeln; Revisionen, Löschungen, Zugangsänderungen und Privatsphäreeinstellungen invalidieren Treffer und verhindern obsolete Evidence-IDs.
- **FR-079**: Smart Skip für zulässiges Originalaudio nur ausdrücklich pro Quelle aktivieren; Werbung/Intro/Outro mit Herkunft und Unsicherheit markieren, Skip rückgängig machen und Originalzeitachse erhalten.
- **FR-080**: Erwerb, Transkription, Alignment, Kapitel, Zusammenfassung, Index und Relevanz separat wiederholbar und versioniert cachen; Änderung eines Prompts löst nicht automatisch neuen Audiodownload aus.
- **FR-081**: Container/Codec-Kombinationen nativ pro Plattform prüfen; MP3/AAC/ALAC/FLAC/OGG als konkrete Capability-Testfälle statt pauschaler Formatgarantie behandeln; keine FFmpeg-/Drittcodec-Laufzeit hinzufügen.
- **FR-082**: Optionale native Übersetzung separat vom Original speichern und als Übersetzung markieren; Zeitbelege bleiben am Original, Sprachpaare und Modellassets werden geprüft.

**Acceptance Scenarios:** Die zugehörigen AC-Einträge in `acceptance-cases.json` sind die einzelnen Given/When/Then-Abnahmeanweisungen; sie sind geplant und nicht als ausgeführt markiert.

### US13 — Eigenes Podcastwissen kontrolliert für Agenten öffnen (Priority: P1)

**Independent Test:** Fake-Client gegen isolierten Export-Snapshot ohne Modellzugang; keine echte Fremddatenübertragung nötig.

- **FR-083**: Auf macOS einen standardmäßig ausgeschalteten nativen Swift-MCP-Zugang anbieten; zunächst lokaler stdio-Helfer, keine automatisch öffentliche Netzwerkfreigabe oder iOS-Daemon-Fiktion.
- **FR-084**: MCP-Verträge für Bibliothekssuche, Evidence-Abruf, Highlightliste, Exportvorschau und Fokusplan-Vorbereitung definieren; keine freie SQL-, Datei-, Shell- oder URL-Ausführung und keine Tonwiedergabe durch Suchtools.
- **FR-085**: MCP-Datenweitergabe als eigene Einwilligung mit Client-/Scopebindung, Widerruf und Redaction behandeln; externe Agenten können eigene Modelle verwenden, ohne dadurch Modellanbieter der App zu werden.

**Acceptance Scenarios:** Die zugehörigen AC-Einträge in `acceptance-cases.json` sind die einzelnen Given/When/Then-Abnahmeanweisungen; sie sind geplant und nicht als ausgeführt markiert.

### US14 — YouTube-Link einfügen, abonnieren und Historie erschließen (Priority: P1)

**Independent Test:** Gespeicherte Video-/Kanal-/Feed-/Katalogantworten mit drei Seiten testen gesamten Import ohne Netzwerk.

- **FR-067**: Eine einzige YouTube-URL aus Video, youtu.be, Shorts, Live, Kanal-ID, Handle oder Share Sheet erkennen; Kanal-ID autoritativ auflösen, Zeitmarke für den Einzelimport erhalten.
- **FR-068**: Nach Auflösung eine Vorschau mit „Nur diese Folge“, „Kanal abonnieren“ und „Frühere Folgen analysieren“ anbieten; keine Aktion allein durch Einfügen ausführen.
- **FR-069**: Den Kanal-Atomfeed aus der verifizierten channelID automatisch ermitteln und prüfen; Nutzer müssen im Normalfall keine RSS-URL kennen oder manuell suchen.
- **FR-070**: Ältere YouTube-Folgen über den verfügbaren Kanal-Uploads-Katalog mit offizieller Pagination erschließen; Auswahl letzte N, Zeitraum, manuell oder gesamtes verfügbares Archiv, auch über den aktuellen Atomfeed hinaus.
- **FR-071**: Archivauffindbarkeit, Inhaltszugang und Analyseabdeckung getrennt zählen; gefundene Videos ohne autorisierte Text-/Audioquelle niemals als inhaltlich analysiert ausweisen.
- **FR-072**: Historische Batchjobs pausieren, fortsetzen, abbrechen, priorisieren und selektiv wiederholen; Cursor und Seiten-Commit atomar sichern, aktuelle Folgen nicht durch das Archiv blockieren.
- **FR-073**: Auch Podcast-RSS rückwirkend über alle tatsächlich verfügbaren Feed-/Publisher-Archivquellen erschließen; gekürzte Feeds als unvollständig kennzeichnen, keine nicht vorhandenen Archivendpunkte erfinden.
- **FR-086**: Bereits bekannte alte Folgen nachträglich gezielt neu analysieren, etwa nach Änderung von Interessen, Modell oder Pipeline; Umfang und betroffene Stufen vorher anzeigen, menschliche Notizen nie überschreiben.
- **FR-087**: Offline-, API-Quota-, Zugangs-, gelöschte Video- und uneindeutige URL-Zustände mit Wiederholen oder kanonischem Link-Import behandeln; keinen Erfolg oder manuell zu suchenden RSS als normalen Ablauf vortäuschen.
- **FR-088**: Archivjobs auf Wunsch nach Interessen priorisieren; eine nur aus Titel/Beschreibung geschätzte Priorität ausdrücklich als vorläufig kennzeichnen und keinen unbeachteten Rest als irrelevant verwerfen.
- **FR-089**: Abo anhand stabiler Kanal-/Quell-ID deduplizieren; Handlewechsel darf kein zweites Abo erzeugen, historische Analyse und Autoanalyse neuer Folgen bleiben unabhängig schaltbar.
- **FR-090**: Vor Batchstart gewählten Umfang, verfügbare/gesperrte Inhalte, Daten-/Speicherbedarf soweit bekannt und Analysepolicy anzeigen; „alle“ bedeutet alle zugänglichen Einträge im bestätigten Snapshot, nicht private oder gelöschte Videos.

**Acceptance Scenarios:** Die zugehörigen AC-Einträge in `acceptance-cases.json` sind die einzelnen Given/When/Then-Abnahmeanweisungen; sie sind geplant und nicht als ausgeführt markiert.


Die Erweiterung ist Bestandteil der vollständigen Version und fließt vor T109/T110 in die Freigabe ein. Native Übersetzung ist eine ausdrücklich optionale P2-Erweiterung; ihre Verfügbarkeit darf Kernfunktionen nicht blockieren.

## Ergänzung 1.2 — Widerspruchs-Mixer und Breadcrumb-Trail

Sonar ist der im Feedback verwendete Produktarbeitsname. Technische Hauptbasis und Modulnamen bleiben BrainSpeak. Keine Bundle-ID- oder Markenumbenennung ist dadurch bereits freigegeben.

### US15 — Eigene Thesen mit belegten Gegenpositionen prüfen (Priority: P1)

**Independent Test:** Bestätigte technische These, echte Gegenposition im synthetischen Korpus und vorgetäuschte Gegenposition bilden einen deterministischen Mixer-Test.

- **FR-091**: Bestätigte Standpunkte, vermutete Interessen, Quellenpositionen und bloßes Hör-/Speicherverhalten getrennt halten; Hören oder Highlight allein darf niemals als Zustimmung gelten.
- **FR-092**: Den Widerspruchs-Mixer standardmäßig ausschalten; Nutzer wählt These oder Thema, zulässige Quellen, Zeitbudget und ob Vorschläge künftig vorbereitet werden dürfen.
- **FR-093**: Gegenpositionen gegen eine konkrete These samt Bedingungen vergleichen; starker fairer Gegenstandpunkt statt Karikatur, bloße Themenähnlichkeit ist kein Widerspruch.
- **FR-094**: Jede Gegenposition mit vollständigem Kontext, Evidence-ID, Quelle, Datum und konkreter Medienfassung ausgeben; Audio bleibt Original, Einordnung bleibt getrennt.
- **FR-095**: Verschiedene Perspektiven nach nachgewiesener Passung und Quellenvielfalt auswählen; Syndikation und inhaltliche Duplikate nicht als unabhängige Bestätigung zählen.
- **FR-096**: Direkten Widerspruch, Einschränkung, andere Annahme und bloße Ergänzung unterscheiden; Interpretationen als vorgeschlagen kennzeichnen und korrigierbar machen.
- **FR-097**: Mixer als budgetgebundenen Original-Hörplan mit Vorschau, Quellenwechsel, Stop und Rückkehr aufbauen; gleicher PlaybackGrant wie anderer Fokusmodus.
- **FR-098**: Ohne belastbare Gegenposition offen fehlende Evidenz zeigen; keine Quellen, Gegenargumente, Zeitcodes oder künstliche Ausgewogenheit erfinden.
- **FR-099**: Eigene These, Quelleninterpretation und Modus jederzeit ändern, pausieren oder widerrufen; Änderungen invalidieren noch nicht gestartete darauf basierende Pläne.
- **FR-100**: Politische Inhalte nicht zur Ableitung politischer Nutzerpräferenzen oder individualisierten Überzeugungsänderung nutzen; nur explizit gewünschte neutrale, quellenbasierte Gegenüberstellung ohne Empfehlung oder Ranking politischer Optionen.
- **FR-101**: Erfolg nicht an Meinungsänderung, Empörung oder Hörzeit optimieren; Nutzer kann Gegenposition als hilfreich, bereits bekannt, unpassend oder fehlerhaft markieren, ohne eigene These ändern zu müssen.
- **FR-102**: Standpunkte und Gegenpositionsbeziehungen nicht ungefragt exportieren, an Agenten freigeben oder in Systemsuche veröffentlichen; gesonderte Scopeentscheidung für persönliche Inhalte.

**Acceptance Scenarios:**

1. **Given** drei gespeicherte Local-first-Folgen ohne Zustimmung; **When** der Mixer vorbereitet wird; **Then** schlägt er höchstens eine zu prüfende These vor, nicht eine angeblich bekannte Meinung.
2. **Given** eine bestätigte technische These und sechs Minuten Budget; **When** ich Gegenposition hören wähle; **Then** entsteht ein fairer, belegter Original-Hörplan mit Kontext und Quellenwechsel.
3. **Given** kein passend belegtes Gegenargument; **When** ich den Mixer aufrufe; **Then** zeigt die App die Lücke ohne provokative Ersatzempfehlung.
### US16 — Jede Hörsession als kuratierten Wissenspfad abschließen (Priority: P1)

**Independent Test:** Eine beendete Testsession mit vier auffindbaren Quellen erlaubt Vertiefen, Parken und Verwerfen ohne laufendes LLM oder Netzwerk.

- **FR-103**: Jede Hör-/Fokus-/Mixer-Session mit stabiler ID, Ausgangsfrage, tatsächlich verwendeten Belegen, Budget und Checkpoint verknüpfen; aus Verlauf wird nur nach Kuration ein Wissenspfad.
- **FR-104**: Nach natürlichem Ende, Budgetende oder bewusstem Beenden eine kompakte Abschlussfrage mit Vertiefen, Parken und Verwerfen anbieten; Schließen ohne Entscheidung bleibt möglich.
- **FR-105**: In der Abschlussfrage nur tatsächlich auffindbare und zugängliche Quellen zählen; Anzahl, Scope, Relevanz und Inhaltsstatus sind am Zeitpunkt des Angebots überprüfbar.
- **FR-106**: Vertiefen erzeugt eine neue begrenzte Kindsession aus einer gewählten Folgefrage und geprüften Quellen; kein endloses Autoplay und kein automatischer Scope-/Kostenanstieg.
- **FR-107**: Parken sichert eine Wissenslandkarte aus Frage, Erkenntnissen, Originalbelegen, eigenen Notizen und offenen Fragen; Markdown, Graph-JSON und Mermaid sind portable Exportziele.
- **FR-108**: Verwerfen verwirft den vorgeschlagenen Wissenspfad, nicht Medien, Abos, existierende Notizen oder Highlights; Undo ist möglich, Desinteresse wird nicht automatisch gelernt.
- **FR-109**: Wissensgraph mit typisierten Knoten und Kanten modellieren: Frage, Aussage, Beleg, Notiz, Thema und Session sowie stützt, widerspricht, qualifiziert, folgt aus und vertieft.
- **FR-110**: Generierte Graphbeziehungen als Vorschläge von bestätigten Kurationen trennen; Parken bestätigt Aufbewahrung, nicht Wahrheit oder Zustimmung zu allen Aussagen.
- **FR-111**: Graphableitungen mit Prompt-/Modell-/Inputrevision speichern und selektiv neu berechnen; menschliche Notizen, manuelle Kanten und bewusste Entscheidungen nicht überschreiben.
- **FR-112**: Export an ein Wissens-Tool über explizit gewählte Datei-/Ordnerfreigabe oder autorisierten Agent-Scope ausführen; Vorschau, Redaction, transaktionales Schreiben und Retrystatus vorsehen.
- **FR-113**: Unterbrechung, OS-Beendigung, Netzverlust, Sleep Timer und vorübergehende Pause als fortsetzbare Zustände behandeln; Abschlussangebot erst am passenden bewussten Ende nachholen.
- **FR-114**: Parken und Verwerfen geräteübergreifend idempotent und revisionsgebunden synchronisieren; konkurrierende Entscheidungen erhalten beide Varianten oder sichtbaren Konflikt statt Datenverlust.
- **FR-115**: Auf iPhone kompakte Abschlusskarte, iPad/Mac Karte plus Wissensansicht und Watch kurze Auswahl anbieten; Graph besitzt immer zugängliche Listen-/Baumalternative.
- **FR-116**: Abschluss und Übergänge standardmäßig visuell, optional mit nativer Systemstimme darstellen; nie Publisher-Credits verändern oder eine Sprecheridentität imitieren.
- **FR-117**: Kuration an nützlichen beantworteten/offenen Fragen und nachvollziehbarer Wiederverwendung messen; überspringbare Abschlusskarte, abschaltbarer Modus und kein Streak-/Druckmechanismus.
- **FR-118**: Offene geparkte Fragen nur innerhalb ausdrücklich aktivierter Quellenbeobachtung erneut anbieten; Parken allein aktiviert keine automatischen Benachrichtigungen, Downloads oder Dauersuchen.
- **FR-119**: Beim Entfernen einer Quelle oder persönlicher Daten abhängige Graph-/Index-/Exportvorschläge markieren oder bereinigen; exportierte Dateien nur innerhalb bestehender Schreibfreigabe verändern und externe Kopien nicht als gelöscht behaupten.
- **FR-120**: KI-generierte Fragen und Graphlabels als nicht vertrauenswürdige Daten behandeln; sie dürfen keine URL-/Datei-/Tool-Aktion außerhalb des bestätigten Scopes auslösen.

**Acceptance Scenarios:**

1. **Given** eine beendete Session und vier verifizierte Quellen; **When** der Abschluss erscheint; **Then** fragt die App nach Vertiefen, Parken oder Verwerfen und nennt die belegte Anzahl.
2. **Given** ich parke die Session; **When** Export und lokale Speicherung bestätigt sind; **Then** bleibt eine verknüpfte Wissenslandkarte, nicht bloß eine Liste abgespielter Sekunden.
3. **Given** ich verwerfe den Vorschlag; **When** ich später mein Highlight öffne; **Then** ist das Original erhalten und die vorgeschlagene Kuration kann rückgängig gemacht werden.
4. **Given** die Kopfhörer trennen sich; **When** Wiedergabe pausiert; **Then** wartet die Abschlussfrage bis zum wirklichen Sessionende.

### Zusätzliche messbare Abnahmekriterien
100 % der Fixture-Quellenzahlen entsprechen deduplizierten verfügbaren Quellen. Kein implizites Zustimmungs- oder sensibles Überzeugungsprofil aus dem Verlauf. Kein automatischer Neustart am Sessionende. Jeder geparkte Graph ist referenziell konsistent und exportierbar. Jeder Konflikt zwischen Parken und Verwerfen ist ohne Verlust menschlicher Inhalte rekonstruierbar. Diese Ziele sind keine bereits gemessenen App-Ergebnisse.

## Erweiterung 1.3 — Smart Podcast List

### US17 — Eigene Themen-Podcasts aus ungehörten Originalstellen abonnieren (Priority: P1)

**Independent Test:** Deterministischer Themenkorpus, Feedkonfiguration und leere Ledger erzeugen eine Ausgabe; zweiter Lauf erzeugt keine Dublette.

**Acceptance Scenarios:**
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Zwei Themenfeeds und einen gemischten Feed anlegen; nach Neustart bleiben IDs, Themen und Ausgaben erhalten.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Konfiguriertes Profil ohne Lernfreigabe verwenden; mehrfaches Play fordert kein Profilinterview und ändert das Profil nicht.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Teilanalysierten Korpus wählen; Coverage und enthaltene Quellen stimmen; nicht erlaubte Quelle bleibt ausgeschlossen.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Zweimal denselben Kandidatenlauf ausführen: eine logische Ausgabe; Titelwechsel allein erzeugt keine neue Folge.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Alte Originalquelle als neue persönliche Ausgabe bündeln; korrekte Daten und absatzbezogene Evidence-IDs prüfen.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Mehr Treffer als eine Ausgabeseite bereitstellen; kein Top-k-Verlust, Rest folgt sichtbar; Kurzfassung nennt nicht alles.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Während Wiedergabe neue Segmente einspeisen; bestehendes Manifest bleibt byteidentisch, nächste Ausgabe ist separat.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Audiofassung austauschen bzw. Quelle löschen; betroffene Segmente sichtbar nicht verfügbar, kein Zeittransfer auf fremde Fassung.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Nichts-Neues-Fall erzeugt keine leere Folge; Screenreader liest Thema, Quellenzahl und Coveraktion; Notification ohne Autorisierung bleibt aus.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Manifest und Markdown gegen aktuelle Revision prüfen; private URLs redigiert, Original-/persönliche Zeiten stimmen.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Synthetische Themen iOS, Google/KI, EnBW und Datenschutz verwenden; vollständigen Ablauf einschließlich Re-Refresh, Queue-Ende und Cover-Abbruch testen.

### US18 — In einer Folge oder persönlichen Ausgabe nur relevante Stellen hören (Priority: P1)

**Independent Test:** Geprüftes Segmentmanifest und Fake-Player testen Reihenfolge, Grants und zweifache Zeitachse ohne Modell.

**Acceptance Scenarios:**
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Eine Folge mit drei passenden Abschnitten starten; nur diese werden abgespielt; Ganz hören bleibt erreichbar.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Play autorisiert genau den Plan; Quellenwechsel läuft weiter; Hintergrundveröffentlichung erzeugt keinen Ton.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Persönliche Position in Segment 2 auf Originalzeit abbilden; 1,5-fache Rate verändert Quellenzeitmapping nicht.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Kein TTS-Aufruf im Ausgabepfad; Sourcewechsel sichtbar, Originalclip und dessen geprüfte Grenzen unverändert.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Ausgabefrage darf nur Manifestbelege verwenden; unbekannter Sprecher wird nicht benannt; Sprung ins Original funktioniert.

### US19 — Ungehörtes über alle Wiedergabewege und Geräte erkennen (Priority: P1)

**Independent Test:** Intervall-Fixtures testen Union, Seeklücken, Teilfolgen, Kontextwiederholung und Epoch-Reset.

**Acceptance Scenarios:**
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Spielen 10–20 s, Springen auf 60 s und Spielen 60–65 s erzeugt genau diese zwei Intervalle, nicht 10–65 s.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Abschnitt im Themenfeed hören; derselbe Abschnitt gilt beim Original und zweiten Feed als abgespielt, übrige Folge nicht.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Teilgehörte Aussage mit Kontext prüfen; neue Restbelege erhalten gültige Grenzen, Kontext als Wiederholung markieren.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Teils gehörte Folge bleibt im Restfilter; fehlt im Nie-gestartet-Filter; manuell erledigt erzeugt keine Hörintervalle.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Zwei Offlinegeräte mit gleichen Kandidaten und überlappenden Hörintervallen mergen ohne doppelte neue Segmente; Watch zeigt nur vollständig geladene Pakete offline-bereit.

### US20 — Eigene Episodencover mit nativem Fallback und Image Playground gestalten (Priority: P1)

**Independent Test:** CoverCoordinator mit Fakes simuliert Verfügbarkeit, Bestätigung, Abbruch und Assetpersistenz; reale Sheet-Tests bleiben Geräteabnahmen.

**Acceptance Scenarios:**
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** ImageCreator ist im neuen Featurecode abwesend; native Sheet-Integration prüfen; externe Provider nicht in erlaubten Stilen.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Ohne Modell, offline und bei Cover-Abbruch erscheint ein eigenes natives Cover; Audioausgabe bleibt nutzbar.
- **Given** der zugehörige Testaufbau; **When** die Aktion ausgeführt wird; **Then** Temporärdatei nach Kopie entfernen; gespeichertes Cover bleibt; abgebrochene Auswahl ersetzt kein bisheriges Asset.

### Verbindliche funktionale Anforderungen

- **FR-121** [US17]: Die App MUSS persistente persönliche Themen-Feeds mit eigenen Ausgaben, Titel, Shownotes, Cover und unveränderlichem Originalsegmentmanifest bereitstellen; getrennte und gemischte Themenlisten ermöglichen.

- **FR-122** [US17]: Die App MUSS bestätigte konfigurierte Interessen übernehmen und optional korrigierbar dazulernen; vor jedem Play keine erneute Interessenabfrage verlangen.

- **FR-123** [US17]: Die App MUSS den Quellen-Scope je Feed festhalten; verfügbare, analysierte, passende und enthaltene Inhalte getrennt ausweisen; keine unangekündigte Websuche ausführen.

- **FR-124** [US17]: Die App MUSS neue persönliche Folgen nur aus neuen passenden, ungehörten und abspielbaren Kernsegmenten veröffentlichen; wiederholten Refresh und Offline-Doppelentwürfe anhand stabiler Identität deduplizieren.

- **FR-125** [US17]: Die App MUSS titel und textuelle Shownotes nur aus dem finalen Segmentmanifest erzeugen; Originaldatum und persönliche Veröffentlichung unterscheiden; alte Inhalte als neu für dich statt neu veröffentlicht kennzeichnen.

- **FR-126** [US17]: Die App MUSS alles Ungehörte als umfassenden Modus von budgetierter Auswahl unterscheiden; bei Pagination, Limits oder unvollständiger Analyse Restbestand und Abdeckung sichtbar halten.

- **FR-127** [US17]: Die App MUSS publizierte oder gestartete persönliche Ausgaben nicht heimlich neu zusammensetzen; bewusste Restfassungen als neue Revision mit aktualisierten Shownotes und Grant behandeln.

- **FR-128** [US18]: Die App MUSS pro Originalfolge Ganz hören, Für mich relevante Stellen und einzelne Belegsprünge anbieten; passende Originalabschnitte innerhalb eines bestätigten Plans automatisch nacheinander spielen.

- **FR-129** [US18]: Die App MUSS einmaliges Play oder expliziten Chat-Wiedergabewunsch als begrenzte Startfreigabe verwenden; keine erneute Bestätigung pro Segment und kein Tonstart durch Empfehlungen, Refresh oder Sync.

- **FR-130** [US19]: Die App MUSS abgespielte Originalzeitintervalle pro MediaVersion global vereinigen; Seek, Download, Analyse, Lesen und Buffering niemals als gehörte Zeit erfassen.

- **FR-131** [US19]: Die App MUSS gemeinsamen Hörverlauf zwischen Originalfolgen, Chat-Fokus, Themenfeeds und Geräten anwenden; Fokuswiedergabe markiert nicht die komplette Originalfolge als gehört.

- **FR-132** [US19]: Die App MUSS noch ungehörte Kernbereiche von nötiger Kontextwiederholung trennen; bereits geplante Dubletten und explizite Ausschlüsse gesondert führen; semantische Ähnlichkeit allein ist keine Dublette.

- **FR-133** [US19]: Die App MUSS ungehörte Abschnitte auch aus angefangenen Folgen und Nur noch nicht gestartete Originalfolgen als zwei Filter anbieten; unbekannte Historie und manuell erledigte Inhalte separat kennzeichnen.

- **FR-134** [US18]: Die App MUSS persönliche und originale Zeitachsen deterministisch aus dem Manifest abbilden; Resume, Kapitel, Fernsteuerung und Watch verwenden denselben bestätigten Plan.

- **FR-135** [US18]: Die App MUSS audio in Originalstimmen ohne KI-Nachsprache oder gesprochene KI-Überleitungen wiedergeben; Quellenwechsel kenntlich machen, Kontext und Qualifikationen erhalten.

- **FR-136** [US18]: Die App MUSS kapitel, Quellen, belegte Sprechernamen, Originalzeitcodes, persönliche Zeit und Original-Weiterhören anbieten; Fragen zur persönlichen Ausgabe auf deren Originalbelege begrenzen.

- **FR-137** [US19]: Die App MUSS feedkonfigurationen, Manifestrevisionen, Ledger-Events und Coverreferenzen optional über vorhandenen privaten Sync übertragen; Epochs, Deduplizierung und vollständige Watch-Packs prüfen.

- **FR-138** [US17]: Die App MUSS quellenverlust, geänderte Medienfassung, Löschung und Profilreset in abhängigen persönlichen Folgen und Reservierungen berücksichtigen; veraltete Belege nicht abspielen.

- **FR-139** [US20]: Die App MUSS image-Playground-Cover ausschließlich über unterstützten nutzergeführten Systemdialog auf Vollclients anbieten; Apple-Stile begrenzen und externe Provider ausschließen; ImageCreator nicht verwenden.

- **FR-140** [US20]: Die App MUSS sofort ein automatisches natives Titel-/Themen-Cover bereitstellen; optional bestätigtes Feedmotiv wiederverwenden; dies nicht als neue automatische Image-Playground-Generierung bezeichnen.

- **FR-141** [US20]: Die App MUSS bestätigtes Image-Playground-Ergebnis vor Ablauf temporärer Datei atomar speichern, prüfen und versionieren; Cover-Provenienz und Motivdatensparsamkeit beachten; Watch zeigt synchronisiertes Asset.

- **FR-142** [US17]: Die App MUSS keine neuen Segmente, unvollständige Analyse und nicht verfügbare Quellen als eigene Zustände zeigen; Veröffentlichung atomar vor optionaler Benachrichtigung committen; Accessibility und Datenschutz auf allen vier Plattformen berücksichtigen.

- **FR-143** [US17]: Die App MUSS persönliche Folge und Feedkonfiguration als Markdown bzw. sicheres Manifest exportieren: Originalquellen, Zeitmapping, Shownotes, Analyseumfang und Coverherkunft; keine implizite öffentliche Audioveröffentlichung.

- **FR-144** [US17]: Die App MUSS den gesamten Themenfeed-Ablauf von Konfiguration über ungehörte Originalsegmente, Publikation, Play, erneute Aktualisierung und Cover-Fallback mit plattformbezogenen Abnahmen belegen.

Detail: [smart-podcast-list.md](smart-podcast-list.md). Automatische Bildgenerierung ist nicht mit Image-Playground-Systemdialog gleichzusetzen; FR-139–141 und [A27–A30] sind verbindlich.

**Aktueller Spezifikationsstand:** 1.3 vom 2026-09-20. Frühere Entwurfsdaten bleiben historisch nachvollziehbar.
