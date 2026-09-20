# Security, Datenschutz und Inhaltsgrenzen

## Datenfluss
Medien kommen von bewusst gewählten Quellen. Temporäre Audiofiles und Sprachassets bleiben im App-verwalteten Dateibereich. Apple-Speech verarbeitet zulässige Dateien; der Wissensspeicher hält finale Segmente, Herkunft und minimierte Nutzersignale. PCC erhält nur nötige Evidence-Auszüge und Aufgabe nach Capability-/Consent-Prüfung. Optionaler CloudKit-Sync betrifft ausgewählte Fachrecords. Keine Drittanbieter-LLM- oder Analytics-SDKs.

## Nicht vertrauenswürdige Quellen
RSS, Atom, Shownotes, Kapitel, Transkripte, Modellantworten und importiertes Markdown sind Daten, keine Systeminstruktionen. Anweisungen darin dürfen weder Netzwerkziele bestimmen noch Profile, Player, Datenexport oder Löschung autorisieren. Retrieval und Modelltools bekommen eine kleine Allowlist mit zentralem PolicyGate. Modelle liefern IDs, keine auszuführenden URLs.

## Netzwerk und Parser
TLS und sichere URL-Schemata; Dateityp/Signatur, Größe, Content-Type, Redirectanzahl und tatsächlichen Zielhost prüfen. Private/Loopback/Link-local Ziele aus fremden Feeds standardmäßig blockieren; DNS-Rebinding und jeden Redirect neu prüfen. Bewusst vom Nutzer konfigurierte lokale Quellen brauchen einen getrennten expliziten Pfad, keine globale Ausnahme. XML ohne externe Entitäten; keine Skriptausführung aus Shownotes. Archive gegen Pfadtraversal, Symlinks und Dekompressionsbomben schützen.

## Geheimnisse
Keychain verwaltet lokale Secret-Referenzen. Private URLs können Tokens im Pfad, Host oder Query enthalten. Keine Reparatur allein durch Query-Stripping. Export/Sharing verwendet ausschließlich erlaubte öffentliche kanonische Links oder lesbare interne IDs. Signed Download-URLs sind Laufzeitgeheimnisse und können ihre erforderlichen Parameter im autorisierten Abruf behalten.

## Nutzerkontrolle
Personalisierung, optionale iCloud-Synchronisation und PCC-Datenverarbeitung sind unterscheidbare Entscheidungen. Profiländerungen lassen sich einsehen, korrigieren und löschen. Reset-Epoch verhindert Wiederaufbau aus alten Events. Hörverhalten erlaubt keine medizinischen, politischen oder psychologischen Sensitivprofile. Datenschutzinformation muss erläutern, dass App-eigene Evidenz nicht automatisch die Wahrheit einer Podcastbehauptung garantiert.

## Plattformschutz
App Sandbox auf macOS und passende Entitlements; security-scoped Dateizugriffe mit begrenzter Lebensdauer. Schutzklassen bei gesperrtem Gerät auf reale Hintergrund-/Audiovoraussetzungen abstimmen. Keine dauerhaft weitreichenden Dateiberechtigungen, keine versteckten Mikrofonaufnahmen. PrivacyInfo.xcprivacy mit tatsächlich verwendeten APIs/Daten erstellen, nicht eine generische falsche „keine Daten“-Erklärung kopieren.

## Logging und Modelltests
Nur redigierte Ereignistypen, Operation-/Fehlercodes und notwendige Messwerte. Keine Transkripte, private URLs, Toninhalte oder vollständigen Prompts in Telemetrie. Synthetische adversariale Fixtures testen Toolinjektion, Datenabfluss, unbekannte Evidence-IDs und surprise autoplay. Apple Evaluations ergänzt deterministische Regeln, ersetzt sie nicht. [A19, A20]



## Perspektiven-/Wissensgraph-Policy
Gehörtes ist keine Meinung. Keine politische Präferenzableitung aus Hörverlauf. Bestätigte private Standpunkte bleiben aus Standardexports, MCP und OS-Suche ausgeschlossen. Explizite politische Sachfragen werden neutral anhand konkreter Quellen beantwortet, ohne Überzeugungsziel, Rangliste oder Handlungs-/Wahlempfehlung.

Aufbewahrte Gegenposition bleibt Gegenposition. Parken ist kein Opt-in zu Monitoring, weiterer Analyse oder externer Weitergabe. Verwerfen ist kein Löschen des ursprünglichen Wissens. Quellenentzug entfernt nicht verwandte manuelle Notizen. Externe Kopien werden nicht als kontrollierbar behandelt. Generierte Mermaid-/Markdownlabels werden escaped, Knotentext darf nie Datei-/Netzwerk-/Playback-Autorisierung erzeugen.

## Smart Podcast Lists und Cover (1.3)
Interessen sind konfiguriert oder bestätigt. Sensible Arbeitgeber-/Projektdetails und private Feed-URLs fließen nicht ungefragt in Coverprompts. Shownotes und Bildvorschläge sind nicht vertrauenswürdige Modelldaten, niemals auszuführende Toolanweisungen. Externe Image-Playground-Provider sind ausgeschlossen. Bei politischen Themen keine Ableitung einer politischen Haltung aus Hörverhalten; neutraler thematischer Informationszugang.

Ein veröffentlichter persönlicher Feed ist standardmäßig app-intern. Markdown/Manifest-Export enthält bereinigte Quellreferenzen, keine öffentliche Audioveröffentlichung. Profil-/Historienlöschung propagiert Epochs, Ausgabenvorschläge und lokale Reservierungen. Exportierte Fremdkopien werden nicht als aus der Ferne gelöscht behauptet.
