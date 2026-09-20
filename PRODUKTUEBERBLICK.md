# Sonar / BrainSpeak — dein Audio wird zu Wissen

**Apple-native für iOS, iPadOS, watchOS und macOS 27.**
Arbeitsname Sonar, technische Hauptbasis BrainSpeak. Version 1.3, 20. September 2026.

## Der Kern
Du abonnierst Quellen, nicht die Verpflichtung, alles zu hören. Sonar erschließt zugängliche Inhalte, zeigt ihre Relevanz für deine bestätigten Interessen, beantwortet Fragen mit Belegen und spielt bei Bedarf die passenden Originalstellen. Ungehört, analysiert, gelesen und bewusst als bekannt markiert bleiben unterschiedliche Zustände.

## Quelle hinein
Ein RSS-, Folgen- oder YouTube-Link genügt. Bei YouTube werden Video, Kanal und Feed automatisch aufgelöst. Die App bietet Einzelimport, Kanalabo und rückwirkende Analyse an. Historische Folgen kommen aus dem tatsächlich verfügbaren Katalog, nicht nur aus dem aktuellen Feedfenster. Gefundene Einträge und inhaltlich analysierbare Folgen werden getrennt gezählt.

## Wissen heraus
Transkript, Original- und KI-Kapitel, Aussagen, Highlights und Zusammenfassungen bilden einen durchsuchbaren Bestand. Du fragst eine Folge, mehrere ausgewählte Folgen oder alle analysierten Inhalte. Quellenzeitcodes führen auf die konkrete Medienfassung zurück. Die App darf Inhalte nicht allein aus Titel oder Beschreibung als vollständig verstanden ausgeben.

## Fokus hören
„Spiele mir die Stellen zum Betriebsaufwand“ wird zum geprüften Original-Hörplan. Er zeigt Zeitbudget, Quellenwechsel und Kontext. Innerhalb einer bewusst gestarteten Fokus-Session darf die App passende Sequenzen automatisch nacheinander abspielen. Eine neu eingetroffene Empfehlung allein startet niemals Ton.

## Widerspruchs-Mixer
Der freiwillige Modus macht belegte Gegenpositionen zugänglich. Er unterscheidet deine bestätigte These von einer Aussage, die du lediglich gespeichert oder gehört hast. Eine andere Annahme ist nicht automatisch ein Gegenbeweis. Hörplan und Einordnung bewahren den Originalkontext. Ziel ist ein besseres eigenes Urteil, nicht eine vorbestimmte Meinungsänderung.

## Breadcrumb-Trail
Eine bewusst abgeschlossene Session endet mit einer überspringbaren Frage:

> Willst du das vertiefen, als Wissenslandkarte parken oder den Vorschlag verwerfen?

**Vertiefen** zeigt eine belegte Anschlussfrage, tatsächlich vorhandene Quellen und ein neues begrenztes Zeitbudget. **Parken** sichert Frage, Erkenntnisse, Gegensätze, Belege und eigene Notizen als kuratierten Wissensgraphen. **Verwerfen** verwirft nur den Vorschlag, nicht die ursprünglichen Highlights, Quellen oder Notizen.

Parken bedeutet Aufbewahrung, nicht Zustimmung zu jeder Aussage. Die Wissenslandkarte lässt sich als Markdown mit relativen Verknüpfungen, Graph-JSON und Mermaid-Datei in einen gewählten Wissensordner übertragen. Externer Export hat einen eigenen, überprüfbaren Status. Auf der Watch vorgemerkt ist noch nicht im Wissens-Tool gespeichert.

## Vier Geräte, vier passende Oberflächen
| Plattform | Schwerpunkt |
|---|---|
| iPhone | Quellen teilen, Relevanz prüfen, fokussiert hören und unterwegs fragen. |
| iPad | Transkript, Chat und Quellen parallel bearbeiten; adaptive Mehrspaltenansicht. |
| Mac | Große Bibliotheken, Archivjobs, native Fenster, Wissensgraph und kontrollierte MCP-Freigabe. |
| Watch | Kurze Erkenntnisse, vorbereitete Originalsequenzen, Highlights und kompakte Abschlussentscheidungen. |

## Verbindliche technische Richtung
Nur Apple-Modelle und native Swift-/Apple-Frameworks. Kein Ersatz von BrainSpeak durch eine Web-App und kein stiller Wechsel zu einem externen LLM. Verfügbarkeit, Entitlements, Hintergrundressourcen und Plattformgrenzen werden real geprüft. Aktuelle SDK-Angaben und ihre Quellen stehen im Quellenregister; sie sind keine schon ausgeführten Gerätetests.

## Umfang des Pakets
144 Anforderungen, 20 Nutzerabläufe und 266 zugeordnete Umsetzungsschritte. Dazu ausgefüllte Spec-Kit-Dateien, Architekturentscheidungen, JSON-/Swift-Verträge, Originalscreens, acht Abläufe, vier Plattformbeschreibungen, synthetische Testdaten und Prüfskripte. Die Anwendung selbst und der nicht erreichbare BrainSpeak-Quellcode sind nicht enthalten.

## Neu: Smart Podcast List — eigene Themen-Podcasts
Du konfigurierst zum Beispiel iOS/Mobile, Google/KI, EnBW oder Datenschutz. Daraus entstehen einzelne Themenfeeds oder dein gemeinsames „Mein Themen-Update“. Die KI fragt die verfügbaren Inhalte gegen dein Profil ab. Neue, passende und noch nicht gehörte Originalstellen erscheinen als persönliche Folgen mit Titel, Shownotes, Kapiteln und Cover. Einmal Play spielt die Originalstimmen nacheinander. Auch innerhalb einer Originalfolge bleibt „Nur für mich relevante Stellen“ verfügbar.

Globale abgespielte Originalintervalle verhindern Wiederholungen zwischen Themenfeeds und Originalfolgen. „Alles Ungehörte“ ist ausdrücklich vom kurzen budgetierten Update getrennt. Neue Inhalte verändern laufende Ausgaben nicht und starten keinen Ton.

Image Playground wird als native Covergestaltung per Systemdialog integriert. Automatische native Layoutcover stehen sofort bereit; Apple unterstützt ImageCreator ab Version 27 nicht mehr. Individuelle Image-Playground-Bilder werden deshalb nicht als unsichtbarer Hintergrundprozess versprochen. [A27–A30]

Die vollständige Erweiterung: [ERWEITERUNG_SMART_PODCAST_LIST.md](ERWEITERUNG_SMART_PODCAST_LIST.md).
