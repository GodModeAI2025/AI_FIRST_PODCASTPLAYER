# Plan: PodcastAI als reiner Player auf Apple Watch, Apple TV und im Auto

Stand: 01.10.2026. Auftrag des Product Owners: PodcastAI soll auf watchOS, tvOS und in CarPlay als Podcast-Player ohne jede KI erscheinen. iPhone, iPad und Mac bleiben unverändert.

## Was die Player können und was nicht

Erlaubt sind Abos, Folgenlisten, Wiedergabe, Warteschlange (Up Next), Fortsetzungsstelle, Schlaf-Timer, Tempo, Kapitel und Cover. Es gibt keine Transkripte, Fakten, Tags, Chat, Themen-Updates, kein Apple Intelligence und kein FoundationModels, keinen MCP-Zugang, keine Widgets mit KI-Inhalt und keine Teilen-Erweiterung.

Regel 1 gilt überall: Nichts spielt, bevor jemand es antippt, an der Fernbedienung wählt oder in CarPlay bzw. per Siri anfordert. Eine geladene Liste, ein geöffnetes Now-Playing und ein Start der App starten keinen Ton. Nach einer Folge läuft nur weiter, was der Nutzer selbst in Up Next gelegt hat.

## Bausteine und Bundle-IDs

| Ziel | Bundle-ID | Plattform | Inhalt |
|---|---|---|---|
| PodcastAI (bestehend) | `com.godmodeai.podcastai.mobile` | iOS, iPadOS | zusätzlich CarPlay-Szene (Code ist da, Berechtigung fehlt noch) |
| PodcastAIWatch | `com.godmodeai.podcastai.mobile.watchkitapp` | watchOS 27 | eingebettet in die iOS-App, läuft auch ohne iPhone |
| PodcastAITV | `com.godmodeai.podcastai.mobile` | tvOS 27 | eigene App, aber derselbe App-Store-Eintrag wie iPhone und Mac (Universal Purchase) |
| PodcastAIPlayerKit | (Paketprodukt) | iOS, macOS, watchOS, tvOS | Datenmodell, Bibliothek, Player, Warteschlange, Feed-Abruf |

## Was geteilt wird

Geprüft mit `swift build --target … --triple …` gegen die installierten SDKs watchOS 27.0 und tvOS 27.0 (beide Simulator-SDKs sind da).

| Paketziel | watchOS 27 | tvOS 27 | Grund |
|---|---|---|---|
| PodcastAICore | ja | ja | nur Foundation |
| PodcastAISources | ja | ja | Feed-Parser, OPML, nur Foundation und XMLParser |
| PodcastAIMedia | ja | ja | Download, Dateispeicher |
| PodcastAIPlayback | nein | nein | hängt auf dem Papier an PodcastAIKnowledge, braucht es im Code nicht; für den Player unnötig |
| PodcastAIKnowledge, PodcastAIIntelligence | nein | nein | FoundationModels: `Tool`, `contextSize`, `SystemLanguageModel` fehlen auf beiden |
| PodcastAIPersistence | nein | nein | zieht Knowledge und damit FoundationModels |
| PodcastAITranscription | nein | nein | Speech |

`Package.swift` führt `.watchOS("27.0")` und `.tvOS("27.0")` als Plattformen des Pakets. Gebaut wird dort nur, was das Produkt `PodcastAIPlayerKit` braucht: Core, Sources, Media und das neue Ziel `PodcastAIPlayerKit`. Ein Test im Paket stellt sicher, dass das neue Ziel weder KI-Module noch FoundationModels, Speech, Vision oder NaturalLanguage einbindet.

### Datenmodell

`PodcastAIPersistence` lässt sich auf Uhr und Fernseher nicht bauen, und die echten Modelle ziehen über ihre Beziehungen auch Transkripte und Segmente in jeden Container (geprüft: `Schema([StoredSource, StoredEpisode, StoredListeningState])` enthält danach auch `StoredMediaVersion`, `StoredTranscript` und `StoredSegment`). Das wäre ein Abgleich von Transkripten auf eine Uhr.

Darum liegt in `PodcastAIPlayerKit` ein schmaler Satz Modelle mit **denselben Entitätsnamen und denselben Eigenschaften** wie im Hauptschema, aber nur drei Entitäten und ohne die Beziehung zu den Fassungen: `StoredSource`, `StoredEpisode`, `StoredListeningState`. Das CloudKit-Schema ändert sich dadurch nicht, die Player lesen dieselben Datensätze im Container `iCloud.com.godmodeai.podcastai`. Ein Test vergleicht Namen, Typen und Standardwerte jeder Eigenschaft mit `LibraryStore.schema`, damit die beiden Fassungen nicht auseinanderlaufen.

