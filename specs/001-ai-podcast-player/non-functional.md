# Nichtfunktionale Anforderungen und Release-Ziele

Zahlen sind initiale Akzeptanzziele. Sie müssen auf tatsächlich benannten Geräten/OS-Builds gemessen werden; dieses Paket enthält keine behaupteten App-Messungen.

| ID | Anforderung | Nachweis |
|---|---|---|
| NFR-01 | 27.0 als Minimum auf allen vier Targets, kein Legacy-OS-Codepfad als Produktbasis | Buildsettings und CI |
| NFR-02 | UI-Arbeit MainActor, schwere Analyse außerhalb; kein synchrones Datei-/Netzwerk-I/O beim Zeichnen | Instruments + Codeaudit |
| NFR-03 | 10.000 Episoden und 100.000 Segmente als initiales Skalierungsfixture, paginiert | Speicher-/Suchbenchmark |
| NFR-04 | Lokale gefilterte Bibliotheksabfrage p95 unter 300 ms auf freigegebener Referenzhardware | reproduzierbarer Benchmark |
| NFR-05 | Lokaler warmer Beleg-Seek p95 maximal 1 s; Ausrichtung gegenüber Goldtranskript separat messen | Gerätemessung, kein Netzwerkversprechen |
| NFR-06 | Kein kompletter Mehrstunden-Audiopuffer in RAM; Peak-Ziel für iPhone-Analyse unter 350 MB über Baseline | Instruments, chunk tests |
| NFR-07 | Ein Langform-ASR-Job pro Mobilgerät initial; Parallelität nur nach Benchmarks erhöhen | Scheduler-/Thermaltest |
| NFR-08 | UI zeigt Fortschritt oder Wartegrund binnen 500 ms nach Nutzeraktion, keine erfundene ETA | UI-Test |
| NFR-09 | Stop/Skip hat Vorrang vor Prefetch, Modellantwort und Autoqueue | Race-/Faulttests |
| NFR-10 | Checkpoints mindestens nach jedem finalen Segmentbatch und jedem Pipelineabschluss | Abbruchtests |
| NFR-11 | Kein Tonstart aus Sync, Appstart, Notification oder fremdem Text | 100 % Policytestkorpus |
| NFR-12 | Keine Credentialleaks in Logs/Markdown/Prompt; Quellenlinks allowlist-basiert | Leaktests inkl. Path-Tokens |
| NFR-13 | Jeder Parser besitzt Bytes-/Depth-/Time-/Redirect-Limits und Abbruchmöglichkeit | Fuzz-/Boundarytests |
| NFR-14 | Alle Hauptaktionen barrierefrei, Zeitcodes als verständliche gesprochene Bereiche | VoiceOver auf vier Plattformen |
| NFR-15 | Größte Dynamic-Type-Kategorien ohne verdeckte zentrale Aktionen | UI-Matrix |
| NFR-16 | Reduce Motion/Transparency/Contrast respektieren; Bedeutung nie nur Farbe | Accessibility Review |
| NFR-17 | Ohne iCloud bleiben lokale Medien/Wissen nutzbar; Sync aktiviert keine PCC-Freigabe | Offline-/Consenttests |
| NFR-18 | Index komplett rekonstruierbar aus persistentem Wissen, keine geheimen Regeln nur im LLM-Verlauf | Rebuildtest |
| NFR-19 | Ein Export ist UTF-8, atomar geschrieben, in fremdem Markdownreader verständlich | Snapshot + Datei-/Escape-Tests |
| NFR-20 | Watch zeigt nur lokal bestätigten Packstatus, keine falsche Offline-Zusage | unvollständige Transfers |
| NFR-21 | Swift-6-Concurrency-Warnungen im Produktcode nicht mit pauschalem unchecked Sendable überdecken | CI/Review |
| NFR-22 | Keine Third-party Runtime, Model API oder Analytics ohne geänderte Constitution | Dependency-/Netzwerkaudit |
| NFR-23 | Prompts, Modell-/OS-/Indexversion und Evaluationsdatensatz gemeinsam versionieren | CI-Artefakte |
| NFR-24 | Alle failed/blocked/not-run Ergebnisse sichtbar; kein „grün“ durch Überspringen kritischer Gates | Freigabecheckliste |

## Datenhaltungs-Defaults

Entwurfsdefaults: Metadaten bis Nutzerlöschung; fertiges Wissen bis Nutzerlöschung; temporäre Analyseaudiodaten nach erfolgreicher Verarbeitung und kurzer Recoveryfrist von 24 Stunden entfernen, sofern nicht im Player/Watch-Pack referenziert; heruntergeladene Medien gemäß Nutzerwahl; lokale technische Diagnostik sieben Tage; Lernsignale 90 Tage, bestätigte Interessen unabhängig davon. Der Nutzer kann Limits ändern; private Quellbedingungen können strengere Aufbewahrung erfordern. Löschung von Profil und Lernhistorie setzt eine neue ResetEpoch.

## Fehlerbudget

Keine tolerierte Rate für unautorisierten Start, Cross-scope-Leak, erfundene Quellen-IDs oder Tokenexport. Für semantische Qualität gelten kuratierte Evals plus Human Review, nicht perfekte Sicherheit durch Prozentscore. Ein nicht ausreichend gesicherter Beleg bleibt nicht abspielbar.

## Smart Feed Qualitätsgates (1.3)
Keine Verzögerung von Play durch Covergenerierung. Neues Feedmaterial startet nie Ton. Komposition ist wiederaufnehmbar und idempotent; veröffentlichte Manifeste bleiben stabil. Umfangs-/Vollständigkeitsangaben stimmen auch bei seitenweisen Kandidaten, offline Geräten und fehlenden Quellen. VoiceOver unterscheidet persönliche Zeit von Originalzeit und automatische Layoutcover von bestätigten KI-Bildern. Übergänge lokaler Files und Remote-Streams werden getrennt auf realen Geräten gemessen; kein behaupteter Gapless-Nachweis aus Pakettests.
