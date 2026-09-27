# PodcastAI bauen und testen

## Voraussetzungen

- Xcode 27
- XcodeGen, falls du das Projekt aus `project.yml` neu erzeugen willst: `brew install xcodegen`

## Öffnen und starten

```bash
cd app
xcodegen generate     # nur nach Änderungen an project.yml nötig
open PodcastAI.xcodeproj
```

| Schema | Ziel |
|---|---|
| `PodcastAI` | iPhone und iPad |
| `PodcastAIMac` | Mac, nativ ohne Catalyst |

Signiert wird automatisch mit dem Team Mobile Box (`SP73Z8JWXM`).

Beide Apps betten die Share Extension „An PodcastAI senden“ ein (`PodcastAIShare` in `com.godmodeai.podcastai.mobile.share`, `PodcastAIShareMac` in `com.godmodeai.podcastai.mac.share`). Apps und Erweiterungen teilen die App Group `group.com.godmodeai.podcastai`. Der erste signierte Build danach braucht `-allowProvisioningUpdates` (das TestFlight-Skript setzt es) oder einmal Xcode mit angemeldetem Account, damit die beiden App-IDs entstehen und die Gruppe in die Profile kommt. Ohne Signatur (`CODE_SIGNING_ALLOWED=NO`) bauen beide Schemata auch vorher.

## Tests

Die Logik im Swift-Paket hat eigene Tests, darunter die Löschregeln und die Suche für den Chat:

```bash
cd app/Packages/PodcastAIKit
swift test
```

Ein Ende-zu-Ende-Test lädt eine echte Folge, transkribiert sie und prüft die Belege mit Zeitmarken. Er braucht Netz und die Spracherkennung des Mac:

```bash
PODCASTAI_LIVE=1 swift test --filter LiveAnalysisTests
```

Die Oberfläche testen UI-Tests im Simulator: Feeds aus dem TestFlight-Feedback abonnieren, Folge mit ihren Reitern öffnen, abspielen, Fragen an eine Folge, Export, Löschen, Einstellungen.

```bash
xcodebuild -project PodcastAI.xcodeproj -scheme PodcastAI \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Die Mac-App hat eigene UI-Tests (`PodcastAIMacUITests`): Bereiche über ⌘1 bis ⌘7, Inspektor, Hilfe-Menü und dass Öffnen nichts abspielt. Sie brauchen einen signierten Build und die Freigabe für Bedienungshilfen:

```bash
xcodebuild -project PodcastAI.xcodeproj -scheme PodcastAIMac \
  -only-testing:PodcastAIMacUITests test
```

## iCloud

Beide Apps nutzen den CloudKit-Container `iCloud.com.godmodeai.podcastai`. Nach Änderungen am Datenmodell das Schema neu anlegen und in der CloudKit-Konsole nach Production übertragen:

```bash
# signierter Debug-Build des Mac-Schemas, dann:
PodcastAI.app/Contents/MacOS/PodcastAI -initialize-cloudkit-schema
```

## Widget und App Group

Beide Apps betten eine Widget-Erweiterung ein: `PodcastAIWidget` (`com.godmodeai.podcastai.mobile.widget`) und `PodcastAIMacWidget` (`com.godmodeai.podcastai.mac.widget`). Apps und Erweiterungen teilen die App Group `group.com.godmodeai.podcastai`; dort legt die App den Schnappschuss ab, den das Widget liest. Für einen signierten Build müssen App Group und die beiden neuen Bundle-IDs im Entwicklerkonto stehen. Das erledigt die automatische Signatur, wenn sie Profile anlegen darf: einmal in Xcode bauen oder `-allowProvisioningUpdates` mitgeben, wie es `scripts/upload-testflight.sh` tut. Ohne Signatur (`CODE_SIGNING_ALLOWED=NO`) bauen alle Targets, das Widget bleibt dann leer.

Das Widget öffnet die App über `podcastai://topicupdates` und `podcastai://tag/<Kennung>`.

## Agentenzugang auf dem Mac

