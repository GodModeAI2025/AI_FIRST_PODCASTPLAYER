# Vom Nutzer gelieferte Wettbewerbsnotiz (Wortlaut)

Die nachfolgende Notiz ist Nutzerinput, keine durch das Paket bestätigte Produkt- oder Zahlenrecherche. Die Bewertung steht in references/competitive-input-assessment.md. Alle Quellenlinks sind in user-supplied-reference-links.json erhalten.

Was dabei ? Ein AI-first Audio Player muss Audio nicht nur abspielen, sondern **verstehen, durchsuchbar machen und in den Wissens-Workflow integrierbar machen** – Transkripte, Kapitel, Zusammenfassungen und semantische Suche sind das Minimum; der Player selbst wird zur Nebensache. Vor allem Podcast-Apps wie Snipd, Onda und Anycast zeigen bereits, in welche Richtung das geht.[1][2][3]

## KI-Kernfunktionen

- **Transkription in Echtzeit oder vorgeneriert**: Snipd verarbeitet über 1 Million Episoden vor, sodass Transkripte beim Drücken der Play-Taste bereits bereitstehen. Anycast bietet Live-Transkription inkl. Übersetzung in über 10 Sprachen.[3][4]
- **AI-Kapitel & Navigation**: Automatisch generierte Kapitel und suchbare Transkripte, um gezielt zu Segmenten zu springen statt linear zu spulen.[1]
- **Zusammenfassungen & Relevanz-Filter**: AI-Summaries pro Episode helfen, vor dem Hören zu entscheiden, ob sich das Hören lohnt.[1]
- **Highlights & Wissensextraktion**: Snipd speichert per Headphone-Tap Ideen mit Transkript-Ausschnitt und Zusammenfassung; Onda erkennt automatisch Schlüsselmomente und macht daraus durchsuchbare Notizen.[1][2]
- **Chat mit dem Inhalt**: „Frag die Episode" – Q&A über das Transkript, wie es Podcript oder Onda vormachen.[2][5]
- **Smart Skip**: Werbung, Intros und Outros automatisch überspringen.[1]

## Klassische Player-Basis (Non-Negotiables)

Auch der beste KI-Layer rettet einen Player nicht, wenn das Fundament fehlt: stabile Hintergrund-Wiedergabe, Lockscreen/Notification-Controls, Formate wie MP3/FLAC/AAC/OGG, Offline-Fähigkeit, Fortschritts-Sync über Geräte, Geschwindigkeitsregelung, Sleep-Timer und eine saubere Library-Organisation. Das ist genau die Ebene, auf der BookPlayer und YourPods als Swift-Basis bereits stark sind – Kapitel-Handling, AVFoundation-Abstraktion und Sync sind dort gelöst.[6]

## Architektur: Local-First & Agenten-Schnittstellen

Für dein Profil würde ich folgende Anforderungen ansetzen:

- **Transkription lokal oder wählbar**: On-Device-Modelle (Whisper-Klasse) für Privatsphäre, Cloud nur als Option – vergleichbar mit Apps, die explizit „Privacy First, keine Uploads" bewerben.[7]
- **Transkripte als First-Class-Daten**: als SRT/VTT/TXT exportierbar, mit Speaker-Labels und Word-Level-Timestamps, damit sie in Obsidian-ähnliche Systeme fließen können.[8][9]
- **Embedding-Index über die eigene Library**: semantische Suche über alle jemals gehörten Episoden – das differenzierende Feature gegenüber klassischen Playern.
- **MCP/Agent-Zugriff**: Der Player sollte als Tool für Claude/Codex-Workflows exposing können („suche in meinen Podcasts nach X", „erstelle Notizen aus Episode Y") – das passt zu deinen bestehenden MCP-Integrationen.
- **Reversible, modulare Pipeline**: Transkription → Kapitel → Summary als separate, wiederholbare Schritte mit Caching, damit nichts doppelt verarbeitet wird.

## Abgrenzung zu „AI-Pseudo"-Playern

Viele Apps im Store kleben „AI" nur als Label drauf: syncronisierte Lyrics, Equalizer-Presets oder adaptive UI werden als „AI-Enhanced" verkauft, obwohl kein echtes Sprachmodell dahintersteht. Echte AI-First-Player messen sich daran, ob man **mit dem Audio interagieren** kann – Fragen stellen, Zitate extrahieren, Segmente finden – und nicht nur besser hören.[6][7]

**Kurzfazit als Anforderungs-Checkliste**: Transkript + Kapitel + Summary + semantische Suche + Export/Schnittstelle für Agenten, alles auf einer soliden, local-first Player-Basis. Wenn du das auf Basis von BookPlayer/YourPods weiterdenkst, wäre der interessanteste nächste Schritt ein Transkript-Pipeline-Design (On-Device Whisper vs. API) inklusive Datenmodell für Highlights – soll ich dazu eine konkrete Architektur skizzieren?

## Quellen
[1] https://apps.apple.com/sg/app/snipd-ai-podcast-player/id1557206126
[2] https://getonda.app/
[3] https://anycast.website/
[4] https://www.podshot.ai/tools/transcription
[5] https://play.google.com/store/apps/details?id=com.podcast.transcript&hl=en
[6] https://play.google.com/store/apps/details?id=ai.musicplayer.aimusicplayer
[7] https://play.google.com/store/apps/details?id=com.darkmp3player&hl=en_US
[8] https://www.rask.ai/tools/transcript-for-podcast
[9] https://stt.ai/podcasts/
[10] https://chromewebstore.google.com/detail/mixtape-ai-music-player-f/hbehonkemncmedacjgodmhcdaglojlgn
[11] https://play.google.com/store/apps/details?id=com.tencent.ibg.joox&hl=en_US
[12] https://apps.apple.com/us/app/lightcast-ai-podcast-player/id6443644334
[13] https://transistor.fm/best-ai-podcast-tools/
[14] https://download.cnet.com/ai-music-player-aurora/3000-android-ai-music-player-aurora.html
[15] https://note.com/enspire/n/ndbc59a9c16e0?hl=en
