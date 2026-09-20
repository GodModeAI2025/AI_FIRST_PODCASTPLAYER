# Revalidierung tragender Technikannahmen

Geprueft am 19. September 2026 durch Abruf primaerer Hersteller-/Standarddokumentation. Aussagen bleiben zeitgebunden; die konkrete lokal ausgewaehlte Toolchain wird erst auf dem Mac geprueft.

| Bereich | Ergebnis | Quelle |
|---|---|---|
| Toolchain | Xcode 27 / Swift 6.4 fuer Release; Apple fuehrt 27.x-Betas separat | A01, A02 |
| PCC-Zugang | Small Business Program, Downloadschwelle und Accountentitlement sind Bedingungen, keine im Paket bereits erteilte Freigabe | A08 |
| Watch-KI | Foundation Models auf watchOS 27 benoetigt Netzmodell; kein lokales Watch-Modell und kein automatisches Borrowing des iPhones | A26 |
| Semantische Suche | SpotlightSearchTool durchsucht bereitgestellte App-Inhalte; Volltext muss aus eigenem Store hydriert werden | A10 |
| YouTube-Historie | playlistItems.list unterstuetzt Seiten-Cursor; bis 50 Eintraege pro Seite | Y05 |
| YouTube-Inhalte | Metadateneintrag ist keine Audio-/Caption-Berechtigung | Y02, Y03 |
| MCP | Version 2026-07-28 fuehrt request-scoped Metadata fuer stdio/HTTP; keine alte Sessionsemantik ungeprueft als aktuell deklarieren | M01, M02 |

Die per DocC verlinkten Markdownansichten liessen sich bei diesem zweiten Abruf teils nicht ueber das Webwerkzeug laden. Deshalb werden fuer diese Details die zuvor erfassten Nachweise/WWDC-Texte und die SDK-Probes getrennt ausgewiesen; es wird keine zweite Volltextpruefung behauptet. API-Signaturen, Buildnummern, Sprachassets, PCC-Kontingente und reale Performance bleiben offene lokale Gates.
