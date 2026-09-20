# Validierung — Version 1.3
Stand 20. September 2026. Diese Ergebnisse betreffen das Spezifikationspaket, nicht eine fertige Apple-App.

| Prüfung | Ergebnis | Nachweis |
|---|---|---|
| FR/US/AC/Task-Verknüpfung, DAG und Release-Gates | bestanden; 144 Anforderungen, 20 Stories, 144 geplante Abnahmen, 266 offene Tasks | packet-validation.json |
| JSON-Verträge und synthetische Daten | 41 Fixtures gegen 22 Schemas, strukturell und mit ergänzenden Invarianten geprüft | packet-validation.json |
| Paket-/Fixture-Regeln | 95 Tests bestanden | fixture-tests.txt |
| Swift-Domainverträge | vorhandene und neue Werttypen mit Linux Swift 6.2.1 im Swift-6-Modus typegeprüft | swift-domain-typecheck.txt |
| Bilder | alle 11 PNG-Dateien byteidentisch zum vorherigen ZIP | smart-feed-changes.md; historische Bildprüfung in design-assets.md |
| Lokale Markdown-Links | 30 Ziele ohne fehlende Datei; historische Archivtexte ausgenommen | document-links.json |
| Archiv/Integrität | vollständiges Inventar; nach Verpackung CRC und Einzeldateien geprüft | PACKAGE_MANIFEST.json und SHA256SUMS; Abschlussprüfung außerhalb des ZIP |

## Nicht geprüft / nicht implementiert
BrainSpeak-Codeaudit; Xcode-27-/Apple-SDK-App-Build; Geräte-UIs; Foundation-Models-/PCC-Laufzeit; Image-Playground-Systemdialog; echte Audioanalyse; native Audioübergänge; CloudKit/Watch-Laufzeit und App-Store-Freigabe. Die 144 Produkt-Akzeptanzfälle sind geplant, nicht ausgeführt.

Die neuen Python-Regeln sind Test-Orakel für die Spezifikation, keine alternative Appimplementierung. Die App bleibt Swift/Apple-nativ. Ein Linux-Typecheck beweist keine Xcode-27- oder Swift-6.4-Kompatibilität. Bildfixtures für Covermetadaten sind ausdrücklich fiktiv; es wurde kein Image-Playground-Cover erzeugt.

## Wiederholen
`python3 scripts/validate_packet.py` prüft Dateien, Schemas, Testdaten und Traceability. `python3 -m unittest discover -s tests -p 'test_*.py'` führt 95 Regeltests aus. Änderungen machen die Inventarhashes ungültig; diese anschließend bewusst neu erzeugen. Apple-Geräteprüfungen bleiben separate offene Aufgaben.
