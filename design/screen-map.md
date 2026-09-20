# Screen map und Zuordnung zum Referenzbild

Das Original enthält zehn iPhone-Konzeptscreens. Nur diese Screens sind tatsächlich gerendert. iPad-/Mac-/Watch-Layouts sind in diesem Paket präzise beschrieben, aber **nicht** als bereits erstellte oder getestete Bildschirmfotos bezeichnet.

| Referenz | Inhalt | Aktuelle Spezifikation |
|---|---|---|
| 01 | Für dich | persönliche Relevanz, neutrale Zusammenfassung, CoverageBadge |
| 02 | Quelle hinzufügen | capabilities, Abo/Analyse/Offline unabhängig |
| 03 | KI-Zusammenfassung | Verstehen, Claim vs. eigene Notiz, belegte Aussagen |
| 04 | Kapitel | Original-/AI-Herkunft, revisionsgebundene Originalzeit |
| 05 | Player | zentraler Coordinator, Audio-/Fokusmodus, Rücksprung |
| 06 | Chat mit Folge | Scope, Evidence, explizite Wiedergabeaktion |
| 07 | Mehrere Folgen | analysierter Scope, Vergleich, Quellenabdeckung |
| 08 | AI-Playlist | heutiger Fokusplan: Budget, Kontext, bewusste Startfreigabe |
| 09 | Wissen/Export | Exportvorschau, safe links, Markdown |
| 10 | Interessen | opt-in, explizit vs. vermutet, ResetEpoch |

Zusätzliche erforderliche Zustände: Empty, metadataOnly, processing, partial, ready, missingLanguageAsset, offline, pccQuota, pccIneligible, staleMedia, sourceRestricted, interrupted, syncConflict, exportFailure und watchPackIncomplete. Nicht jeder Zustand bekommt einen separaten Bildschirm; häufig ist es ein zugänglicher Zustand derselben View.

Die Bildtexte über reale Personen/Podcasts sind Illustrationen. Weder Statements noch Dauer, Episode-ID, Datum oder Zeitcode daraus werden in die Demo-Daten übernommen.



## Änderungen nach den Mockups
S02: Ein YouTube-Link genügt; automatische Feedauflösung, explizites Kanalabo und rückwirkende Analyse gemäß `youtube-import-and-archive.md`. S09: Highlights sowie SRT/VTT/TXT/JSON-Export ergänzen Markdown. Suche umfasst auch ungehörte analysierte Folgen. Auf Mac kommt ein eigener opt-in Agentenzugriff in Einstellungen hinzu. Es wurden dafür keine neuen Screenshots behauptet.



## Nachtraegliche Funktionszuordnung
Screen 03 „Verstehen“ und 10 „Interessen“ erhalten den optionalen Einstieg Andere Perspektive (US15). Screen 08 „Fokus“ erhaelt den dreiteiligen Sessionabschluss (US16). Screen 09 „Wissen/Export“ erhaelt Wissensgraph, offene Folgefragen und Parkstatus. Neue exakte Screens sind noch nicht gezeichnet; der verbindliche Wireflow steht in `breadcrumb-and-counterpoint.md`.

## Screens SF01–SF06 (1.3)
[smart-podcast-list.md](smart-podcast-list.md) ergänzt persönliche Feedkarten, Themenfeed, persönliche Folge, Doppelzeit-Player, Originalfolgenmodus und Coverdialog. Vorhandene PNG-Screens bleiben unverändert; neue Screens sind textuell spezifiziert.
