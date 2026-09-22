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

Was stattdessen belegt ist, in zwei getrennten Stufen — die Unterscheidung
ist wichtig, weil sie verschieden viel wert sind:

**Portierte Kernlogik.** Die Algorithmen sind nach Python übertragen und
gegen Brute-Force-Modelle geprüft, die dieselbe Frage unabhängig und
absichtlich dumm beantworten (Intervalle als Millisekunden-Mengen,
Auswahl durch Aufzählen aller Möglichkeiten). Wo die Portierung vom
Swift-Code abweicht, belegt sie nichts — das ist die Grenze dieser Stufe
und sie lässt sich ohne Compiler nicht schließen.

**Modellierte Eigenschaften.** Einige Modelle bilden nicht Zeile für Zeile
ab, sondern prüfen eine Eigenschaft, die der Code haben muss: dass eine
Größengrenze auch dann hält, wenn der Server über die Länge lügt; dass bei
Rückstau kein Block verloren geht; dass keine Prüfsumme, an der eine
Entscheidung hängt, auf FNV-1a steht. Zwei davon prüfen zusätzlich den
Swift-Quelltext direkt und schlagen an, wenn eine künftige Änderung die
Regel bricht.

```bash
app/verification/run_all.sh
```

| Referenzmodell | Prüfungen | Was es belegt |
|---|---|---|
| `intervalset_reference.py` | 210 003 | Intervall-Algebra gegen ein Millisekunden-Mengenmodell; Normalform, Idempotenz |
| `selection_reference.py` | 180 004 | Modellantworten: erfundene Verweise werden verworfen, nicht korrigiert |
| `suggester_reference.py` | 156 033 | Vermutete Interessen nur aus mehrfach Gehörtem; nie automatisch wirksam |
| `ledger_reference.py` | 140 005 | Gehört bleibt gehört, feedübergreifend; Zusammenführen kommutativ und idempotent |
| `export_reference.py` | 120 016 | Kein Token im Export, fremder Text zerlegt die Struktur nicht |
| `focusplanner_reference.py` | 120 004 | Budget hält, keine Überlappung, keine Fundstelle verschwindet |
| `passage_reference.py` | 100 003 | Passagen schneiden an Sprechpausen, nie mitten im Satz |
| `assembler_reference.py` | 80 006 | Wiederaufnahme nach Abbruch ohne Dubletten und ohne Textverlust |
| `relevance_reference.py` | 100 005 | Nur bestätigte Interessen wirken; Rangfolge auch bei vertauschter Eingabereihenfolge gleich |
| `publisher_reference.py` | 74 470 | Persönliche Ausgaben ohne Wiederholung; Budget und Zeitachse bei sechs Wiedergaberaten |
| `backpressure_reference.py` | 258 | Begrenzter Puffer ohne Verlust — mit Gegenbeweis: ohne Wiederholung gingen 174 von 200 Blöcken verloren |
| `transferlimit_reference.py` | 148 | Größengrenze hält, auch wenn der Server über die Länge lügt |
| `mediatime_reference.py` | 137 | Zeitrechnung sättigt statt abzustürzen; Randwerte erschöpfend |
| `networkdestination_reference.py` | 101 | Jede Schreibweise von localhost fällt durch, gegen `ipaddress`/`inet_aton` abgeglichen |
| `digestpolicy_reference.py` | 28 | Jede entscheidungstragende Prüfsumme auf SHA-256 — geprüft am Quelltext |
| `sourceresolver_reference.py` | 20 | Linkklassifikation gegen `fixtures/youtube/url-cases.json` aus dem Spec-Kit |
| `mcpserver_reference.py` | 49 | JSON-RPC-Fehlercodes, Form der `id`, kein Werkzeug ohne Freigabe, Obergrenze |
| `feeddiscovery_reference.py` | 28 | Feed-Verweis in 13 Seitenformen; Verweise ins eigene Netz werden nicht vorgeschlagen |

Das belegt die **Logik**, nicht die Swift-Syntax. Kein Referenzmodell
ersetzt einen Compiler, und keines ersetzt einen Lauf auf einem Gerät.

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
Mindestversionen: iOS 27.0, macOS 27.0, Sprachmodus Swift 6 mit strikter
Nebenläufigkeit.

> **D7 war keine offene Entscheidung.** Der Code stand auf 26.0 mit dem
> Hinweis, 27 sei noch zu klären. `config/toolchain-lock.json` trägt seit
> dem 19. September `"policy": "latest-apple-native-27-only"` mit 27.0 für
> alle vier Plattformen, und `AGENTS.md` Punkt 3 macht diese Politik
> verbindlich. Die 26.0 war schlicht eine Abweichung davon.
>
> Für den Code ändert das nichts: `SpeechAnalyzer`, `.glassEffect`,
> `.tabViewBottomAccessory` und `FoundationModels` gibt es ab 26, auf 27
> also erst recht. Was sich ändert, ist die Mindesthardware — und das ist
> genau die Entscheidung, die die Sperrdatei bereits getroffen hat.
>
> `swiftCompiler: "6.4"` und die Xcode-Buildnummer stehen dort auf
> `null` bzw. `locallyVerified: false`. Beides bleibt so: hier ist kein
> Apple-SDK, und geratene Buildnummern einzutragen verbietet die Datei
> ausdrücklich.

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
