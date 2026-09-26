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

Ein KI-Agent kann über MCP lesend auf das Wissen zugreifen. Er startet dafür die Mac-App selbst, mit `--mcp`, und spricht über Standardein- und -ausgabe mit ihr. Einen Netzwerk-Port gibt es nicht. In diesem Modus startet keine Oberfläche; der Prozess öffnet die Datenbank ohne iCloud-Abgleich, liest nur und endet mit dem Ende der Eingabe.

```json
{
  "mcpServers": {
    "podcastai": {
      "args": ["--mcp"],
      "command": "/Applications/PodcastAI.app/Contents/MacOS/PodcastAI"
    }
  }
}
```

Den Eintrag mit dem richtigen Pfad zeigt die App unter PodcastAI › Einstellungen › Agenten. Dort wird der Zugang eingeschaltet, eine Freigabe mit Quellen und Ablaufzeit vergeben und das Protokoll gelesen. Schalter, Freigabe und Protokoll liegen in den Einstellungen der App, die der Agentenprozess bei jeder Anfrage neu liest. Ohne Freigabe beantwortet er keine Werkzeuganfrage.

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

Apps/
  Shared/                AppModel, Dienste, gemeinsame Ansichten
  PodcastAI/             iOS: fünf Tabs, Mini-Player
  PodcastAIMac/          macOS: Seitenleiste, Menübefehle, MCP-Server
  PodcastAIWidget/       Widget „Was ist neu“ für iOS und macOS
  ShareExtension/        „An PodcastAI senden“ für iOS und macOS

UITests/                 UI-Tests für iOS
```

## Regeln im Code

1. **Nur Apple-Modelle.** Fehlt ein Modell, sagt die App das. Sie weicht nicht auf einen anderen Anbieter aus.
2. **Das Modell wählt nur aus.** Es antwortet mit Nummern aus einer vorgelegten Liste. Zeiten, Quellen und Rechte kommen aus dem Code. Was nicht passt, wird verworfen.
3. **Vorbereiten ja, abspielen nur auf Wunsch.** Jede Wiedergabe braucht eine Freigabe aus einer Handlung des Nutzers. Sie gilt kurz, für ein Gerät und genau einen Hörplan.
4. **Gespeichert oder gehört heißt nicht zugestimmt.**
