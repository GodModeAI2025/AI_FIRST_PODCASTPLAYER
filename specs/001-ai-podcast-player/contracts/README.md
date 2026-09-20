# Datenverträge
JSON Schema Draft 2020-12 beschreibt die Serialisierungsform. Alle `schemas.example.invalid`-IDs sind lokale Kennungen, keine Netzwerkdienste. Referenzintegrität, Bereichsvergleich, Timing, Quellenrechte, Scope, aktive Hörzeit und Grants werden **zusätzlich** deterministisch geprüft; JSON Schema allein kann sie nicht nachweisen.

`DomainContracts.swift` ist ein originales Swift-Domainbeispiel ohne Apple-SDK-Adapter. Kein vollständiges App-Modul. `tool-contracts.md` und `mcp-tools.json` beschreiben fachliche Werkzeuge, nicht einen bereits laufenden MCP-Server. Vertragsfixtures sind synthetisch; die tatsächlichen Podcastbeispiele aus dem generierten Bild sind ausgeschlossen.

Paketprüfung: `scripts/validate_packet.py` und `tests/`. Der integrierte kleine Validator prüft ausschließlich den hier eingesetzten Schema-Subset und verweigert unbekannte Assertion-Keywords. Er ist keine allgemeine JSON-Schema-Bibliothek. Zusätzlich wurde, falls im Buildsystem verfügbar, gegen einen vollständigen Draft202012Validator geprüft; Status steht unter validation.


Die vier neuen Schemas `stance`, `counterpoint`, `knowledge-graph`, `session-closure` ergaenzen US15/US16. Sprachliche Relationen sind vorgeschlagene Interpretationen, keine formalen Wahrheitsbeweise. Bestaetigung, Quellenzahl, Graphreferenzen und Aktionstrennung werden zusaetzlich semantisch validiert.

## Version 1.3
Vier additive Smart-Feed-Verträge und SmartFeedContracts.swift. Sie erweitern die bestehenden Datenmodelle; konkrete SwiftData-/SDK-Integration bleibt geplant. Der synthetische Cover-Vertragstest enthält keine echte Bilddatei.