Geschrieben wird nie ein fremder Datensatz:

- Quellen und Folgen schreiben die Player nur im lokalen Betrieb ohne iCloud. Mit Abgleich liest die Uhr sie nur. Frische Folgen aus dem Feed hält sie im Speicher (Überlagerung), damit kein zweiter Satz Folgen in iCloud entsteht.
- Die Fortsetzungsstelle schreibt jedes Gerät in seine eigene Zeile `<Fassung>#<Geräte-Kennung>` von `StoredListeningState`, wie `LibraryStore.record(_:)`. `MediaListeningState.merged(with:)` aus Core vereinigt die Zeilen beim Lesen. Alle Felder der Zeile werden mit gesetzt, damit ein iPhone nie eine Zeile mit fehlenden Feldern liest.

## Datenfluss

1. Start: Container öffnen, erst mit iCloud-Abgleich, bei Fehler lokal (wie `AppBootstrap.openStore()`). tvOS legt den Speicher unter Caches ab, weil nur dort geschrieben werden darf. Das System kann ihn löschen, iCloud ist dort die Wahrheit.
2. Bibliothek: `PlayerLibrary` liest Quellen (abonniert) und Folgen (nicht entfernt), entfernt Dubletten aus dem Abgleich und liefert Wertetypen aus Core (`Source`, `Episode`).
3. Aktualisieren: `FeedParser` aus PodcastAISources holt den Feed einer Quelle direkt. Nur `https`, Regeln aus `SafeHTTP`.
4. Abspielen: `PlaybackEngine` (AVPlayer, Now Playing, Fernbedienung, Schlaf-Timer, Tempo, Kapitel). Startet nur über `play(_:)`.
5. Fortsetzen: Beim Pausieren, Springen, Beenden und alle 30 Sekunden schreibt `PlayerLibrary` Stelle und gehörten Bereich in die eigene Zeile.
6. Warteschlange: lokal je Gerät in den Benutzereinstellungen (`playerUpNext`).

## Plattformen

**watchOS.** SwiftUI-App mit Abos, Folgen, Wiedergabe (Play/Pause, ±Sprung, Tempo, Schlaf-Timer, Kapitel, Up Next). Hintergrundton über `UIBackgroundModes: audio` und die Sitzung `longFormAudio`. Wiedergabe über Bluetooth-Kopfhörer, ohne die fragt das System nach einem Gerät. Downloads für offline hören über eine Hintergrund-URLSession.

**tvOS.** Tabs Abos, Neu, Warteschlange, Wiedergabe (`sidebarAdaptable`), Cover-Raster mit Fokus, Wiedergabe mit Siri Remote (Play/Pause, ±10 s/±30 s, Kapitel). Dunkles Erscheinungsbild.

**CarPlay.** Szene `CPTemplateApplicationSceneDelegate` in der iOS-App mit `CPTabBarTemplate` (Abos, Neu, Warteschlange), `CPListTemplate` für Folgen und `CPNowPlayingTemplate` mit Sprung, Tempo und Up Next. CarPlay nutzt das vorhandene `AppModel`-Wiedergabeobjekt der iOS-App. Es kommt keine KI-Funktion in die Oberfläche.

## Grenzen

- Up Next liegt heute in den Benutzereinstellungen und nicht im Schema. Ohne Schemaänderung gibt es keine Warteschlange über Geräte hinweg. Uhr und Fernseher führen eine eigene.
- Die Fortsetzungsstelle reist über iCloud. Die Kennung der Fassung folgt aus der Audioadresse (`Episode.streamMediaVersionID`), wie auf dem iPhone, auch für gestreamte Folgen. Ändert ein Podcast die Adresse einer Folge, beginnt sie auf allen Geräten neu.
- Downloads auf der Uhr laufen nur, solange die App offen ist. Für Hintergrund-Downloads bräuchte die Uhr eigene Hintergrundaufgaben, die es hier nicht gibt.
- Der Fernseher trägt seit 1.3 `aps-environment`: Apple nimmt eine tvOS-App mit CloudKit ohne diese Berechtigung nicht an. Die Uhr hat keine Push-Berechtigung. Dort läuft der iCloud-Abgleich beim Öffnen; ob das für Änderungen während der Nutzung reicht, zeigt sich erst auf einem Gerät. Wenn nicht, kommt `aps-environment` auch dort dazu.
- Der Player schreibt gehörte Bereiche wie die iPhone-App, aber ohne Wissen: „Ungehört“ in Themen-Updates auf dem iPhone berücksichtigt sie.
- Die Uhr holt höchstens alle 15 Minuten alle Feeds (höchstens 8 MB je Feed), einzelne Podcasts beim Öffnen. Der Fernseher lädt Feeds gleich, mit 64 MB je Feed.
- Podcasts hinzufügen geht nur auf iPhone, iPad und Mac. Die Player zeigen, was iCloud liefert.
- Auf der Uhr spielt Ton nur über Bluetooth-Kopfhörer oder einen anderen Audioweg, den das System anbietet. Das gilt für Streaming und für geladene Folgen gleich.
- Ob iCloud bei einem Teilschema auf Uhr und Fernseher wirklich nur die drei Entitäten abgleicht, lässt sich im Simulator nicht prüfen. Es braucht ein echtes Gerät mit iCloud-Konto.
- Der Player-Satz kennt `mediaVersions` nicht. Löscht ein Player-Gerät eine Folge, entstünden Waisen. Deshalb löscht er nie.

