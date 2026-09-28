# CloudKit-Schema für die nächste Version (0.15)

Stand 28. September 2026, Branch `schema-release` auf Basis von 0.14 (282eee0). Die Schemaänderung, die Entscheidung 11 in [plan-pipeline.md](plan-pipeline.md) auf diese Release verschoben hat, dazu die Unterhaltungen im Chat.

Nichts hiervon ist in CloudKit angelegt. Die Liste ist die Vorlage für den Product Owner: in die Development-Umgebung von `iCloud.com.godmodeai.podcastai` importieren, prüfen, nach Production übertragen. Erst danach gleichen TestFlight-Builds mit dem neuen Schema ab.

## Kurz

- **Drei neue Record-Typen:** `CD_StoredChatConversation`, `CD_StoredSourceRemoval`, `CD_StoredProcessingLease`.
- **Keine neuen Felder an vorhandenen Typen.** Nichts entfernt, nichts umbenannt, kein Typ eines Felds geändert.
- `CD_StoredMediaVersion.CD_localRelativePath` bleibt im Schema. Die neue App schreibt es nicht mehr, ältere Apps lesen und schreiben es weiter.
- Die feste Sprache in der Kennung des Transkripts ändert nur Werte in `CD_StoredTranscript.CD_identifier`, nicht das Schema.
- Die `#Index`-Angaben der Modelle sind Indizes in der lokalen SQLite-Datei, CloudKit sieht sie nicht.

## Warum das für ältere Apps sicher ist

- Neue Typen kennt eine ältere App nicht. NSPersistentCloudKitContainer lädt Records unbekannter Typen nicht in ihr Modell, sie arbeitet wie bisher.
- Jede neue Eigenschaft hat einen Standardwert oder ist optional, es gibt keine eindeutigen Schlüssel und keine Beziehungen. Kommt ein Record ohne ein Feld an, gilt der Standardwert.
- Eine abbestellte Quelle verschwindet für eine ältere App genau wie bisher: Die Quellzeile wird gelöscht. Das Merkzeichen liegt daneben in einem eigenen Typ. Ein Feld an `CD_StoredSource` hätte die Zeile am Leben gehalten, und eine ältere App zeigte die Quelle weiter an.
- `localRelativePath` bleibt stehen, damit ältere Apps ihre Zeilen weiter lesen und schreiben. Leeren wäre auch ein Schreiben an alle Geräte, deshalb bleibt der alte Wert stehen, wo er ist.
- Ein Transkript mit fester Sprache in der Kennung ist für eine ältere App ein gewöhnliches Transkript. Sie findet es über die Fassung (`transcript(forMedia:)`) wie jedes andere.

## Die Typen aus Swift

| Swift | Feld in CloudKit | Zusatzfeld |
|---|---|---|
| `String`, auch optional | `STRING QUERYABLE SEARCHABLE SORTABLE` | dazu `<Feld>_ckAsset ASSET` |
| `[String]` | `BYTES QUERYABLE SORTABLE` | dazu `<Feld>_ckAsset ASSET` |
| `Int`, `Bool` | `INT64 QUERYABLE SORTABLE` | |
| `Date` | `TIMESTAMP QUERYABLE SORTABLE` | |
| `Double` | `DOUBLE QUERYABLE SORTABLE` | |
| `Data` mit `.externalStorage` | `BYTES` | dazu `<Feld>_ckAsset ASSET` |

Jeder neue Record-Typ braucht außerdem, wie die vorhandenen:

- `CD_entityName STRING QUERYABLE SEARCHABLE SORTABLE`
- `CD_moveReceipt BYTES` und `CD_moveReceipt_ckAsset ASSET`
- die Systemfelder `___createTime TIMESTAMP`, `___createdBy REFERENCE`, `___etag STRING`, `___modTime TIMESTAMP`, `___modifiedBy REFERENCE`, `___recordID REFERENCE QUERYABLE`
- die Rechte der vorhandenen Typen: `GRANT WRITE TO "_creator"`, `GRANT CREATE TO "_icloud"`, `GRANT READ TO "_world"`. Vor dem Import mit dem Export der Development-Umgebung vergleichen und genau dieselben nehmen.

