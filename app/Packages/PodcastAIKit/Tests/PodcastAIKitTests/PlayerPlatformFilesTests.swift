//
//  PlayerPlatformFilesTests.swift
//
//  Die Dateien der neuen Plattformen: CarPlay bleibt aus den Standarddateien
//  heraus (sonst scheitert die Signierung, bis Apple es freigibt) und die
//  Fassungen für CarPlay laufen im Gleichschritt mit den Standarddateien. Uhr,
//  Fernseher und CarPlay enthalten nichts von der KI.
//

import Testing
import Foundation

@Suite("Player: Dateien der Plattformen")
struct PlayerPlatformFilesTests {

    private static var apps: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Apps", directoryHint: .isDirectory)
    }

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.apps.appending(path: path))
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func equal(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }

    // MARK: CarPlay

    @Test func carPlayStaysOutOfTheDefaultFiles() throws {
        let entitlements = try plist("PodcastAI/PodcastAI.entitlements")
        #expect(entitlements["com.apple.developer.carplay-audio"] == nil)
        let info = try plist("PodcastAI/Info.plist")
        #expect(info["UIApplicationSceneManifest"] == nil)
        // Auch nicht in den Dateien der anderen Ziele.
        for path in ["PodcastAIMac/PodcastAIMac.entitlements", "PodcastAIWatch/PodcastAIWatch.entitlements",
                     "PodcastAITV/PodcastAITV.entitlements"] {
            #expect(try plist(path)["com.apple.developer.carplay-audio"] == nil, "\(path)")
        }
    }

    @Test func carPlayEntitlementsAreTheDefaultOnesPlusCarPlayAudio() throws {
        var expected = try plist("PodcastAI/PodcastAI.entitlements")
        expected["com.apple.developer.carplay-audio"] = true
        #expect(equal(try plist("PodcastAI/PodcastAICarPlay.entitlements"), expected))
    }

    @Test func carPlayInfoIsTheDefaultOnePlusTheSceneManifest() throws {
        var variant = try plist("PodcastAI/InfoCarPlay.plist")
        let manifest = try #require(variant.removeValue(forKey: "UIApplicationSceneManifest") as? [String: Any])
        #expect(equal(variant, try plist("PodcastAI/Info.plist")))

        let configurations = try #require(manifest["UISceneConfigurations"] as? [String: Any])
        let roles = try #require(
            configurations["CPTemplateApplicationSceneSessionRoleApplication"] as? [[String: Any]])
        #expect(roles.count == 1)
        #expect(roles.first?["UISceneClassName"] as? String == "CPTemplateApplicationScene")
        #expect(roles.first?["UISceneDelegateClassName"] as? String == "$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate")
    }

    @Test func theProjectSwitchesCarPlayOnlyThroughOneBuildSetting() throws {
        let project = try String(
            contentsOf: Self.apps.deletingLastPathComponent().appending(path: "project.yml"), encoding: .utf8)
        #expect(project.contains("PODCASTAI_VARIANT: \"\""))
        #expect(project.contains("Info$(PODCASTAI_VARIANT).plist"))
        #expect(project.contains("PodcastAI$(PODCASTAI_VARIANT).entitlements"))
    }

    // MARK: Uhr und Fernseher

    @Test(arguments: [
        "PodcastAIWatch/PodcastAIWatch.entitlements", "PodcastAITV/PodcastAITV.entitlements",
    ])
    func playerEntitlementsAreICloudOnly(path: String) throws {
        let entitlements = try plist(path)
        #expect(Set(entitlements.keys) == [
            "com.apple.developer.icloud-container-identifiers", "com.apple.developer.icloud-services",
        ])
        #expect(entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
                == ["iCloud.com.godmodeai.podcastai"])
    }

    @Test(arguments: ["PodcastAIWatch/Info.plist", "PodcastAITV/Info.plist"])
    func playerInfoDeclaresBackgroundAudioOnly(path: String) throws {
        let info = try plist(path)
        #expect(info["UIBackgroundModes"] as? [String] == ["audio"])
    }

    @Test func theWatchAppIsEmbeddedWithTheRightIdentifiers() throws {
        let info = try plist("PodcastAIWatch/Info.plist")
        #expect(info["WKCompanionAppBundleIdentifier"] as? String == "com.godmodeai.podcastai.mobile")
        let project = try String(
            contentsOf: Self.apps.deletingLastPathComponent().appending(path: "project.yml"), encoding: .utf8)
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: com.godmodeai.podcastai.mobile.watchkitapp"))
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: com.godmodeai.podcastai.tv"))
    }

    @Test func theWatchIconIsTheAppIcon() throws {
        let shared = try Data(contentsOf: Self.apps.appending(
            path: "Shared/Assets.xcassets/AppIcon.appiconset/icon-1024.png"))
        let watch = try Data(contentsOf: Self.apps.appending(
            path: "PodcastAIWatch/Assets.xcassets/AppIcon.appiconset/icon-1024.png"))
        #expect(shared == watch, "Das Symbol der Uhr weicht vom App-Symbol ab")
        // Der gemeinsame Katalog bleibt, wie er war: ein watchOS-Eintrag dort
        // lässt den Mac-Bau warnen.
        let contents = try String(contentsOf: Self.apps.appending(
            path: "Shared/Assets.xcassets/AppIcon.appiconset/Contents.json"), encoding: .utf8)
        #expect(!contents.contains("watchos"))
    }

    // MARK: Keine KI in den Oberflächen

    private static let forbiddenWords = [
        "Transkript", "transcript", "Transcript", "Fakten", "Chat", "Intelligence", "FoundationModels",
        "Themen-Update", "MCP", "relevantToday", "smartFeeds", "Interest", "ChapterTag",
    ]

    private func sourceTexts(in folder: String, extensions: Set<String>) throws -> [(String, String)] {
        let directory = Self.apps.appending(path: folder)
        let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var result: [(String, String)] = []
        for case let url as URL in files where extensions.contains(url.pathExtension) {
            result.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return result
    }

    @Test(arguments: ["PodcastAIWatch", "PodcastAITV", "PlayerShared", "PodcastAI/CarPlay"])
    func playerSurfacesMentionNothingOfTheAI(folder: String) throws {
        let texts = try sourceTexts(in: folder, extensions: ["swift", "xcstrings", "plist", "entitlements"])
        #expect(!texts.isEmpty)
        for (name, text) in texts {
            for word in Self.forbiddenWords {
                // Der Hinweis in den Entitlements („Bewusst nicht dabei: Apple Intelligence …“) ist Kommentar.
                if name.hasSuffix(".entitlements") { continue }
                #expect(!text.contains(word), "\(folder)/\(name) enthält „\(word)“")
            }
        }
    }
}
