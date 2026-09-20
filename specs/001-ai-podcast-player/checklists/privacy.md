# Checkliste — privacy

Status: App-Implementierung und Gerätetests nicht durchgeführt. Alle Punkte bleiben als Freigabearbeit offen.

- [ ] Private Feed-Tokens tauchen nicht in Prompts, Logs, Exports oder Sync-Fachrecords auf.
- [ ] PCC und Personalisierung haben korrekte Capability-/Consentzustände.
- [ ] Profilereset blockiert alte Sync-Events.
- [ ] Promptinjektion kann keine Tools oder Playback autorisieren.
- [ ] Parser-/Netzwerk-/Archivgrenzen durch adversariale Fälle geprüft.
- [ ] Inhaltszugang und YouTube-Nutzung entsprechen tatsächlichen Fähigkeiten.
- [ ] Keine Drittanbieter-Modelle oder AnalyticsSDKs.



## Widerspruchs-Mixer / Breadcrumb
- [ ] Kein Nutzerstandpunkt allein aus gehoerten oder gespeicherten Quellen.
- [ ] Gegenposition fair, kontextgebunden und mit geprueften Originalzeiten.
- [ ] Keine politische Profilbildung, Wahlempfehlung oder politische Rangliste.
- [ ] Quellenzahl dedupliziert, verfuegbar und mit tatsächlichem Scope abgeglichen.
- [ ] Ende/Pause getrennt; keine Autoplay-Schleife oder erzwungene Abschlussantwort.
- [ ] Parken und Verwerfen bewahren Originalnotizen; Undo und Exportstatus korrekt.
- [ ] Graph ueber Liste/VoiceOver bedienbar, Watch-Entscheidung ohne Exportfiktion.
- [ ] Offline-Konflikte, Quellenentzug und externe Kopien nachvollziehbar behandelt.

## Zusatz 1.3
- [ ] Coverprompts minimiert, keine privaten Feed-URLs; keine politischen Haltungsprofile aus Hörverhalten; persönliche Feeds app-intern; Historien-/Profilreset mit Epoch propagiert.
