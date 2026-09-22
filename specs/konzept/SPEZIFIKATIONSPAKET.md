# Start hier — BrainSpeak Podcasts / Apple 27

**Lieferumfang:** ausgefülltes Spec-Kit-Arbeitspaket, nicht nur ein Prompt und nicht die fertige App. Stand 20. September 2026. Mindestbetriebssystem auf iPhone, iPad, Watch und Mac: 27.0.

## Für den nächsten Coding-Lauf
Entpacke das Paket. Öffne den vorhandenen BrainSpeak-Checkout mit dem Coding-Agenten und gib ihm `prompts/00_START_IMPLEMENTATION.md` zusammen mit dem Paket als Arbeitsgrundlage. Der erste Schritt ist der Ist-Audit; es wird kein neues Ersatzprojekt vorausgesetzt.

Die lokale Zusammenführung ist in `scripts/inspect-overlay.py` zunächst nur als Dateiliste/Dry-Run vorgesehen. Existierende Dateien werden nicht automatisch ersetzt. Die ZIP enthält weder Zugangsdaten noch den nicht lesbaren BrainSpeak-Code.

## Bereits ausgearbeitet
`constitution.md` legt Grenzen fest. `spec.md` beschreibt Nutzerziele und Akzeptanz. `plan.md` beschreibt native Architektur. `tasks.md` enthält abhängige Arbeitspakete. `data-model.md`, `contracts/`, `research.md`, `quickstart.md` und Checklisten machen daraus einen implementierbaren Entwurf. `design/` und `archive/` bewahren Bilder, User Flows und ältere Daten; `fixtures/` liefert neue, klar synthetische Testdaten.

## Spec Kit verwenden
Das Format richtet sich nach dem aktuell recherchierten offiziellen GitHub Spec Kit. Dieses Paket installiert den CLI nicht und behauptet keine registrierten Slash Commands. [G01, G02]

Ein bereits eingerichteter Agent kann die vorhandenen Artefakte direkt analysieren und danach implementieren. Je nach Integration heißen die Skills `/speckit-analyze`, `/speckit-implement`, `/speckit-converge` oder mit Punkt statt Bindestrich. Nicht beide Schreibweisen als garantiert installiert behandeln.

Für eine frische offizielle Einrichtung in einem **separaten Arbeitsverzeichnis** dokumentiert Upstream:

```bash
uv tool install specify-cli
specify init brainspeak-work --integration copilot
```

Integration gemäß verwendeter Agent-Umgebung wählen. Keine erneute `specify`-Generierung über die bereits ausgefüllten Dateien erzwingen. Eigene, agentenunabhängige Start-/Analyse-/Implementierungs-/Converge-Prompts sind unter `prompts/` enthalten.

## Offline prüfen
```bash
python3 scripts/validate_packet.py
python3 -m unittest discover -s tests -p 'test_*.py'
```
Python dient hier ausschließlich der Prüfung des Dokumentpakets. Die zu bauende App bleibt rein nativ Swift.

## Apple-spezifisch prüfen
```bash
bash scripts/probe-apple-sdk.sh
```
Nur auf macOS mit ausgewähltem Xcode 27 sinnvoll. Das Skript sammelt Toolchain-/SDK-Versionen und typecheckt kleine API-Probes. Es baut keine App, installiert nichts und erteilt kein PCC-Entitlement. Fehler und nicht verfügbare Symbole bleiben sichtbar.

## Zentrale offene Nachweise
BrainSpeak-Codeaudit; zugewiesenes PCC-Entitlement des konkreten Accounts; echte Apple-27-Gerätetests für Inferenz, Hintergrund, Audio, Watch und CloudKit. Diese Nachweise sind bereits Aufgaben, keine verdeckten Annahmen.



## Ergänzungen aus deinem Feedback
Ein normaler YouTube-Link genügt: automatische Feed-Erkennung, Abo oder Einzelimport, danach rückwirkende Auswahl. Details: `specs/001-ai-podcast-player/youtube-discovery-backfill.md`. Highlights, SRT/VTT/TXT/JSON, Suche über ungehörte analysierte Folgen, Smart Skip und nativer macOS-MCP-Zugang sind ebenfalls aufgenommen. Referenzumfang jetzt: 144 Anforderungen, 20 Nutzerabläufe und 266 Umsetzungsschritte. Die ergänzten Schritte hängen vor der finalen Konvergenz/Releaseprüfung.

## Sonar: Gegenpositionen und Wissenspfade
Die letzten Erweiterungen sind eingearbeitet: Widerspruchs-Mixer (US15) und Breadcrumb-Trail (US16). Details in `contradiction-mixer.md` und `breadcrumb-trail.md` im Spec-Ordner. Der komplette Beispiel-Graph liegt unter `fixtures/export/trail/`. Sonar ist Arbeitsname, BrainSpeak bleibt Hauptbasis.

## Erweiterung 1.3 zuerst beachten
Lies `ERWEITERUNG_SMART_PODCAST_LIST.md` und anschließend `prompts/06_SMART_PODCAST_LIST.md`. Die neue Gesamtspezifikation integriert FR-121–144 / US17–20 / T219–266. Automatisches natives Layoutcover und nutzergeführter Image-Playground-Dialog sind verschiedene Pfade; keine ImageCreator-Implementierung einbauen.