MCP (Model Context Protocol) ist das Verfahren, mit dem KI-Programme wie Claude Desktop oder Claude Code andere Programme als Werkzeug nutzen. Die Mac-App bringt einen solchen Zugang mit, nur lesend. Die iPhone- und iPad-App haben ihn nicht, auch nicht, wenn die iPad-App auf einem Mac mit Apple-Chip läuft; ihre Hilfe sagt das dann ausdrücklich.

Was ein Agent lesen kann, mit einer Freigabe für ausgewählte Podcasts:

| Werkzeug | Liefert |
|---|---|
| `listPodcasts` | die freigegebenen Podcasts mit Kennung, Titel, Sprache und Zahl der Folgen mit Transkript |
| `listInterests` | die Tags, denen der Nutzer folgt, für die ganze Mediathek |
| `searchEvidence` | Stellen aus Transkripten mit Podcast, Folge, Datum und Zeitmarke; gesucht wird wie im Chat, mit Stichworten und Sätzen ähnlicher Bedeutung, optional nur in einem Podcast |
| `getEvidence` | eine Stelle über ihre Kennung |
| `listHighlights` | gemerkte Stellen mit Notiz, nur wenn Notizen freigegeben sind |
| `listTrails` | gesicherte Antworten mit Frage, Antwort und Stellen, nur wenn Notizen freigegeben sind |

Kein Werkzeug schreibt, löscht oder startet Wiedergabe.

In drei Schritten, alles unter PodcastAI › Einstellungen › Agenten:

1. „Agentenzugang erlauben“ einschalten.
2. Den Agenten eintragen. Die Einstellungen zeigen beides fertig zum Kopieren, mit dem Pfad, unter dem die App gerade liegt.
   - Claude Desktop: den Eintrag in den Block `mcpServers` der Datei `~/Library/Application Support/Claude/claude_desktop_config.json` setzen, dann Claude Desktop mit ⌘Q beenden und neu öffnen. Meldungen von PodcastAI stehen danach in `~/Library/Logs/Claude/mcp-server-podcastai.log`.
     ```json
     "podcastai": {
       "command": "/Applications/PodcastAI.app/Contents/MacOS/PodcastAI",
       "args": ["--mcp"]
     }
     ```
     Für eine neue oder leere Datei gibt es „Ganze Datei kopieren“, mit der Hülle `{"mcpServers": {…}}`.
   - Claude Code: im Terminal
     ```sh
     claude mcp add --scope user podcastai -- /Applications/PodcastAI.app/Contents/MacOS/PodcastAI --mcp
     ```
     `--scope user` trägt den Server für alle Projekte ein. `claude mcp list` zeigt danach, ob die Verbindung steht.
3. Podcasts wählen, auf Wunsch Notizen einschließen, eine Dauer von 1 bis 24 Stunden wählen und „Freigeben“. Wahlweise gilt die Freigabe nur für einen Agenten, der sich schon einmal verbunden hat; zur Wahl stehen nur Namen, die Agenten selbst gemeldet haben, sodass sich der echte Agent nicht durch einen Tippfehler aussperren lässt. Der Name ist keine Sicherheitsgrenze.

Läuft die Freigabe ab, bekommt der Agent auf jede Anfrage eine Absage mit Datum und Uhrzeit des Ablaufs. „Erneuern“ gibt denselben Umfang für dieselbe Dauer wieder frei. Unter „Was gelesen wurde“ stehen die letzten Anfragen mit Uhrzeit, Agent, Suchbegriff und Zahl der Treffer, auch jede Absage.

