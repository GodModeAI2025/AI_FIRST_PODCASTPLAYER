# BrainSpeak Podcasts — Constitution

**Version:** 1.2.0 · **Ratified:** 2026-09-19 · **Last amended:** 2026-09-19

## I. Wissen ist das Produkt
Die App MUSS Inhalte ohne vorheriges Anhören erschließen. Player, Wissen und Interesse bleiben getrennte Domänen. Gehört, ausgewertet, gelesen, als bekannt markiert und als wahr geprüft sind unterschiedliche Zustände. Der Erfolg ist nachvollziehbarer Wissensnutzen, nicht maximale Hörzeit.

## II. BrainSpeak bleibt die Basis
Vor Integration MUSS ein lesender Ist-Audit des vorhandenen BrainSpeak-Checkouts erfolgen. Vorhandene geeignete Audio-, Persistenz- und Apple-Intelligence-Bausteine werden angepasst, nicht verdeckt durch eine Neuentwicklung ersetzt. Neue Namen im Plan sind Ziel-Zuständigkeiten. YourPods ist nur funktionale Referenz. Kein Git-Push, kein Release, keine Cloudressource und keine Codeübernahme ohne eigene Autorisierung. [G03–G05]

## III. Apple-native, Generation 27 ausschließlich
Deploymentminimum: iOS 27.0, iPadOS 27.0, watchOS 27.0, macOS 27.0. Xcode 27 mit Swift 6.4 und Swift-6-Sprachmodus ist die Release-Baseline. Jüngste verfügbare 27.x-SDKs werden zusätzlich geprüft; Beta-only APIs gelangen nicht unbemerkt in die Release-Konfiguration. SwiftUI, Observation, Structured Concurrency, Actors, SwiftData, Apple-Frameworks und Swift Testing bilden den Standard. Keine Electron-, Flutter-, React-Native-, Catalyst- oder servergetriebene App-Shell. Keine Laufzeit in Python/Node. [A01–A04]

## IV. Nur Apple Intelligence als Modellanbieter
SystemLanguageModel auf geeigneten Vollgeräten und PrivateCloudComputeLanguageModel bei tatsächlicher Berechtigung. Keine fremden LLM-Anbieter, API-Schlüssel, externen Embeddingdienste oder heruntergeladenen Drittmodelle. Framework-Offenheit hebt diese Produktgrenze nicht auf. PCC-Zugang, Kontingent, Modell- und Sprachverfügbarkeit werden geprüft und verständlich angezeigt. Watch-PCC ist möglich, ein lokales Watch-Modell wird nicht erfunden. [A05–A09, A21]

## V. Jede Aussage hat eine Herkunft
Modellausgaben dürfen Evidence-IDs auswählen, nicht Zeitcodes oder URLs erfinden. Originaltext, Modellableitung und eigene Notiz bleiben unterscheidbar. Jede Fundstelle referenziert die konkrete Medien- und Transkriptfassung. Teilanalysen, fehlende Quellen und veraltete Fassungen sind sichtbar. Quellenbezug ist keine unabhängige Wahrheitsprüfung.

## VI. Automatisch vorbereiten, bewusst abspielen
Interessen und Chat dürfen Originalsegmente zu Fokuslisten verbinden. Wiedergabe startet nur nach ausdrücklicher Nutzeraktion oder innerhalb einer zuvor bewusst aktivierten Fokus-Sitzung. Eine neue Empfehlung allein darf niemals Ton starten. Vorschau, Kontext, Stop, ganze Folge und Rückkehr zur bisherigen Queue sind obligatorisch. Modellauswahl und ausführende Audiosteuerung werden technisch getrennt.

## VII. Inhaltsrechte und Privatsphäre vor Bequemlichkeit
Zugängliche RSS-Audiodaten und autorisierte Importe dürfen nach Nutzerauftrag verarbeitet werden. YouTube-Atom bedeutet keinen Audiozugang; keine versteckte Extraktion, kein Scraping von geschützten Captions, kein Hintergrund-IFrame. Zugangstoken gelangen nicht in Exporte, Logs oder den KI-Kontext. Netzwerk-/Sync-/PCC-Einwilligungen sind getrennt. Persönliche Interessen werden lokal verwaltet, korrigierbar und löschbar. [Y01–Y03]

