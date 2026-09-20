# Native Design Direction — Generation 27

## Hierarchie
Das bestehende Bild ist eine visuelle Idee für Informationsgruppen, keine fertige Designsystem-Implementierung. Die App nutzt aktuelle SwiftUI-Systemkomponenten, automatisch angepasste Materialien und Systemtypografie. Keine eigenen Kopien von Statusleiste, Tabbar, Uhr oder Geräte-Rahmen innerhalb der App. Keine mitgelieferten Apple-Schriftdateien.

Fachliche Hauptbereiche: Für dich · Mediathek · Fragen · Wissen. Suche ist ein System-/Toolbar-Einstieg, kein fachlich fünfter Bereich. „Fokus“ ist ein Hörmodus mit eigenem Sheet bzw. Detailpanel, nicht ein Paralleluniversum zur normalen Mediathek.

## Visuelle Sprache
Dunkelmodus aus dem Referenzbild bleibt eine Variante; Hellmodus und Systemmodus sind Pflicht. Semantische Akzentfarben kennzeichnen Wiedergabe, KI-Ableitung und persönliche Relevanz, aber jedes Signal besitzt zusätzlich Label/Icon. Liquid-Glass-Materialien gehören primär zu Navigation/Bedienelementen, nicht auf lange Transkripttexte. Hintergründe bleiben lesbar. Systemkontrast/Reduce Transparency hat Vorrang.

Typografie: systemische Textstile, skalierbare Zeilenhöhe, monospaced digits nur für Zeiten. Eine Zeile „18:40–20:10 · 1:30 Original“ darf nicht als unlesbarer Badge schrumpfen. Lange Titel umbrechen; Actionbuttons behalten verständliche Beschriftung.

## Wiederverwendbare Komponenten
RelevanceCard (Grund + Analysebasis), CoverageBadge (metadaten/teilweise/vollständig), EvidenceChip (Quelle + Originalzeit), ScopePicker (gewählt/analysiert/verwendet), FocusPlanCard (Budget + Kontext + Start), PlayerAccessory, CapabilityNotice, ProcessingStatus, InterestReasonSheet, ExportPreview. Keine Komponente setzt vollständige Analyse voraus.

## Neue SwiftUI-Mechanik
State-/ContentBuilder-Migration nach Xcode-27-Technote. Reordering und Toolbar-Overflow über aktuelle native APIs nach SDK-Probe. Inspector/NavigationSplitView an verfügbaren Platz anpassen. Ein Preview-Fixture je Empty/Loading/Partial/Ready/Offline/Quota/Error. `#Preview` soll ohne PCC und ohne private Daten funktionieren. [A03, A04, A24]

## Microcopy
„Vollständig ausgewertet“ heißt alle verfügbaren Inhalte dieser Fassung verarbeitet, nicht „wahr“.
„Neu für deinen Wissensbestand“ statt „Das weißt du noch nicht“.
„Nur Titel und Beschreibung geprüft“ statt künstlicher Vollzusammenfassung.
„3 Stellen · ca. 8:30 Hörzeit · Originalaudio“ statt unspezifischem „AI Playlist“.
„Auf dieser Watch sind 2 von 7 Quellen verfügbar“ statt „Alle Quellen“.
„Automatisch weiter innerhalb dieser Sitzung“ statt globalem unklarem Autoplay.
