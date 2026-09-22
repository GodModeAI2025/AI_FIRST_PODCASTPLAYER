# TestFlight

## Was hier nicht geht

**Dieser Build kann aus dieser Umgebung nicht nach TestFlight.** Das ist
keine Einstellungsfrage, sondern es fehlt jede einzelne Voraussetzung:

| Nötig | Vorhanden |
|---|---|
| macOS | nein, Linux |
| Xcode 27 | nein |
| Swift-Compiler | nein — `download.swift.org` ist per Netzwerkpolicy gesperrt |
| Signierzertifikat und Provisioning Profile | nein |
| Zugang zu App Store Connect | nein |
| Mitgliedschaft im Apple Developer Program | unbekannt |

Dazu kommt das Entscheidende: **der Code ist nie übersetzt worden.** 14 794
Zeilen Swift ohne einen einzigen Compilerlauf ergeben kein Archiv. Der erste
Mac-Build wird Fehler zeigen; das ist der Normalfall und kein Rückschlag.

`AGENTS.md` Punkt 2 untersagt einem Agenten ohnehin, selbstständig zu
veröffentlichen. Was hier steht, ist Vorbereitung — der Upload bleibt eine
bewusste Handlung eines Menschen.

## Was vorbereitet ist

| Stück | Datei | Warum es sonst fehlschlägt |
|---|---|---|
| App-Icon | `Apps/*/Assets.xcassets/AppIcon.appiconset/` | Ohne AppIcon scheitert die Archivvalidierung |
| Privacy-Manifest | `Apps/*/PrivacyInfo.xcprivacy` | Seit Mai 2024 Pflicht beim Upload |
| Exportoptionen | `release/ExportOptions-*.plist` | `xcodebuild -exportArchive` braucht sie |
| Mac-Kategorie | `Apps/PodcastAIMac/Info.plist` | `LSApplicationCategoryType` ist Pflicht |
| Verschlüsselungserklärung | beide `Info.plist` | `ITSAppUsesNonExemptEncryption` false, sonst fragt App Store Connect bei jedem Build nach |
| Hintergrundmodi | `Apps/PodcastAI/Info.plist` | `audio`, `processing` und die beiden BGTask-Kennungen |

Das Icon ist **ein Platzhalter.** Es entsteht aus
`Design/make_app_icon.py`, damit es nachvollziehbar und ersetzbar bleibt.
Ein echtes Icon belegt dieselben Dateinamen.

## Was noch entschieden werden muss

### Die Bundle-IDs gehören vermutlich nicht dir

`com.podcastai.app` und `com.podcastai.mac` sind Platzhalter aus dem
Produktnamen. Eine Bundle-ID muss zu einer Domain gehören, die dir gehört,
und sie muss im Developer-Portal registriert sein. Dasselbe gilt für die
App-Gruppe `group.com.podcastai.shared`.

Zu ändern in `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`), in beiden
`.entitlements` und in `Info.plist`, wo BGTask-Kennungen darauf aufbauen —
und in `BackgroundWork.swift`, wo `com.podcastai.refresh` und
`com.podcastai.analysis` stehen. **Die Kennungen in `Info.plist` und im
Swift-Code müssen übereinstimmen**, sonst wirft iOS beim Registrieren.

### Team-ID

`project.yml` und beide Exportoptionen lesen `$(PODCASTAI_TEAM_ID)`. Setze
sie als Umgebungsvariable oder trage sie direkt ein.

## Der Ablauf auf dem Mac

```bash
export PODCASTAI_TEAM_ID=ABCDE12345     # deine echte Team-ID

brew install xcodegen
cd app && xcodegen generate
```

**Schritt 1 — erst übersetzen, nicht archivieren.**

```bash
xcodebuild -project PodcastAI.xcodeproj -scheme PodcastAI \
           -destination 'generic/platform=iOS' build
```

Hier entsteht die Arbeit. Erst wenn das durchläuft, ist der Rest Mechanik.

**Schritt 2 — Tests gegen den echten Code.**

```bash
xcodebuild -project PodcastAI.xcodeproj -scheme PodcastAIMac test
```

Die Swift-Testing-Tests unter `Packages/PodcastAIKit/Tests/` prüfen
dieselben Invarianten wie die Referenzmodelle in `verification/`, aber am
Original statt an einer Portierung nach Python.

**Schritt 3 — archivieren und hochladen.**

```bash
xcodebuild -project PodcastAI.xcodeproj -scheme PodcastAI \
           -destination 'generic/platform=iOS' \
           -archivePath build/PodcastAI.xcarchive archive

xcodebuild -exportArchive \
           -archivePath build/PodcastAI.xcarchive \
           -exportOptionsPlist release/ExportOptions-iOS.plist \
           -exportPath build/export-ios
```

Für den Mac dasselbe mit `-scheme PodcastAIMac`,
`-destination 'generic/platform=macOS'` und
`release/ExportOptions-macOS.plist`.

`destination: upload` in den Exportoptionen lädt direkt hoch. Wer erst
prüfen will, setzt es auf `export` und benutzt danach:

```bash
xcrun altool --validate-app -f build/export-ios/PodcastAI.ipa \
             -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID"
```

**Schritt 4 — in App Store Connect.**

Der Build erscheint nach einigen Minuten unter *TestFlight*. Vor der
ersten externen Prüfung sind auszufüllen: Testhinweise, Kontakt für die
Beta-Prüfung und die Exportkonformität (sie ist durch
`ITSAppUsesNonExemptEncryption` bereits beantwortet).

Für **interne** Tester (bis 100 Personen im eigenen Team) entfällt die
Beta-Prüfung. Das ist der schnellste Weg zum ersten echten Gerätelauf —
und der ist überfällig, weil bisher nichts davon auf einem Gerät lief.

## Jede weitere Hochladung

`CURRENT_PROJECT_VERSION` in `project.yml` erhöhen. App Store Connect lehnt
eine bereits benutzte Buildnummer ab, und die Fehlermeldung nennt nicht
immer den Grund.