## Entitlements

- iOS (bestehend): unverändert. `PodcastAI.entitlements` bekommt **kein** `com.apple.developer.carplay-audio`.
- watchOS und tvOS: eigene Entitlements-Dateien mit iCloud-Container `iCloud.com.godmodeai.podcastai` und CloudKit. Keine App Group, keine Private Cloud Compute.
- CarPlay: `app/Apps/PodcastAI/PodcastAICarPlay.entitlements` (komplette Kopie plus `com.apple.developer.carplay-audio`) und `app/Apps/PodcastAI/InfoCarPlay.plist` (Kopie der Info.plist plus Szenenmanifest). Beide sind per Build-Einstellung `PODCASTAI_VARIANT` schaltbar. Standard ist leer, dann gelten `PodcastAI.entitlements` und `Info.plist` wie bisher. Ein Test hält die beiden Info-Dateien und die beiden Entitlements-Dateien synchron.

## Was Apple freigeben muss

1. CarPlay Audio: Antrag unter developer.apple.com/contact/carplay, App-Kategorie Audio, App `com.godmodeai.podcastai.mobile`. Apple prüft einzeln und meldet sich per E-Mail. Ohne Zusage lässt sich keine signierte Fassung mit CarPlay bauen. Im Simulator geht es auch ohne.
2. Neue App-IDs im Developer-Portal: `com.godmodeai.podcastai.mobile.watchkitapp` (iCloud mit Container `iCloud.com.godmodeai.podcastai`, Hintergrundmodi sind keine Berechtigung) und eine für den Fernseher (iCloud mit demselben Container; anfangs `com.godmodeai.podcastai.tv`, seit 18.10.2026 dieselbe ID wie die iPhone-App). Wichtig: Die Uhr steckt jetzt in der iOS-App. Der nächste Archiv-Lauf von `app/scripts/upload-testflight.sh` braucht deshalb die App-ID der Uhr samt Profil. Mit `-allowProvisioningUpdates` und automatischer Signierung legt Xcode sie an, wenn das Konto Rechte dazu hat. Sonst vorher von Hand anlegen, sonst scheitert auch das Archiv der iOS-App.
3. App Store Connect: für die Uhr kein eigener Eintrag, sie hängt an der iOS-App (watchOS-Plattform der App ergänzen). Für den Fernseher die Plattform „tvOS“ in der bestehenden App (seit 18.10.2026 so umgesetzt, ebenso macOS), mit Screenshots 1920x1080 und App-Symbol in Schichten. Datenschutzangaben wie bei der iOS-App, Hinweis, dass die Player keine KI nutzen.
4. Provisioning-Profile für die drei IDs, Automatic Signing mit Team `SP73Z8JWXM` erzeugt sie. Das Upload-Skript archiviert `PodcastAI` (iOS, mit der Uhr), `PodcastAIMac` und `PodcastAITV`. Der Fernseher wird unsigniert archiviert, weil im Team kein Gerät registriert ist. Ein unsigniertes Archiv trägt keine Berechtigungen, deshalb signiert das Skript es vor dem Export ad hoc mit der Berechtigungsdatei. Bis zum Build vom 18.10.2026 fehlte dieser Schritt, und der fertigen App fehlte iCloud.
5. CloudKit: der Container braucht nichts Neues. Das Production-Schema bleibt, wie es ist.

## Freischaltung von CarPlay, sobald Apple zusagt

