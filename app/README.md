# PodcastAI

AI-First Knowledge Podcast Player für **iOS und macOS**.

Ein klassischer Player beantwortet „Was möchte ich hören?“.
PodcastAI beantwortet zusätzlich **„Was davon sollte ich wissen?“** — und
spielt die Antwort als Originalaudio.

## Stand

Der Code ist vollständig geschrieben, aber **in dieser Umgebung nicht
kompiliert**: es gibt keinen Swift-Compiler (`download.swift.org` ist per
Netzwerkpolicy gesperrt, GitHub-Releases liegen ausserhalb des
Session-Scopes). Ein Xcode-Build auf einem Mac steht aus.

Was stattdessen belegt ist: die Kernalgorithmen sind Zeile für Zeile nach
Python portiert und gegen Brute-Force-Modelle geprüft.

```bash
app/verification/run_all.sh
```

| Referenzmodell | Prüfungen | Was es belegt |
|---|---|---|
| `intervalset_reference.py` | 210 003 | Intervall-Algebra gegen ein Millisekunden-Mengenmodell; Normalform, Idempotenz |
| `ledger_reference.py` | 140 005 | Gehört bleibt gehört, feedübergreifend; Zusammenführen kommutativ und idempotent |
| `focusplanner_reference.py` | 120 004 | Budget hält, keine Überlappung, keine Fundstelle verschwindet |
| `publisher_reference.py` | 74 391 | Persönliche Ausgaben ohne Wiederholung; zweiter Refresh erzeugt keine zweite Ausgabe |
| `assembler_reference.py` | 80 006 | Wiederaufnahme nach Abbruch ohne Dubletten und ohne Textverlust |
| `selection_reference.py` | 180 004 | Modellantworten: erfundene Verweise werden verworfen, nicht korrigiert |
| `export_reference.py` | 120 016 | Kein Token im Export, fremder Text zerlegt die Struktur nicht |
| `sourceresolver_reference.py` | 20 | Linkklassifikation gegen `fixtures/youtube/url-cases.json` aus dem Spec-Kit |
| `relevance_reference.py` | 80 005 | Nur bestätigte Interessen wirken; deterministische Rangfolge |
| `passage_reference.py` | 100 003 | Passagen schneiden an Sprechpausen, nie mitten im Satz |
| `redirectguard_reference.py` | 28 | Weiterleitungen ins eigene Netz werden abgelehnt |

Das belegt die **Logik**, nicht die Swift-Syntax.

Dazu läuft `swift_consistency.py` über alle Swift-Dateien und prüft, was
ohne Compiler tatsächlich schiefgeht: unausgeglichene Klammern, nicht
geschlossene `#if`-Blöcke, doppelt deklarierte Typen und Verweise auf Typen,
die es nirgends gibt. Sie hat beim Schreiben zwei echte Klammerfehler
gefunden.

Die Invarianten stehen zusätzlich als Swift-Testing-Tests unter
`Packages/PodcastAIKit/Tests/` — damit sie auf einem Mac gegen den echten
Code laufen und nicht nur gegen eine Portierung davon.

## Bauen

```bash
brew install xcodegen
cd app && xcodegen generate
open PodcastAI.xcodeproj
```

Schemata: `PodcastAI` (iOS/iPadOS) und `PodcastAIMac` (nativ, kein Catalyst).
Mindestversionen: iOS 26.0, macOS 26.0, Swift 6 mit strikter Nebenläufigkeit.

> Zur offenen Entscheidung D7 im Plan (26 gegen 27): der Code steht auf 26.0,
> weil das die Version ist, auf der die vorhandene BrainSpeak-Basis läuft.
> Ein Sprung auf 27.0 hebt die Mindesthardware an und ist eine
> Produktentscheidung — siehe `plan/03-risiken-und-entscheidungen.md`.

## Aufbau

```
Packages/PodcastAIKit/Sources/
  PodcastAICore          Domäne. Foundation only, keine Apple-Frameworks.
  PodcastAISources       RSS/Atom, Linkauflösung, YouTube-Erkennung.
  PodcastAIMedia         Dateien lesen, Formate wandeln, CMTime-Brücke.
  PodcastAITranscription SpeechAnalyzer mit Medienzeit.
  PodcastAIIntelligence  Apple-Modelle, belegsichere Auswahl.
  PodcastAIKnowledge     Aussagen, Index, Retrieval.
  PodcastAIPlayback      FocusPlanner, Freigaben, Player.
  PodcastAISmartFeeds    Persönliche Themenfeeds.
  PodcastAIExport        Markdown mit sicheren Quellenlinks.
  PodcastAIPersistence   SwiftData-Modelle, ModelActor.

Apps/
  Shared/                AppModel, Dienste, gemeinsame Oberflächen.
  PodcastAI/             iOS: vier Bereiche, durchgehender Mini-Player.
  PodcastAIMac/          macOS: Seitenleiste, Menübefehle, Einstellungen.
```

`PodcastAICore` hängt bewusst an nichts. Genau deshalb liess sich die
Kernlogik hier ohne Apple-SDK prüfen.

## Die vier Regeln, die jede Abkürzung überstimmen

1. **Nur Apple-Modelle.** Kontingentende, fehlende Hardware und Offline sind
   ehrliche Zustände, keine Erlaubnis für einen fremden Anbieter.
2. **Das Modell wählt Kennungen.** Zeiten, Rechte, Scope und Fassung löst
   Code auf. Ein Modell antwortet mit Nummern aus einer vorgelegten Liste;
   was nicht exakt zeigt, fällt weg und wird protokolliert.
3. **Automatisch vorbereiten, bewusst abspielen.** Eine Empfehlung allein
   startet niemals Ton. Freigaben entstehen nur aus einer Handlung eines
   Menschen, sind kurzlebig, gerätegebunden und an genau einen Plan gehasht.
4. **Gespeichert oder gehört heisst nicht zugestimmt.**

## Verhältnis zu BrainSpeak

BrainSpeak ist eine On-Device-Diktier-App, kein Podcast-Player — siehe
`plan/04-brainspeak-audit.md`. Übernommen ist die Sprach-, KI- und
Audioschicht (`TranscriptionEngine`, `AudioFileReader`, `BufferConverter`,
`FoundationModelsClient`, die Prompt-Härtung aus `FactCaptureMode`).

Der entscheidende Unterschied steht in einer Zeile:

```swift
// BrainSpeak                    // PodcastAI
attributeOptions: []             attributeOptions: [.audioTimeRange]
```

Ohne Medienzeit gibt es keinen Beleg, keinen Sprung zur Originalstelle und
keine persönliche Ausgabe.
