# Recherche: Was ein AI-First-Podcast-Player können muss

Stand September 2026. Grundlage für den Funktionsumfang von PodcastAI.

## Komfort eines guten Players

Overcast und Pocket Casts setzen den Massstab. Beide bieten einstellbares Tempo, Kapitelmarken, eine Warteschlange, Schlaf-Timer und die Fortsetzung an der zuletzt gehörten Stelle. Overcast kürzt Pausen (Smart Speed) und gleicht Lautstärke an (Voice Boost). Pocket Casts glänzt beim Abgleich zwischen Geräten. Neuere Player wie Podcast Guru zeigen Kapitel und Transkripte nach Podcasting 2.0 an.

Für PodcastAI umgesetzt: Tempo, Sprünge, Kapitel aus dem Feed (Podlove und Podcasting-2.0-JSON), Warteschlange, Schlaf-Timer, AirPlay, Sperrbildschirm, Fortsetzung über Geräte hinweg. Offen sind Pausenkürzung und Lautstärkeausgleich. Beides braucht eine eigene Audio-Verarbeitung statt AVPlayer.

## YouTube

Jeder öffentliche YouTube-Kanal hat einen Atom-Feed unter `youtube.com/feeds/videos.xml?channel_id=…`. Darüber lassen sich Kanäle abonnieren. Den Ton fremder Videos lädt die App nicht, das untersagen die Nutzungsbedingungen von YouTube. Stattdessen sucht sie im Apple-Podcast-Verzeichnis den Audio-Podcast desselben Anbieters, der sich laden und transkribieren lässt.

## Transkripte mit Zeitmarken

Seit iOS 26 und macOS 26 gibt es `SpeechAnalyzer` mit `SpeechTranscriber`. Das Modell läuft auf dem Gerät und ist für lange Aufnahmen gebaut. Mit der Option `audioTimeRange` trägt jedes Wort seine Zeit im Ton. Genau das braucht die App, um jede Aussage an eine Stelle im Original zu binden.

## Apple Intelligence und Private Cloud Compute

Das Foundation-Models-Framework liefert das Sprachmodell auf dem Gerät mit etwa 8.000 Token Kontext. Seit WWDC26 gibt es zusätzlich `PrivateCloudComputeLanguageModel`: Apples Servermodell mit 32.000 Token Kontext, derselben Sitzungs-API und einem Kontingent je Nutzer und Tag. Entwickler im App Store Small Business Program mit weniger als zwei Millionen Erstdownloads nutzen es ohne Cloud-Kosten. Voraussetzung ist die Berechtigung `com.apple.developer.private-cloud-compute`, die Apple auf Antrag über developer.apple.com/contact/request/private-cloud-compute/ vergibt. Getestet werden darf über TestFlight.

PodcastAI nutzt PCC für Antworten und Vergleiche, weil dort mehr Stellen in den Kontext passen. Alles andere läuft auf dem Gerät. Scheitert PCC an Netz oder Kontingent, beantwortet das Gerätemodell dieselbe Frage.

## Abgleich zwischen Geräten

SwiftData spiegelt eine Datenbank über CloudKit in die private iCloud-Datenbank. Die Regeln dafür: jede Eigenschaft optional oder mit Standardwert, alle Beziehungen optional, keine eindeutigen Schlüssel. Weil CloudKit Eindeutigkeit nicht erzwingen kann, bereinigt die App doppelte Datensätze selbst. TestFlight- und App-Store-Builds sprechen mit der Produktionsumgebung von CloudKit; das Schema muss dafür einmal in der CloudKit-Konsole von Development nach Production übertragen werden.

## Quellen

- [WWDC26: What's new in the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2026/241/)
- [Apple: Private Cloud Compute für Entwickler](https://developer.apple.com/private-cloud-compute/)
- [Apple Developer Documentation: PrivateCloudComputeLanguageModel](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel)
- [MacRumors: Apple Outlines Major AI and Developer Tool Updates (Juni 2026)](https://www.macrumors.com/2026/06/09/apple-outlines-major-ai-and-developer-tool-updates/)
- [WWDC25: Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Apple Developer Documentation: SpeechTranscriber audioTimeRange](https://developer.apple.com/documentation/speech/speechtranscriber/resultattributeoption/audiotimerange)
- [Fatbobman: Rules for adapting data models to CloudKit](https://fatbobman.com/en/snippet/rules-for-adapting-data-models-to-cloudkit/)
- [Hacking with Swift: How to sync SwiftData with iCloud](https://www.hackingwithswift.com/quick-start/swiftdata/how-to-sync-swiftdata-with-icloud)
- [TrimPod: Podcast app comparison 2026](https://trimpod.com/blog/podcast-app-comparison-7-apps-tested-side-by-side-in-2026)
- [Slant: Pocket Casts vs Overcast](https://www.slant.co/versus/2276/2284/~pocket-casts_vs_overcast)
- [YouTube RSS Feed ohne Werkzeug finden (2026)](https://www.wprssaggregator.com/youtube-rss-feed/)