1. Im Developer-Portal bei der App-ID `com.godmodeai.podcastai.mobile` die Fähigkeit „CarPlay Audio App“ eintragen, Profile neu laden.
2. In `app/project.yml` im Ziel `PodcastAI` die Einstellung `PODCASTAI_VARIANT: CarPlay` setzen.
3. `cd app && xcodegen generate`.
4. Bauen und archivieren wie gewohnt. Das Archiv trägt jetzt `PodcastAICarPlay.entitlements` und `InfoCarPlay.plist`.
5. Zuerst auf einem iPhone ohne verbundenes CarPlay starten und prüfen, dass das Hauptfenster wie gewohnt erscheint. `InfoCarPlay.plist` nennt nur die CarPlay-Rolle im Szenen-Eintrag; SwiftUI liefert die Fenster-Szene normalerweise selbst. Gebaut ist die Fassung, gestartet wurde sie bisher nie. Bleibt das Fenster leer, kommt in `InfoCarPlay.plist` ein Eintrag `UIWindowSceneSessionRoleApplication` dazu.
6. Im CarPlay-Simulator (Xcode, I/O, External Displays, CarPlay) prüfen: Abos, Neu, Warteschlange, Wiedergabe.
7. Rückweg: Einstellung entfernen und neu generieren.

Eine Nebenwirkung der Fassung für CarPlay: `UIApplicationSupportsMultipleScenes` steht dort auf `YES` (die CarPlay-Szene braucht es), damit erlaubt die iOS-App auf dem iPad auch mehrere Fenster. Zum Prüfen vor dem ersten Upload mit CarPlay lässt sich die Fassung auch für den Simulator bauen: `xcodebuild -scheme PodcastAI -destination 'generic/platform=iOS Simulator' PODCASTAI_VARIANT=CarPlay CODE_SIGNING_ALLOWED=NO build`.

## Reihenfolge der Umsetzung

1. Paket: Plattformen, Produkt `PodcastAIPlayerKit`, Tests.
2. watchOS-App.
3. tvOS-App.
4. CarPlay in der iOS-App.
5. Dokumentation, Review des eigenen Diffs.

## Entscheidung zu Regel 1 in CarPlay (1. Oktober 2026)

Manche Autos schicken beim Verbinden von selbst „Wiedergabe“. Die App nimmt ein solches Kommando von außen in den ersten zehn Sekunden nach dem Verbinden nicht an (`EpisodePlayer.ignoresRemotePlayUntil`). Ein Tipp auf eine Folge in CarPlay hebt die Sperre sofort auf, danach gelten Wiedergabe, Pause und Springen wie sonst. Ton im Auto beginnt also nur nach einem Tipp.

Ein Autoradio ohne CarPlay, ein Lautsprecher oder ein Kopfhörer kann beim Verbinden dasselbe tun. Seit dem 11. November 2026 gilt deshalb eine eigene Sperre für jedes neue Audiogerät, auf iPhone und iPad ebenso wie auf Uhr und Fernseher. Meldet die Audiositzung ein neues Gerät (`AVAudioSession.routeChangeNotification` mit dem Grund `newDeviceAvailable`), startet zehn Sekunden lang kein „Wiedergabe“ von außen (`playCommand`). Auf iPhone und iPad führt `EpisodePlayer` die Frist (`ignoresPlayCommandUntil`), auf Uhr und Fernseher `PlaybackEngine` (`holdRemotePlay`).

Diese Sperre ist enger als die von CarPlay. Der Wechsel zwischen Wiedergabe und Pause (`togglePlayPauseCommand`) und jeder Tipp in der App wirken sofort: Ein Druck am Kopfhörer gleich nach dem Verbinden soll gelten, und am Anschluss lässt sich ein Auto nicht von einem Kopfhörer unterscheiden. Die Sperre von CarPlay hält in ihren zehn Sekunden auch diesen Wechsel auf, solange die Folge nicht spielt. Ein Tipp auf eine Folge in CarPlay hebt beide Sperren auf (`EpisodePlayer.liftRemotePlayHold`), weil CarPlay beim Verbinden auch den Audioweg ändert. Auf Uhr und Fernseher hebt kein Tipp die Sperre auf, sie läuft nach zehn Sekunden ab.

Was sie nicht leistet: Schickt ein Gerät statt „Wiedergabe“ den Wechsel, setzt es die Folge fort. Kommt „Wiedergabe“ später als zehn Sekunden nach der Meldung, ebenfalls. Kam es kurz vor der Meldung, hält die App die Folge nicht nachträglich an. Und die Sperre greift nur, wenn die App läuft und die Meldung vor dem Kommando eintrifft. War die App angehalten oder beendet, als sich das Gerät verband, kann das Kommando zuerst ankommen. Was ein bestimmtes Radio schickt und in welcher Reihenfolge, zeigt nur ein echtes Gerät.