## VIII. Jede Plattform ist ein echtes Produkt
iPhone für unterwegs, iPad für paralleles Lesen/Fragen/Hören, Mac für große Bibliothek/Mehrfenster/Dateien, Watch für kurze Erkenntnisse, Fokuswiedergabe und kompakte Fragen. Gemeinsame Domain, angepasste Oberfläche; keine hochskalierte iPhone-Ansicht auf Mac/iPad und keine Chat-Textwand auf der Watch.

## IX. Dauerhaftigkeit und begrenzte Ressourcen
Lokale Jobs, Commit-Grenzen, Wiederaufnahme und idempotente Artefakte sind Pflicht. Keine Garantie fester iOS-Hintergrundintervalle, keiner permanenten Watch-Inferenz und keiner sofortigen CloudKit-Zustellung. Ein Datensatz hat nur einen Synchronisationsbesitzer. Kein doppeltes SwiftData-Auto-Sync plus CKSyncEngine für dieselben Records. [A13–A16, A23]

## X. Evidenzbasierte Qualität und Governance
Deterministische Policy-/Timeline-/Sync-Tests plus Apple Evaluations für KI-Ergebnisse. Jede Anforderung hat Abnahmeszenario und Arbeitspaket. Kein Modelljudge darf eine fehlende Quellen-ID, widerrechtliche Quelle oder fehlende Startfreigabe überstimmen. Aktuelle SDK-Signaturen werden per Compile-Probe und Gerätetest belegt. Nicht ausgeführte Tests bleiben offen. [A19–A20]

## Änderungsverfahren
Änderungen aktualisieren Version, Änderungsgrund, spec, plan, contracts, tasks und Tests gemeinsam. Produktgrenzen, Plattformen, Quellenrechte, Datenlöschung oder fremde KI-Anbieter sind keine stillen Implementierungsdetails. Designbilder stehen unter dieser Constitution. Eine Abweichung benötigt einen expliziten ADR mit Nutzerentscheidung.



## Ergänzung 1.1 — Links, Historie und Wissenstransfer
Ein YouTube-Link genügt zum Start; der Nutzer muss keinen Feed ermitteln. Abo, Einzelimport und rückwirkende Analyse sind explizite getrennte Entscheidungen. Feedfenster und Gesamtarchiv sind nicht gleichzusetzen. Highlights, native semantische Suche und portable Transkripte sind First-Class-Funktionen. Optionaler MCP-Zugriff auf Mac bleibt gesondert freigegebene Datenweitergabe; appinterne Inferenz bleibt Apple-only. Drittanbieter-ASR, Whisper/MLX als Modellfallback und Drittcodec-Runtimes sind ausgeschlossen. Externe Metadaten-APIs wie YouTube Data API sind keine verbotenen Fremd-LLM-Anbieter.



## Ergänzung 1.2 — Perspektiven und kuratiertes Wissen
Sonar darf eine Behauptung prüfen helfen, nicht behaupten, alle Meinungen einer Person zu kennen. Nur ausdrückliche Bestätigung macht eine These zum eigenen Standpunkt. Gegenpositionen sind fair, belegt, abschaltbar und nicht auf Empörung oder Meinungswechsel optimiert. Politische Überzeugungsprofile werden nicht aus Verhalten abgeleitet; politische Sachvergleiche sind neutral, quellenbasiert und ohne Empfehlung oder Rangliste.

Die Session endet produktseitig mit einer überspringbaren Frage: Vertiefen, Parken oder Verwerfen. Original-Credits werden nicht entfernt. Parken kuratiert einen Wissensgraphen; Aufbewahren bedeutet keine Zustimmung. Graphvorschläge sind von menschlichen Notizen und Entscheidungen getrennt. Kein automatisches Weiterhören, kein heimliches Monitoring und kein Löschen von Originalwissen durch Verwerfen.

## Addendum 1.3 — persönliche Feeds
Persönliche Ausgaben respektieren bestehende Evidence-, Scope-, Timing-, Consent- und Apple-only-Regeln. Originalaudio bleibt Originalaudio; globale Wiedergabeintervalle sind von Kenntnis/Analyse zu trennen. Ausgabenpublikation startet nie Audio. Automatisches Layoutcover ist kein Image-Playground-Bild; verbotene/veraltete APIs werden nicht aus Produktwünschen abgeleitet.
