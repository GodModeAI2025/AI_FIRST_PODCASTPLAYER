# Synthetische Smart-Feed-Vertragstests
Kein reales Audio, keine aktuellen Nachrichten und kein tatsächlich generiertes Cover. Themen-/Textbeispiele stammen aus dem vorhandenen synthetischen Korpus.

`feed.json` definiert einen persönlichen KI-Betriebs-Feed. `personal-episode.json` enthält zwei Originalsegmente mit insgesamt 110 Sekunden Originalmedienzeit, virtueller Zeitachse und belegten Shownotes. `ledger-before.json` ist vor der Wiedergabe leer. `ledger-after.json` enthält das Abspielen des ersten Segments und einen Seek über das zweite; der Seek zählt nicht als gehört.

`cover-native.json` beschreibt eine native Layoutvorlage, keine PNG-Datei. `cover-confirmed-contract-only.json` prüft den Datensatz eines bestätigten Apple-Bildes; Pfad und Nullhash sind ausdrücklich fiktiv. Daraus darf kein echtes Bild-/Persistenztest-Ergebnis abgeleitet werden. Die JSON-Schemas werden validiert; die zusätzliche Semantikprüfung verwendet den synthetischen Korpus.

Produkt-End-to-End mit iOS/Mobile, Google/KI, EnBW und Datenschutz bleibt in AC-144 geplant. Diese Intervalldaten beweisen kein Ranking-, Speech-, Foundation-Models- oder Image-Playground-Laufzeitverhalten.
