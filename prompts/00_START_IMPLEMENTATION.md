# Direktauftrag an den Coding-Agenten
Du arbeitest am bestehenden BrainSpeak-Checkout. Dieses Spec-Kit-Paket ist die verbindliche Grundlage für einen AI-first Wissensplayer auf iOS/iPadOS/watchOS/macOS 27. Lies START_HERE, AGENTS, Constitution und alle Featureartefakte einschließlich youtube-discovery-backfill, knowledge-workflow, mcp-agent-access und focus-playback.

Arbeite lokal. Kein Push, keine Releases, keine Account-/CloudKit-/PCC-Provisionierung. Ersetze BrainSpeak nicht durch ein Greenfield-Projekt oder einen YourPods-Fork. Prüfe zuerst echten Code und installierte Xcode-27-SDKs. Dokumentiere tatsächliche Integrationspfade und Quellversionen. Fehlende APIs/Accounts als blockiert benennen, niemals erfinden. Keine Drittanbieter-LLMs/ASR/Runtime einführen.

Das Ziel ist der vollständige Flow: YouTube-/RSS-Link erkennen → Kanalfeed automatisch ermitteln → Einzelimport oder Abo anbieten → neue und/oder ältere verfügbare Folgen analysieren → interessenbezogenes Wissen vor dem Anhören → Chat mit Quellbelegen → validierte Originalsequenzen bewusst starten/automatisch in aktiver Fokus-Sitzung fortsetzen → Highlights/Suche/Markdown und Transkriptexport. Native Mac-MCP-Schnittstelle optional und explizit freigegeben. Alle vier Plattformen gehören zum Scope.

Prüfe das Paket, dann implementiere die Tasks in Abhängigkeitsreihenfolge. T109/T110 dürfen erst nach Ergänzungs-Tasks fertig werden. Bestehende ausgefüllte Spezifikationen nicht generisch neu erzeugen. FR-/AC-IDs in Tests und Änderungen referenzieren. Teste deterministische Domainregeln vor Modelladaptern. Apple Evaluations/echte Geräte für probabilistische Qualität und SDK-Gates.

Am Ende jeder abgeschlossenen vertikalen Scheibe: geänderte Dateien, erfüllte IDs, tatsächlich ausgeführte Tests, blockierte Gates und nächste abhängige Aufgabe dokumentieren. Kein Häkchen allein wegen Codeerzeugung. Sicherheits-, Scope- und Timingregeln nicht durch LLM-Ermessen ersetzen.


Beruecksichtige zusaetzlich US15/US16, FR-091–FR-120 sowie `prompts/05_MIXER_BREADCRUMB.md`. Sonar ist ein Produktarbeitsname, keine neue technische Codebasis. Die neu erzeugten Verifikationsberichte belegen nur das Paket, nicht einen Apple-App-Build.

## Zusatz 1.3
Vor Planung zusätzlich `prompts/06_SMART_PODCAST_LIST.md` lesen. T219–T266 sind vor den Release-Gates zu integrieren. Bestehende Basisfunktionalität und Bilder erhalten; neue Themenfeeds sind kein Ersatzprojekt.