## CD_StoredChatConversation

Unterhaltungen im Chat (`StoredChatConversation.swift`), aus dem Branch der Unterhaltungen. Neu gegenüber 0.14.

| Feld | Swift | CloudKit |
|---|---|---|
| `CD_identifier` | `String = ""` | STRING QUERYABLE SEARCHABLE SORTABLE |
| `CD_identifier_ckAsset` | | ASSET |
| `CD_scopeKey` | `String = ""` | STRING QUERYABLE SEARCHABLE SORTABLE |
| `CD_scopeKey_ckAsset` | | ASSET |
| `CD_title` | `String = ""` | STRING QUERYABLE SEARCHABLE SORTABLE |
| `CD_title_ckAsset` | | ASSET |
| `CD_createdAt` | `Date = Date()` | TIMESTAMP QUERYABLE SORTABLE |
| `CD_updatedAt` | `Date = Date()` | TIMESTAMP QUERYABLE SORTABLE |
| `CD_turnCount` | `Int = 0` | INT64 QUERYABLE SORTABLE |
| `CD_formatVersion` | `Int = 1` | INT64 QUERYABLE SORTABLE |
| `CD_payload` | `Data = Data()`, `.externalStorage` | BYTES |
| `CD_payload_ckAsset` | | ASSET |

## CD_StoredSourceRemoval

Das Merkzeichen „Quelle abbestellt“ (`StoredSourceRemoval.swift`). Je Abbestellung eine Zeile, mehrere je Quelle sind erlaubt, es gilt die jüngste.

| Feld | Swift | CloudKit |
|---|---|---|
| `CD_sourceIdentifier` | `String = ""` | STRING QUERYABLE SEARCHABLE SORTABLE |
| `CD_sourceIdentifier_ckAsset` | | ASSET |
| `CD_removedAt` | `Date = Date()` | TIMESTAMP QUERYABLE SORTABLE |
| `CD_deviceIdentifier` | `String?` | STRING QUERYABLE SEARCHABLE SORTABLE |
| `CD_deviceIdentifier_ckAsset` | | ASSET |

## CD_StoredProcessingLease

Die Sperre über Geräte hinweg (`StoredProcessingLease.swift`). Eine Zeile je Gerät, Folge und Art, sie wird während der Arbeit alle fünf Minuten verlängert und danach gelöscht.

| Feld | Swift | CloudKit |
|---|---|---|
| `CD_identifier` | `String = ""` | STRING QUERYABLE SEARCHABLE SORTABLE |
| `CD_identifier_ckAsset` | | ASSET |
| `CD_episodeIdentifier` | `String = ""` | STRING QUERYABLE SEARCHABLE SORTABLE |
| `CD_episodeIdentifier_ckAsset` | | ASSET |
| `CD_kindRaw` | `String = ""` | STRING QUERYABLE SEARCHABLE SORTABLE |
| `CD_kindRaw_ckAsset` | | ASSET |
| `CD_deviceIdentifier` | `String = ""` | STRING QUERYABLE SEARCHABLE SORTABLE |
| `CD_deviceIdentifier_ckAsset` | | ASSET |
| `CD_acquiredAt` | `Date = Date()` | TIMESTAMP QUERYABLE SORTABLE |
| `CD_expiresAt` | `Date = Date()` | TIMESTAMP QUERYABLE SORTABLE |

## Als Schema-Datei

Zum Einfügen in den Export (`xcrun cktool export-schema … --environment development`), vor `validate-schema` und `import-schema`:

```
RECORD TYPE CD_StoredChatConversation (
    "___createTime" TIMESTAMP,
    "___createdBy"  REFERENCE,
    "___etag"       STRING,
    "___modTime"    TIMESTAMP,
    "___modifiedBy" REFERENCE,
    "___recordID"   REFERENCE QUERYABLE,
    CD_createdAt           TIMESTAMP QUERYABLE SORTABLE,
    CD_entityName          STRING QUERYABLE SEARCHABLE SORTABLE,
    CD_formatVersion       INT64 QUERYABLE SORTABLE,
    CD_identifier          STRING QUERYABLE SEARCHABLE SORTABLE,
    CD_identifier_ckAsset  ASSET,
    CD_moveReceipt         BYTES,
    CD_moveReceipt_ckAsset ASSET,
    CD_payload             BYTES,
    CD_payload_ckAsset     ASSET,
    CD_scopeKey            STRING QUERYABLE SEARCHABLE SORTABLE,
    CD_scopeKey_ckAsset    ASSET,
    CD_title               STRING QUERYABLE SEARCHABLE SORTABLE,
    CD_title_ckAsset       ASSET,
    CD_turnCount           INT64 QUERYABLE SORTABLE,
    CD_updatedAt           TIMESTAMP QUERYABLE SORTABLE,
    GRANT WRITE TO "_creator",
    GRANT CREATE TO "_icloud",
    GRANT READ TO "_world"
);

RECORD TYPE CD_StoredSourceRemoval (
    "___createTime" TIMESTAMP,
    "___createdBy"  REFERENCE,
    "___etag"       STRING,
    "___modTime"    TIMESTAMP,
    "___modifiedBy" REFERENCE,
    "___recordID"   REFERENCE QUERYABLE,
    CD_deviceIdentifier         STRING QUERYABLE SEARCHABLE SORTABLE,
    CD_deviceIdentifier_ckAsset ASSET,
    CD_entityName               STRING QUERYABLE SEARCHABLE SORTABLE,
    CD_moveReceipt              BYTES,
    CD_moveReceipt_ckAsset      ASSET,
    CD_removedAt                TIMESTAMP QUERYABLE SORTABLE,
    CD_sourceIdentifier         STRING QUERYABLE SEARCHABLE SORTABLE,
    CD_sourceIdentifier_ckAsset ASSET,
    GRANT WRITE TO "_creator",
    GRANT CREATE TO "_icloud",
    GRANT READ TO "_world"
);

RECORD TYPE CD_StoredProcessingLease (
    "___createTime" TIMESTAMP,
    "___createdBy"  REFERENCE,
    "___etag"       STRING,
    "___modTime"    TIMESTAMP,
    "___modifiedBy" REFERENCE,
    "___recordID"   REFERENCE QUERYABLE,
    CD_acquiredAt                TIMESTAMP QUERYABLE SORTABLE,
    CD_deviceIdentifier          STRING QUERYABLE SEARCHABLE SORTABLE,
    CD_deviceIdentifier_ckAsset  ASSET,
    CD_entityName                STRING QUERYABLE SEARCHABLE SORTABLE,
    CD_episodeIdentifier         STRING QUERYABLE SEARCHABLE SORTABLE,
    CD_episodeIdentifier_ckAsset ASSET,
    CD_expiresAt                 TIMESTAMP QUERYABLE SORTABLE,
    CD_identifier                STRING QUERYABLE SEARCHABLE SORTABLE,
    CD_identifier_ckAsset        ASSET,
    CD_kindRaw                   STRING QUERYABLE SEARCHABLE SORTABLE,
    CD_kindRaw_ckAsset           ASSET,
    CD_moveReceipt               BYTES,
    CD_moveReceipt_ckAsset       ASSET,
    GRANT WRITE TO "_creator",
    GRANT CREATE TO "_icloud",
    GRANT READ TO "_world"
);
```

## Reihenfolge beim Ausliefern

1. Die drei Typen in Development importieren und mit `validate-schema` prüfen.
2. Einen Debug-Build gegen Development laufen lassen und auf zwei Geräten eine Quelle abbestellen, eine Frage im Chat stellen und eine Folge transkribieren. Danach mit `export-schema` nachsehen, dass keine weiteren Felder entstanden sind.
3. In der CloudKit-Konsole „Deploy Schema Changes…“ nach Production.
4. Erst dann den TestFlight-Build hochladen. Ohne die Typen in Production scheitert der Export dieser Records, und Unterhaltungen, Merkzeichen und Sperren blieben auf dem Gerät.