Technisch: Der Agent startet das Programm der Mac-App selbst, mit `--mcp`, und spricht über Standardein- und -ausgabe mit ihm (JSON-RPC, eine Nachricht pro Zeile). Einen Netzwerk-Port gibt es nicht, die App muss nicht offen sein. In diesem Modus startet keine Oberfläche; der Prozess öffnet die Datenbank ohne iCloud-Abgleich, ändert an der Mediathek nichts und endet mit dem Ende der Eingabe. Schreiben tut er nur in die Einstellungen der App: sein Protokoll und den Namen, mit dem sich der Agent meldet. Schalter, Freigabe und Protokoll liegen in den Benutzereinstellungen der App, die der Prozess bei jeder Anfrage neu liest. Ist der Schalter aus, beantwortet er `initialize` und `tools/list` weiter, jeder Werkzeugaufruf bekommt aber eine Absage. Einzelheiten in [docs/architektur.md](../docs/architektur.md#agentenzugang-über-mcp).

Startet macOS die App frisch geladen aus einem vorläufigen Ordner, warnt die Seite: Eintrag und Befehl zeigten sonst beim nächsten Start ins Leere. Liegt die App später woanders, braucht der Agent den neuen Eintrag.

## Podcast-Katalog

Suche, Angesagt und Kategorien im Blatt „Podcast hinzufügen“ fragen öffentliche Schnittstellen, ohne Konto und ohne Anmeldung. Charts und Kategorien kommen von Apple Podcasts, und zwar für das Land aus der Region des Geräts (ohne Region die USA). Gesucht wird bei Apple und bei Podcast Index zugleich, die Treffer werden zusammengeführt. Einzelheiten stehen in [docs/architektur.md](../docs/architektur.md#podcast-katalog).

Für UI-Tests gibt es `-catalog-fixtures`: Charts, Einzelheiten, beide Suchen und die Feeds der Podcast-Seiten antworten dann in Debug-Builds aus `CatalogFixtures`, ohne Netz.

## TestFlight

```bash
app/scripts/upload-testflight.sh
```

Das Skript erhöht die Buildnummer, archiviert iOS und macOS und lädt beide über den in Xcode angemeldeten Account hoch. Voraussetzung sind die beiden App-Einträge in App Store Connect.

## Aufbau

```
Packages/PodcastAIKit/Sources/
  PodcastAICore          Domäne, nur Foundation
  PodcastAISources       RSS und Atom, Linkauflösung, YouTube, Feed-Erkennung, Podcast-Katalog
  PodcastAIMedia         Download, Audio lesen und wandeln
  PodcastAITranscription SpeechAnalyzer mit Medienzeit
  PodcastAIIntelligence  Apple Intelligence, Gerät und Private Cloud Compute
  PodcastAIKnowledge     Relevanz, Suche für den Chat
  PodcastAIPlayback      Hörplan, Freigaben, Player
  PodcastAISmartFeeds    Persönliche Themenfeeds, Shownotes, Cover
  PodcastAIExport        Markdown für Folgen, Antworten und Notizen
  PodcastAIPersistence   SwiftData mit iCloud-Abgleich
  PodcastAIWidgetData    Schnappschuss fürs Widget in der App Group
  PodcastAIShareInbox    Eingang für „An PodcastAI senden“, eigenes Produkt für die Erweiterung
  PodcastAIKit           Sammelziel für die Apps, dazu AgentAccess/: MCP-Server, nur macOS

Apps/
  Shared/                AppModel, Dienste, gemeinsame Ansichten
  PodcastAI/             iOS: fünf Tabs, Mini-Player
  PodcastAIMac/          macOS: Seitenleiste, Inspektor, Player in der Symbolleiste, Menübefehle, Prozess für --mcp (MCPHost)
  PodcastAIWidget/       Widget „Was ist neu“ für iOS und macOS
  ShareExtension/        „An PodcastAI senden“ für iOS und macOS

UITests/                 UI-Tests für iOS
UITestsMac/              UI-Tests für die Mac-App
```

## Regeln im Code

1. **Nur Apple-Modelle.** Fehlt ein Modell, sagt die App das. Sie weicht nicht auf einen anderen Anbieter aus.
2. **Das Modell wählt nur aus.** Es antwortet mit Nummern aus einer vorgelegten Liste. Zeiten, Quellen und Rechte kommen aus dem Code. Was nicht passt, wird verworfen.
3. **Vorbereiten ja, abspielen nur auf Wunsch.** Jede Wiedergabe braucht eine Freigabe aus einer Handlung des Nutzers. Sie gilt kurz, für ein Gerät und genau einen Hörplan.
4. **Gespeichert oder gehört heißt nicht zugestimmt.**
