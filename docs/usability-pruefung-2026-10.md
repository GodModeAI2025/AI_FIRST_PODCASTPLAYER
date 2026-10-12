# Usability-Prüfung Oktober 2026

Geprüft nach Nielsens zehn Heuristiken, Barrierefreiheit (VoiceOver, Dynamic Type, Kontrast, Trefferflächen, Reduzierte Bewegung) und den KI-Mustern (Beleg, Rückgängig, Hinweis auf Fehler, Leerzustände). Grundlage: Quelltext unter `app/Apps/Shared`, `PodcastAI`, `PodcastAIMac` sowie die Bildschirmfotos in `app/build/atlas-named`. Die Funde stammen aus dem Quelltext und den Bildern, nicht aus einem VoiceOver-Durchlauf am Gerät.

## Ampel

| Bereich | Stand |
|---|---|
| Rückmeldung und Bewegung | grün, Federn und Reduzierte Bewegung fast durchgängig |
| VoiceOver | grün, Symbolknöpfe beschriftet, Ansagen bei Ergebnissen, Regler mit Wert |
| Kontrast | gelb, Grün als Schrift zu blass (behoben) |
| Trefferflächen | gelb, kleine Knöpfe in Katalog und Fehlerleiste |
| KI-Muster | gelb, Belege und Leerzustand stark, kein Hinweis auf mögliche Fehler |
| Erhöhter Kontrast, Reduzierte Transparenz | gelb, im Code nirgends ausgewertet |

## Funde

### Hoch

Keine. Es fand sich nichts, was eine Gruppe am Ziel hindert.

### Mittel

1. **Grüne Schrift auf hellem Grund, etwa 2,2 : 1** (WCAG 1.4.3). `Shared/CatalogViews.swift:266`, `SubscriptionImport.swift:394`, `YouTubeTakeoutImport.swift:618`, dazu grüne Symbole und Labels in `CatalogViews.swift:296,723,726`, `LinkPreviewViews.swift:156,198`, `SubscriptionImport.swift:416`, `YouTubeTakeoutImport.swift:676`. **Umgesetzt:** neues Token `Design.Palette.confirmed` (`DesignSystem.swift`), im hellen Modus über 6 : 1.
2. **Bestätigungszeile und Wortlaut-Umschalter ignorierten Reduzierte Bewegung.** `ListeningViews.swift` (`ConfirmationBanner`: `.animation(.default)` plus Schiebeübergang; `FactWording`: `withAnimation { shown.toggle() }`). **Umgesetzt:** Feder aus `Design.Motion`, bei Reduzierter Bewegung nur Überblendung.
3. **Transkript scrollt auf iPhone und iPad mit Standardkurve und ohne Rücksicht auf Reduzierte Bewegung** (`ListeningViews.swift`, `onChange(of: currentStart)`). Auf dem Mac stand die Rücksicht schon da. **Umgesetzt:** gleiche Regel für alle Plattformen, Feder statt `.default`.
4. **Kleine Knöpfe unter 44 pt auf iPhone:** „Abonnieren“ (`CatalogViews.swift:287`), „Nur diese Folge“ (`LinkPreviewViews.swift:146`), „Transkript erstellen/Erneut versuchen“ und „Jetzt starten“ (`EpisodeViews.swift:1095,1111`), alle `.controlSize(.small)`. **Offen:** Ein Rahmen außen herum vergrößert die Trefferfläche eines Systemknopfs nicht zuverlässig, ein Umbau ändert die Optik der Zeilen. Braucht Sichtung im Simulator.
5. **Kein Hinweis, dass Antworten falsch sein können** (`ChatView.swift:724`, `ChatEmptyState`; `AnswerCard` ab Zeile 855). Belege, Modellangabe und Deckungshinweis sind stark, ein schlichter Satz fehlt. **Offen:** neuer sichtbarer Text und Produktentscheidung (Ton, Platz, Store-Texte).
6. **Erhöhter Kontrast und Reduzierte Transparenz werden nirgends ausgewertet** (keine Treffer für `colorSchemeContrast`, `accessibilityReduceTransparency`). Materialien und `glassEffect` passen sich vom System her an, eigene Flächen wie `.tint.opacity(0.1)` (`ChatView.swift:327,746`) und `Design.contentCard` (`.quaternary.opacity(0.35)`) nicht. **Offen:** nur am Gerät mit eingeschalteter Einstellung sinnvoll zu beurteilen.

