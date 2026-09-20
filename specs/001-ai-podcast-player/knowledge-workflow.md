# Highlights, semantische Suche, Transkripte und Smart Skip

## Highlights sind kein Hörfortschritt
`Highlight` besitzt eigene ID, Evidence-IDs, originalExcerpt, userNote, generatedSummary, origin, tags, transcriptRevisionID, editRevision und conflictOf. Ein explizites Capture im Player nimmt ein konfigurierbares rückblickendes Zeitfenster der tatsächlich aktiven Medienfassung, erweitert es auf gesicherte Satzgrenzen und zeigt den Vorschlag zur Korrektur. Ohne Transkript wird zunächst ein Zeitbookmark gesichert; KI-Text folgt erst nach gesicherter Analyse. Ungehörte, gelesene und tatsächlich gehörte Highlights bleiben unterschiedliche Nutzungssignale.

Native Einstiege: Playeraktion, Transkriptselektion, Watch-Kurzaktion und App Intent. Ein frei belegbarer Headphone-Doppeltap wird nicht als Apple-API erfunden. Nur öffentlich unterstützte Remote-Command-Events mit bewusstem Mapping dürfen verwendet werden. Vorhandene Play/Pause-/Skip-Semantik bleibt Standard.

## Suche über den gesamten erschlossenen Bestand
Default: alle freigegebenen analysierten Folgen, ausdrücklich auch ungehörte. Exakte Suche und semantische Suche koexistieren. Core Spotlight / SpotlightSearchTool ist der native aktuelle Ansatz auf den dokumentierten Vollplattformen. Es wird kein externer Vektordienst und kein eigener Whisper-/MLX-Stack eingebaut. Direkte Embedding-Vektorexporte sind kein notwendiges Produktmerkmal; entscheidend ist bedeutungsbasierter, getesteter Recall. [A10]

Ein Apple-semantischer Index kann vorbereitet werden, bevor eine Frage an das LLM geht. Indexstatus und Modellverfügbarkeit getrennt anzeigen. Sensible private Quellen dürfen separat vom systemweit sichtbaren Spotlight-Index ausgeschlossen werden. App-private Indexoptionen im SDK verifizieren; ohne nachgewiesene Suchisolierung nur freigegebene Inhalte dort indexieren. Nicht indexierte Inhalte bleiben mit erlaubter lokaler exakter Suche auffindbar. Jede Treffer-ID wird zusätzlich gegen tatsächlichen ChatScope und aktuelle Zugangsrevision geprüft.

## Exporttypen
Markdown bleibt der Wissensexport. SRT, WebVTT, TXT und versioniertes JSON sind Transkriptexporte. SRT verwendet bestehende Millisekunden-Cues, VTT kann vorhandene Sprecherlabels tragen. Word-level timestamps sind capabilityabhängige Daten, keine aus Wortlängen erfundenen Werte. Unbekannte Sprecher bekommen keine reale Identität zugeordnet. Eventuelle Sprechercluster sind keine Personenidentifikation. Originalsprache, Übersetzung und manuelle Korrektur erhalten separate Revisionen.

Optional native Translation auf passenden Vollplattformen; SDK-/Sprachpaar-/Assetverfügbarkeit prüfen. Keine Zusage von Echtzeitübersetzung in einer pauschalen Anzahl von Sprachen. Fehlende Übersetzung blockiert weder Originaltranskript noch Chat im verfügbaren Modus. [A25]

## Smart Skip
Nur optional für zulässiges RSS-/Importaudio. Publisher- bzw. sicher erkannte Intro-/Outro-/Werbebereiche sind versionierte `SkipCandidate`-Objekte mit Herkunft und Reviewstatus. Unsichere Kandidaten markieren statt automatisch überspringen. Ein Nutzer kann „diese Bereiche automatisch überspringen“ je Quelle freigeben. Der Originalbeleg und die Medienzeitachse bleiben unverändert, Skip kann rückgängig gemacht werden. YouTube-Werbung und sichtbarer offizieller Player werden nicht manipuliert. [Y02]

Smart Skip und Fokusmodus sind unterschiedlich: Fokus beantwortet eine inhaltliche Auswahl, Smart Skip entfernt optional bestätigte nichtinhaltliche Bereiche. Im Beleg-Kontext darf Smart Skip keine Einschränkung oder Gesprächswendung entfernen. Bei Konflikt gewinnt Belegkontext.

## Pipeline und Cache
DAG: acquisition → decode → transcript → alignment → chapters / claims / index → personalRelevance → focusPlan. Schlüssel je Artefakt aus Eingabehash, Medien-/Transkriptrevision, Algorithmus-/Prompt-/Modell-/Schemaversion und relevanter Policy. Interessenupdate invalidiert Relevanz, nicht ASR. Reanalyse erstellt neue Ableitungen, ohne menschliche Notizen zu überschreiben. Keine Gleichsetzung von „neu gerechnet“ und „wahrer“.

## Formate
Die Zusage lautet native getestete Decodierung, nicht „jede Dateiendung überall“. AAC/MP3/M4A/ALAC/FLAC und OGG/Opus werden als Matrix von Container × Codec × Plattform × Streaming/Datei getestet. Ist eine Kombination nicht über Apple-APIs nutzbar, erklärender unsupportedFormat-Zustand statt stiller Drittcodecinstallation. Audioqualität, Lautheit und Renderpräzision gesondert testen.
