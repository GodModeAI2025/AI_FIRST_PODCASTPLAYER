// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PodcastAIKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "PodcastAIKit", targets: ["PodcastAIKit"]),
    ],
    targets: [
        // Reine Domäne: Foundation only, keine Apple-Frameworks, vollständig testbar.
        .target(name: "PodcastAICore"),

        // Quellen: RSS/Atom/OPML, Linkauflösung. Foundation + XMLParser.
        .target(name: "PodcastAISources", dependencies: ["PodcastAICore"]),

        // Medien: Download, MediaVersion, Hash, atomarer FileStore.
        .target(name: "PodcastAIMedia", dependencies: ["PodcastAICore"]),

        // Transkription: SpeechAnalyzer mit Medienzeit-Herkunft.
        .target(name: "PodcastAITranscription", dependencies: ["PodcastAICore", "PodcastAIMedia"]),

        // Apple Intelligence: Router, Profile, evidenzgebundene Extraktion.
        .target(name: "PodcastAIIntelligence", dependencies: ["PodcastAICore"]),

        // Wissen: Claims, Index, Retrieval, Hörhistorie.
        .target(name: "PodcastAIKnowledge", dependencies: ["PodcastAICore", "PodcastAIIntelligence"]),

        // Wiedergabe: FocusPlanner, PlaybackPolicy, PlaybackCoordinator.
        .target(name: "PodcastAIPlayback", dependencies: ["PodcastAICore", "PodcastAIKnowledge"]),

        // Persönliche Themenfeeds.
        .target(name: "PodcastAISmartFeeds", dependencies: ["PodcastAICore", "PodcastAIKnowledge", "PodcastAIPlayback"]),

        // Markdown-Export mit sicheren Quellenlinks.
        .target(name: "PodcastAIExport", dependencies: ["PodcastAICore", "PodcastAIKnowledge"]),

        // Sammelziel für die App-Targets.
        .target(name: "PodcastAIKit", dependencies: [
            "PodcastAICore", "PodcastAISources", "PodcastAIMedia", "PodcastAITranscription",
            "PodcastAIIntelligence", "PodcastAIKnowledge", "PodcastAIPlayback",
            "PodcastAISmartFeeds", "PodcastAIExport",
        ]),

        .testTarget(name: "PodcastAIKitTests", dependencies: ["PodcastAIKit"]),
    ]
)
