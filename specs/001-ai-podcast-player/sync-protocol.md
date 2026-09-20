# Synchronisationsprotokoll und Konflikte

## Verantwortlichkeiten
SwiftData ist lokale Fachpersistenz; CKSyncEngine ist der Transportadapter zur privaten CloudKit-Datenbank. Automatischen SwiftData-CloudKit-Sync für dieselben Modelle nicht zusätzlich aktivieren. Fachänderung und Outbox-Eintrag entstehen gemeinsam in einer lokalen Transaktion. CKSyncEngine-StateSerialisierung wird separat haltbar gespeichert. [A12–A14]

App-eigene Envelopes aus `contracts/sync-envelope.schema.json` sind interne Fachverträge, keine Behauptung über Apples native CKRecord-JSON-Struktur. CKSyncEngine transportiert anhand echter SDK-Typen. Das Schema wird nicht ungeprüft in beliebige öffentliche Records geschrieben.

## Identität und Lieferung
Jede Operation trägt `operationID`, `deviceID`, ein streng steigendes `deviceSequence`, `entityID`, `entityRevision` und `resetEpoch`. Wiederholung derselben operationID ist idempotent. Eine gleiche Sequenz mit anderem Inhalt ist ein Integritätskonflikt. Wall-clock-Zeit dient der Anzeige, nicht als alleinige Kausalordnung.

CloudKit-Lieferung ist eventual. Keine dauerhaft verlässliche Onlinepräsenz und kein Exactly-once-Lock werden vorausgesetzt. Gleichzeitige Analyse derselben unveränderlichen Medien-/Transkriptrevision kann dedupliziert werden. Unterschiedliche Ergebnisse werden nicht blind als dasselbe Artefakt überschrieben.

## Fachliche Merge-Regeln
Hörereignisse sind append-only und besitzen eine Sessionidentität. Derselbe Sessionfortschritt folgt der Sequenz; verschiedene aktive Sessions lösen eine nachvollziehbare Konfliktentscheidung aus. Ein Rücksprung ist zulässig: größte Sekunde gewinnt ausdrücklich nicht immer.

Tatsächlich gehörte Intervalle derselben Medienfassung werden als Mengen vereinigt. Das erzeugt keine Vollhör-Markierung bei Lücken. Originalposition und Fokusposition bleiben getrennt.

Nutzertext und manuelle Notizen benutzen Versions-/Konfliktkopien; niemals eine fremde parallele Änderung unbemerkt verlieren. Queue-/Fokusreihenfolge benutzt stabile Eintrags-IDs und explizite Reorder-Operationen, nicht fragile Arrayindizes. Generierte Artefakte sind immutable je Pipeline-/Modell-/Inputrevision; aktive Auswahl ist ein separater Verweis.

Löschung erzeugt Tombstones und erhöht bei Profilreset die passende Reset-Epoch. Ältere Lernereignisse werden verworfen. Nach längerer Offlinezeit kann ein vollständiger Resync nötig sein; Tombstones nicht nach einem beliebig kurzen festen TTL entfernen. Noch offline befindliche Geräte haben bis zur nächsten erfolgreichen Synchronisation keine garantierte sofortige Fernlöschung.

## Watch
WatchConnectivity vermittelt iPhone/Watch, nicht Mac-RPC. Ein Pack ist erst bereit, wenn Manifest, Dateiabschluss, Bytehash, MediaVersion und Evidence-Referenzen geprüft sind. Sofortnachrichten setzen Reachability voraus; Hintergrundtransfer ist kein Sofortversprechen. Export-/Analyseaufträge besitzen eigene IDs und Acknowledgements. [A23]

## Niemals synchronisieren
PlaybackGrants, Zugriffstokens, private vollständige Feed-URLs, Rohcredentials, pauschale Prozesslogs und fremde Medienbytes ohne ausdrückliche Medien-/Aufbewahrungsregel. Nutzerentscheidungen für Profil-/Wissenssync gelten getrennt vom technischen Kontozustand.



## KnowledgeTrail-Entscheidungen
ClosingDecision ist ein append-only menschliches Ereignis mit sessionID, closingRevision, deviceID und monotoner lokaler eventSequence. IdempotencyKey gilt pro Close-Revision und Aktion. Parken/Verwerfen auf zwei offline Geräten ist ein fachlicher Konflikt; beide Varianten bleiben sichtbar. Eine rein modellgenerierte Neuordnung darf keine Benutzerentscheidung überschreiben.

Exportjob hat stabile ID und lokalen Commitstatus. `parkRequested` von Watch ist kein extern bestätigtes `exported`. Nur der Zielgeräteadapter bestätigt Export nach realem Schreibabschluss. Graphknoten/-kanten haben stabile appweite IDs, Lösch-Tombstones und profileEpoch; veraltete Geräte dürfen gelöschte private Graphdaten nicht wieder einspielen.

## Smart Feed / Ledger / Cover (1.3)
Feedkonfigurationen und PersonalEpisode-Revisionen besitzen stabile IDs. Batch-Identität verwendet kanonisch sortierte Originalsegmentidentitäten, nicht Titel, Cover oder Erstellungstimestamp. Hörverlauf vereinigt deduplizierte Events derselben MediaVersion/Epoch; Source-Sync überträgt niemals eine Tonfreigabe. Parallele Offlinepublikation darf höchstens vorübergehend zwei Darstellungen derselben logischen Ausgabe erzeugen; Merge dedupliziert und verhindert erneute Neu-Markierung.

CoverAssets werden erst nach atomarer Persistenz und Hashprüfung referenziert. Watch-Packs enthalten eingefrorenes Manifest, Coverthumbnail und zugängliche Audiodaten. Unvollständiges Pack ist nicht offline-bereit. Wiedergabeintervalle aus alten Epochs nach Reset und Tombstones nach Quellenlöschung sind zu verwerfen. Globale Reservierungen sind Konfliktregeln, keine behauptete CloudKit-Transaktion über alle Geräte.
