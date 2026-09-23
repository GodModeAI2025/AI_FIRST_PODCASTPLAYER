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

## Podcast-Katalog (Podcast Index)

Suche, Angesagt und Kategorien im Blatt „Podcast hinzufügen“ kommen von [Podcast Index](https://podcastindex.org). Dafür braucht die App einen Schlüssel mit Leserecht und das Geheimnis dazu, beides von [api.podcastindex.org](https://api.podcastindex.org). Sie stehen in einer Datei, die **nie ins Repository kommt**, denn es ist öffentlich:

```bash
cd app/Config/PodcastIndex
cp PodcastIndexCredentials.example.plist PodcastIndexCredentials.plist
plutil -replace APIKey -string 'SCHLÜSSEL' PodcastIndexCredentials.plist
plutil -replace APISecret -string 'GEHEIMNIS' PodcastIndexCredentials.plist
git check-ignore -v PodcastIndexCredentials.plist   # muss die Regel aus .gitignore zeigen
```

Die einfachen Anführungszeichen sind wichtig, Geheimnisse enthalten Zeichen wie `$` oder `|`. Beim Bauen kommt der Ordner als `PodcastIndex/` ins App-Bundle. Ob der Zugang drin ist, zeigt `plutil -p PodcastAI.app/PodcastIndex/PodcastIndexCredentials.plist`.

Fehlt die Datei oder ist ein Feld leer, baut die App trotzdem. Sie sucht dann nur im Apple-Podcast-Verzeichnis und zeigt weder Angesagt noch Kategorien. Frische Worktrees haben die Datei nicht, sie muss dort bei Bedarf hineinkopiert werden. `scripts/upload-testflight.sh` warnt, wenn sie fehlt oder ein Feld leer ist.

Schlüssel und Geheimnis stehen danach lesbar im App-Bundle. Für einen Schlüssel mit Leserecht nimmt Podcast Index das in Kauf. Wird er missbraucht, sperrt der Betreiber ihn, und es braucht einen neuen.

Für UI-Tests gibt es `-catalog-fixtures`: Der Katalog antwortet dann in Debug-Builds aus festen Daten, ohne Netz und ohne Zugang.

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
  PodcastAIKnowledge     Relevanz, Suche für den Chat, Gegenpositionen
  PodcastAIPlayback      Hörplan, Freigaben, Player
  PodcastAISmartFeeds    Persönliche Themenfeeds, Shownotes, Cover
  PodcastAIExport        Markdown für Folgen, Antworten und Notizen
  PodcastAIPersistence   SwiftData mit iCloud-Abgleich

Apps/
  Shared/                AppModel, Dienste, gemeinsame Ansichten
  PodcastAI/             iOS: fünf Tabs, Mini-Player
  PodcastAIMac/          macOS: Seitenleiste, Menübefehle, MCP-Server

Config/PodcastIndex/     Zugang zum Podcast-Katalog, im Repository nur die Vorlage
UITests/                 UI-Tests für iOS
```

## Regeln im Code

1. **Nur Apple-Modelle.** Fehlt ein Modell, sagt die App das. Sie weicht nicht auf einen anderen Anbieter aus.
2. **Das Modell wählt nur aus.** Es antwortet mit Nummern aus einer vorgelegten Liste. Zeiten, Quellen und Rechte kommen aus dem Code. Was nicht passt, wird verworfen.
3. **Vorbereiten ja, abspielen nur auf Wunsch.** Jede Wiedergabe braucht eine Freigabe aus einer Handlung des Nutzers. Sie gilt kurz, für ein Gerät und genau einen Hörplan.
4. **Gespeichert oder gehört heißt nicht zugestimmt.**
