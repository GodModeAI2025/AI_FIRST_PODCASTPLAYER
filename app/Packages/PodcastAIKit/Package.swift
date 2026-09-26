// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PodcastAIKit",
    defaultLocalization: "de",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
    ],
    products: [
        .library(name: "PodcastAIKit", targets: ["PodcastAIKit"]),
        // Für das Widget: nur der Schnappschuss, ohne Datenbank und Modelle.
        .library(name: "PodcastAIWidgetData", targets: ["PodcastAIWidgetData"]),
        // Für die Erweiterung „An PodcastAI senden“: nur der Eingang und die
        // Linkregeln, ohne Datenbank, Medien und Modelle.
        .library(name: "PodcastAIShareInbox", targets: ["PodcastAIShareInbox"]),
    ],
    targets: [
        // Reine Domäne: Foundation only, keine Apple-Frameworks, vollständig testbar.
        .target(name: "PodcastAICore", resources: [.process("Localizable.xcstrings")]),

        // Quellen: RSS/Atom/OPML, Linkauflösung. Foundation + XMLParser.
        .target(name: "PodcastAISources", dependencies: ["PodcastAICore"], resources: [.process("Localizable.xcstrings")]),

        // Medien: Download, MediaVersion, Hash, atomarer FileStore.
        .target(name: "PodcastAIMedia", dependencies: ["PodcastAICore"], resources: [.process("Localizable.xcstrings")]),

        // Transkription: SpeechAnalyzer mit Medienzeit-Herkunft.
        .target(name: "PodcastAITranscription", dependencies: ["PodcastAICore", "PodcastAIMedia"], resources: [.process("Localizable.xcstrings")]),

        // Apple Intelligence: Router, Profile, evidenzgebundene Extraktion.
        .target(name: "PodcastAIIntelligence", dependencies: ["PodcastAICore"], resources: [.process("Localizable.xcstrings")]),

        // Persistenz: SwiftData-Modelle und ModelActor.
        // Persistenz kennt jetzt auch Wissen und Themenfeeds: dort liegen
        // die Typen, die der Nutzer selbst anlegt (Merkzettel, geparkte
        // Fragen, Themenfeeds, persönliche Ausgaben). Kein Kreis — keines
        // dieser Module kennt die Persistenz.
        .target(name: "PodcastAIPersistence", dependencies: [
            "PodcastAICore", "PodcastAIKnowledge", "PodcastAISmartFeeds",
        ], resources: [.process("Localizable.xcstrings")]),

        // Wissen: Claims, Index, Retrieval, Hörhistorie.
        .target(name: "PodcastAIKnowledge", dependencies: ["PodcastAICore", "PodcastAIIntelligence"], resources: [.process("Localizable.xcstrings")]),

        // Wiedergabe: FocusPlanner, PlaybackPolicy, PlaybackCoordinator.
        .target(name: "PodcastAIPlayback", dependencies: ["PodcastAICore", "PodcastAIKnowledge", "PodcastAIMedia"], resources: [.process("Localizable.xcstrings")]),

        // Persönliche Themenfeeds.
        .target(name: "PodcastAISmartFeeds", dependencies: ["PodcastAICore", "PodcastAIKnowledge", "PodcastAIPlayback"], resources: [.process("Localizable.xcstrings")]),

        // Eingang für „An PodcastAI senden“: Übergabe über die App Group.
        // Nur Foundation und die Linkregeln aus den Quellen, damit die
        // Erweiterung klein bleibt.
        .target(name: "PodcastAIShareInbox", dependencies: ["PodcastAICore", "PodcastAISources"], resources: [.process("Localizable.xcstrings")]),

        // Markdown-Export mit sicheren Quellenlinks.
        .target(name: "PodcastAIExport", dependencies: ["PodcastAICore", "PodcastAIKnowledge"], resources: [.process("Localizable.xcstrings")]),

        // Schnappschuss fürs Widget in der App Group. Nur Foundation, damit
        // die Widget-Erweiterung klein bleibt. Keine Texte für die Oberfläche.
        .target(name: "PodcastAIWidgetData"),

        // Sammelziel für die App-Targets.
        .target(name: "PodcastAIKit", dependencies: [
            "PodcastAICore", "PodcastAISources", "PodcastAIMedia", "PodcastAITranscription",
            "PodcastAIIntelligence", "PodcastAIKnowledge", "PodcastAIPlayback",
            "PodcastAISmartFeeds", "PodcastAIExport", "PodcastAIPersistence", "PodcastAIWidgetData",
            "PodcastAIShareInbox",
        ], resources: [.process("Localizable.xcstrings")]),

        .testTarget(name: "PodcastAIKitTests", dependencies: ["PodcastAIKit", "PodcastAIExport", "PodcastAIWidgetData", "PodcastAIShareInbox"]),
    ]
)