### Niedrig

7. **TextField „Name“ im Themen-Update ohne Namen für VoiceOver** (`TopicUpdateViews.swift:1176`), gelesen wurde nur der Platzhalter. **Umgesetzt:** `.accessibilityLabel("Name")`, Text steht schon im String Catalog.
8. **Pressed-Animation auf dem Mac mit `.easeOut(0.08)`** (`MacPageParts.swift:138`). **Umgesetzt:** `Design.Motion.snappy`, unterbrechbar. Die Hover-Überblendungen (`.easeOut(0.12)`, `MacTagsPage.swift:146`, `MacPageParts.swift:137` u. a.) bleiben, weil sie keine Berührung sind und eine kurze Überblendung dort der Konvention entspricht.
9. **Fortschrittsbalken ohne Namen:** `SubscriptionImport.swift:253`, `YouTubeTakeoutImport.swift:414,441`, `Views.swift:380,427`. Der Text darunter nennt den Stand, VoiceOver liest den Prozentwert aber ohne Bezug. **Offen:** braucht eine neue Beschriftung im String Catalog, Wirkung gering.
10. **Keine Haptik** (`sensoryFeedback` kommt nicht vor). Sinnvoll wären Abonnieren, Antwort sichern, Moment merken. **Offen:** neues Verhalten, nicht verhaltensneutral.
11. **Bestätigungszeile ohne „Rückgängig“** (`ListeningViews.swift`, `ConfirmationBanner`, `allowsHitTesting(false)`). Löschen von Antworten und Folgen ist über Rückfragen geschützt, aber nicht umkehrbar. **Offen:** neue Funktion.
12. **Grauer Platzhalter im Chatfeld und `.secondary` auf Grau** wirken auf `atlas-04-chat.png` blass. Systemfarben, Kontrast nicht gemessen. **Offen:** am Gerät messen.

## Was schon gut ist

Sprungleiste und Regler im Player mit Wert und Aktion (`ListeningViews.swift:2235`), `tappableArea()` an 45 Stellen, Ansagen für Ergebnisse (`AccessibilityNotification` an 18 Stellen), Fehler mit Symbol und Text statt nur Farbe (`Design.Notice`), Leerzustand im Chat mit sechs Beispielfragen, Belege mit Zeitmarke und Abspielen nur auf Tipp (Regel 1), Wischaktionen mit Menü-Alternative, feste Schriftgrößen nur bei Covern.

## Geändert

- `app/Apps/Shared/DesignSystem.swift`: Token `Design.Palette.confirmed`.
- `app/Apps/Shared/CatalogViews.swift`, `LinkPreviewViews.swift`, `SubscriptionImport.swift`, `YouTubeTakeoutImport.swift`: Bestätigungsgrün durch das Token ersetzt.
- `app/Apps/Shared/ListeningViews.swift`: Reduzierte Bewegung in Bestätigungszeile, Wortlaut-Umschalter und Transkript-Scrollen.
- `app/Apps/Shared/TopicUpdateViews.swift`: Name für das Namensfeld.
- `app/Apps/Shared/MacPageParts.swift`: Feder statt `easeOut` beim Drücken.

Keine sichtbaren Texte geändert, daher keine Einträge im String Catalog.

## Prüfung

`swift test` im Paket: 1020 Tests, grün. Alle vier Schemata (PodcastAI, PodcastAIMac, PodcastAIWatch, PodcastAITV, Debug) bauen ohne Fehler. Nicht im Simulator angesehen und keine UI-Tests gelaufen; das neue Grün ist nur gerechnet (hell über 6 : 1, dunkel über 10 : 1), nicht gesehen.
