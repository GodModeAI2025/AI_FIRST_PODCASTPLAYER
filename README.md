# PodcastAI

Ein Podcast-Player für iPhone, iPad und Mac, der Folgen nicht nur abspielt, sondern versteht. Er sagt dir, welche Stellen für dich wichtig sind, und spielt genau diese Stellen im Originalton ab.

Ein normaler Player beantwortet die Frage „Was möchte ich hören?“. PodcastAI beantwortet zusätzlich „Was davon sollte ich wissen?“.

## Was die App kann

- **Quellen hinzufügen.** Podcast-Feed, einzelne Folge, YouTube-Kanal oder eine Webseite, auf der ein Feed verlinkt ist.
- **Folgen hören.** Ganze Folgen mit Cover, Kapiteln und Shownotes. Die App merkt sich, was du gehört hast, und zeigt es an Folge, Kapitel und Stelle.
- **Warteschlange.** Was als Nächstes gehört und was als Nächstes erschlossen wird, an einem Ort. Erschlossen wird eine Folge nach der anderen, auf dem iPhone auch im Hintergrund.
- **Folgen erschliessen.** Die App lädt eine Folge, transkribiert sie auf dem Gerät mit Zeitmarken und schneidet sie in Passagen an Sprechpausen. Die Sprache kommt aus dem Feed, nicht aus der Gerätesprache. Die jüngsten Folgen jeder Quelle bereitet sie von selbst vor, abschaltbar in den Einstellungen.
- **Für dich.** Du legst Interessen fest. Die App sucht in erschlossenen Folgen die passenden Stellen und erklärt, warum sie passen. Ein Tippen springt in der ganzen Folge an die Stelle.
- **Themen-Updates.** Aus ungehörten Stellen mehrerer Quellen entsteht eine persönliche Folge mit Kapiteln, Shownotes und Cover.
- **Fragen.** Ein Chat über deine erschlossenen Folgen. Jede Antwort besteht aus belegten Aussagen mit Sprung zur Originalstelle.
- **Gegenpositionen.** Zu einer These zeigt die App faire, belegte Gegenstimmen aus deinen Quellen.
- **Merken und exportieren.** Stellen merken, am Ende einer Hörsitzung vertiefen oder parken, alles als Markdown mit Quellenlinks exportieren.
- **Siri, Kurzbefehle und Spotlight.** Themen-Updates per Sprachbefehl starten, gemerkte Stellen in der Systemsuche finden.
- **Mac: MCP-Zugang.** Andere Programme dürfen nach deiner Freigabe lesend auf dein Wissen zugreifen, mit Ablaufzeit und Protokoll.

## Datenschutz

Alles läuft auf dem Gerät mit Apple-Modellen. Kein fremder KI-Anbieter, kein API-Schlüssel, kein Konto. Eine Empfehlung startet nie von sich aus Ton: abgespielt wird nur, was du bewusst antippst oder per Siri anforderst.

## Voraussetzungen

| Plattform | Mindestversion |
|---|---|
| iPhone und iPad | iOS 26 |
| Mac | macOS 26 |

Für die Transkription braucht das Gerät die Apple-Spracherkennung. Im iOS-Simulator gibt es sie nicht, dort meldet die App das beim Erschliessen. Relevanzauswahl, Chat und Gegenpositionen brauchen ein Gerät mit Apple Intelligence.

## Testen über TestFlight

Interne Builds für iOS und macOS laufen über TestFlight im Team Mobile Box. In App Store Connect heißen die Apps „PodcastAI“ und „PodcastAI Mac“, die Testgruppe heißt „Intern“ und verteilt neue Builds automatisch. Bundle-IDs: `com.godmodeai.podcastai.mobile` und `com.godmodeai.podcastai.mac`. Einen neuen Build hochladen:

```bash
app/scripts/upload-testflight.sh
```

## Selbst bauen

Siehe [app/README.md](app/README.md).

## Aufbau des Repositorys

| Ordner | Inhalt |
|---|---|
| `app/` | Die App: Xcode-Projekt, Swift-Paket, Tests |
| `specs/` | Fachliche Spezifikation, Anforderungen und Abnahmefälle |
| `design/` | Designsystem, Screens und Abläufe |
| `docs/adr/` | Architekturentscheidungen |
| `fixtures/`, `scripts/`, `tests/` | Beispieldaten und Prüfungen der Spezifikation |
| `plan/`, `prompts/`, `references/`, `archive/` | Planungsunterlagen, Recherche und Ursprungskonzept |

## Bekannte Grenzen

- Private Cloud Compute ist ausgeschaltet, weil dem Entwicklerkonto die Berechtigung fehlt. Alles läuft auf dem Gerätemodell.
- Bei YouTube liest die App Kanal und Katalog. Audio und Untertitel fremder Videos lädt sie nicht.
- Eine Apple Watch App gibt es noch nicht.
