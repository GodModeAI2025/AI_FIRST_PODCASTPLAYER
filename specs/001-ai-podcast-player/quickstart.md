# Quickstart für die Umsetzung

## 1. Paket prüfen
Vom Paketroot `python3 scripts/validate_packet.py` und `python3 -m unittest discover -s tests` ausführen. Damit werden ausschließlich Dokumentstruktur, Datenverträge und synthetische Policy-Fixtures geprüft.

## 2. Vorhandenen BrainSpeak-Checkout verwenden
Nicht durch ein neues Playerprojekt ersetzen. `python3 scripts/inspect-overlay.py /absoluter/pfad/BrainSpeak` listet Zusammenführungskandidaten und Konflikte, schreibt jedoch nichts in den Checkout. Bestehende Agent-/Spec-Dateien erhalten. Das gesamte Paket kann zunächst in einem getrennten Reviewordner neben dem Checkout liegen.

## 3. Audit und Apple-Toolchain
`audit/brainspeak-baseline.md` und `audit/integration-map.md` anhand echten Codes ausfüllen. Auf einem Mac `bash scripts/probe-apple-sdk.sh` starten. Es werden SDK-/Compiler-Metadaten und kleine Framework-Probes gesammelt. Eine erfolgreiche Import-Probe ersetzt keine Implementierung oder Geräteeignungsprüfung. Konkretes PCC-Entitlement separat dokumentieren.

## 4. Dem Agenten einen klaren Auftrag geben
`AGENTS.md`, Constitution, spec, plan, tasks und `prompts/00_START_IMPLEMENTATION.md` lesen lassen. Bereits ausgefüllte Nutzeranforderungen nicht erneut durch generische Spec-Erzeugung überschreiben. Nach Phase 00 in testbaren Nutzerabläufen umsetzen. Keine GitHub-Schreibaktionen oder Account-/CloudKit-Provisionierung ohne neuen ausdrücklichen Auftrag.

## 5. Erster End-to-End-Nachweis
Einen bewusst ausgewählten, berechtigt nutzbaren RSS-Podcast importieren. Eine Folge unabhängig vom Anhören analysieren. Voll-/Teilabdeckung zeigen. Eine Frage mit echten Evidence-IDs beantworten. Einen daraus resolvten Abschnitt nach bewusstem Start hören. Erkenntnis mit Herkunft als Markdown exportieren.

## 6. Alle vier Oberflächen fertigstellen
iPad und Mac erhalten Mehrspalten-/Fensterabläufe; Watch ein eigenständiges fokussiertes Erlebnis. Alle vier sind Scope der vollständigen Version, keine pauschal vertagten Anhänge. Quelle/Player/Wissen/Interessen verwenden gemeinsame Fachmodelle, nicht identische Bildschirme.

## 7. Release nur mit Nachweisen
110 Tasks sind geplant, nicht erledigt. Für jedes FR gibt es einen Akzeptanzfall. Echte SDK-, Audio-, Hintergrund-, CloudKit-, Watch-, Privacy- und Evaluations-Berichte müssen die Checklisten schließen. Ohne PCC-Freigabe bleibt der PCC-Pfad gesperrt und entsprechend gekennzeichnet.

## Smart Podcast List 1.3
Zusatzprompt: `../../prompts/06_SMART_PODCAST_LIST.md`. Fixturebeispiel: `../../fixtures/smart-feed/personal-episode.json`. Zuerst Tests der globalen Intervallhistorie und unveränderlichen Manifeste, dann native Views/Audio, dann Cover-Sheet. Neue Apple-Geräteabnahmen bleiben offen.
