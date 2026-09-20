# Widerspruchs-Mixer — Gegenpositionen hören, selbst urteilen

## Ziel
Nicht „Sonar kennt alle deine Meinungen“, sondern: **Sonar kann bestätigte Thesen und gespeicherte Quellen auseinanderhalten und passende Gegenpositionen zugänglich machen.** Der Modus erweitert den Blick, ohne zu bestimmen, was jemand glauben soll. Referenzanforderungen FR-091–FR-102, Nutzerablauf US15.

## Begriffsmodell
`Interest` bedeutet Themeninteresse. `SourceClaim` ist die einem Sprecher zugeschriebene Aussage. `Stance` ist eine These mit Status `proposed`, `confirmed`, `rejected` oder `withdrawn`; nur `confirmed` und Herkunft `explicitUser` darf als Nutzerposition bezeichnet werden. `CounterpointRelation` beschreibt den Vergleich einer Ausgangsthese mit einer Quellenposition. Eine Notiz „interessant“ oder ein Highlight erzeugt keine Zustimmung.

Sensible und insbesondere politische Überzeugungen werden nicht aus Konsumdaten erschlossen. Bei politischen Themen bietet die App auf ausdrückliche Sachfrage einen neutralen quellenbasierten Vergleich konkreter Aussagen, Zeiträume und Bedingungen an, ohne individuelles Überzeugungsziel, Wahl-/Parteipräferenzprofil, Empfehlung oder Rangliste. Dieses Verhalten gilt auch für generierte Zusammenfassungen und Ausgabedateien.

## Einstieg und UI-Ton
Einstieg über „Andere Perspektive“ an einem Thema, einer Frage, einer bestätigten These oder einer Erkenntnis. Automatische Vorschläge sind gesondert opt-in. Eine mögliche, bewusst neutrale Formulierung:

> Du hast drei Folgen zu Local-first gespeichert. Möchtest du eine andere Sicht auf den Betriebsaufwand hören? Ich habe eine belegte Gegenposition im analysierten Bestand gefunden.

Nach expliziter Bestätigung einer eigenen These:

> Deine These: „Für mein Projekt ist Local-first die passendere Wahl.“ Ein anderer Beitrag betont den geringeren Betreuungsaufwand verwalteter Dienste. Beide sprechen unter unterschiedlichen Voraussetzungen. Gegenposition mit Kontext hören?

„Gegengift“, „du liegst falsch“, garantierte Meinungsänderung und Aufregungsscores sind keine automatischen UI-Labels. Aussagen im Beispiel sind Produkt-Fixtures, keine Behauptungen über reale Podcasts oder den Nutzer.

## Verarbeitung
1. Nutzerthese oder neutrale Frage auswählen; Kontext, Zeitpunkt und Bedingungen erhalten.
2. Nur im freigegebenen, analysierten Bestand suchen. Zusätzliche Quellen sind ein eigener bestätigter Import, kein heimliches Web-Crawling.
3. Kandidaten aus finalisierten Transkriptsegmenten mit Evidence-IDs hydrieren.
4. Relation prüfen: `contradicts`, `qualifies`, `differentAssumptions`, `complements`, `notComparable`. Direktes Widersprechen erfordert dieselbe Aussagefrage und vergleichbare Bedingungen; eine Einschränkung ist kein Gegenbeweis.
5. Negationen, Gegenrede, Zitat-in-Zitat und anschließende Korrekturen in den Kontext aufnehmen. Der Vortragende kann eine Position zitieren, ohne sie selbst zu vertreten.
6. Gleiche Ursprungsaufnahme auf mehreren Plattformen deduplizieren. Mehrere URLs belegen nicht mehrere unabhängige Quellen. Unbekannte Herausgeberbeziehungen als unbekannt lassen.
7. Kurzen fairen Einordnungstext und vollständigen Originalhörplan bilden. Bei Lücken weniger Material statt erfundener Gegensätze.
8. UserGate/PlaybackGrant prüfen, anschließend begrenzt abspielen. Nach Ende übernimmt der Breadcrumb-Trail.

Der deterministische Planvalidator prüft Identität, Grenzen, Scope und Freigaben. Ein zweiter Modelllauf kann Argumentqualität verbessern, ersetzt aber keine dieser Prüfungen. Modellbehauptung „valide“ ist kein Validierungsergebnis.

## Zeitbudget
„6 Minuten“ ist ein Budget aktiver Hörzeit einschließlich hörbarer Übergänge und bei gewählter Geschwindigkeit. Der Plan zeigt Originalzeit und tatsächliche Hördauer getrennt. Die Folge wird nicht physisch neu geschnitten; vorliegende Originalabschnitte werden referenziert. Optional gesprochenes App-Intro nutzt eine normale Systemstimme und zählt zum Budget; niemals Sprecherklon. Bei Konflikt gewinnt zusammenhängender Kontext vor maximaler Clipanzahl.

## Korrektur, Privatsphäre und Löschung
„Das ist nicht meine Meinung“, „Hier fehlt Kontext“, „Nicht dieselbe Frage“ und „Andere Perspektive war hilfreich“ sind getrennte Aktionen. Keine davon verändert still die Nutzerthese. Standpunktänderung erzeugt eine Revision und invalidiert vorbereitete Pläne. Modus abschalten verhindert neue Jobs. Persönliche Standpunkte bleiben standardmäßig außerhalb von MCP-, Spotlight- und Exportfreigaben.

Bereits gestartete Pläne werden bei Widerruf nicht unbemerkt ersetzt; Stop bleibt sofort verfügbar und automatische Fortsetzung wird beendet. Hintergrundjob, der nach Widerruf fertig wird, darf seine alte Zustimmung nicht wiederbeleben.

## Fehler- und Qualitätsfälle
Keine Gegenposition → `noEvidence`. Nur thematische Ähnlichkeit → kein Gegenargument. Schlechte ASR an Negation → Beleg sperren oder unsicheren Text zeigen, keine präzise Behauptung. Politischer Inhalt → neutraler expliziter Vergleichspfad, kein individualisierter Mixer. Geänderte Medienfassung → Zeitmarke veraltet. YouTube-only ohne Audio-/Textzugang → sichtbares Originalvideo, kein Audio-Mix-Versprechen.

Für die Umsetzung sind qualitativ annotierte Testfälle mit echten erlaubten Audios zusätzlich zu den mitgelieferten synthetischen Fixtures erforderlich. Ziele sind faire Zuordnung und Kontexttreue, nicht die Übernahme einer bestimmten Position.
