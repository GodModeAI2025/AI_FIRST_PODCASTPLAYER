# Implementierungsauftrag: Smart Podcast List (1.3)

Lies AGENTS.md, die Constitution, spec.md, smart-podcast-list.md, plan.md und data-model.md. Arbeite im vorhandenen BrainSpeak-Code nach Baseline-Audit. Kein Push, kein neues Ersatzprojekt und keine Behauptung fehlender Features ohne Codeprüfung.

Implementiere FR-121–144 / US17–20 / T219–266. Reuse PlaybackCoordinator, Evidence-Resolver, Profil und CKSyncEngine-Owner. Erweitere die Persistenz additiv für Feedkonfigurationen, immutable persönliche Ausgaben, Cover-Assets und globale segmentgenaue Hörhistorie. JSON-Verträge, synthetische Fixtures und Pakettests geben Regeln vor, sind keine fertige App.

Das Produkt muss beide Pfade demonstrieren: relevante Stellen in einer Originalfolge und eigene thematische Feed-Ausgaben aus mehreren ungehörten Quellen. Unveränderte Originalstimmen, keine KI-Moderation. Alles-Ungehörte-Modus darf keine Top-k-Vollständigkeit vortäuschen. Wiederholter Refresh ohne neue Stellen liefert keine neue Ausgabe. Play startet genau eine begrenzte Ausgabe; Daten-/Syncereignisse erzeugen keinen Ton.

Apple-only-Cover: automatische native Gestaltung plus optionaler Image-Playground-Systemdialog mit Bestätigung auf Vollclients. Keine ImageCreator-Aufrufe auf 27er-Zielen, kein externalProvider, keine private API oder automatische Sheet-Bedienung. API-Signaturen, Ergebnisdatei-Lebensdauer und Geräteverfügbarkeit mit aktuellem offiziellen SDK prüfen. Bei fehlender Unterstützung bleibt das native Cover. Watch verwendet synchronisierte Bilder.

Führe erst deterministische Domain-/Schema-Tests, dann Swift-Tests, dann reale 27er-Geräteabnahmen aus. Dokumentiere genau, was bestanden, fehlgeschlagen oder nicht ausführbar war. Markiere Featuretasks erst nach tatsächlicher Implementierung als erledigt. Keine bestehenden Dateien blind aus diesem Paket überschreiben.
