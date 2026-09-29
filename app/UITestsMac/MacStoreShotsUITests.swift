//
//  MacStoreShotsUITests.swift
//  PodcastAIMacUITests
//
//  Bilder für den App Store: die wichtigsten Bereiche mit Beispielinhalten.
//  Läuft nur mit RUN_ATLAS=1, damit der normale Testlauf schnell bleibt.
//

import XCTest

@MainActor
final class MacStoreShotsUITests: XCTestCase {

    /// Die App fotografiert ihr eigenes Fenster (`-store-shots`, nur Debug)
    /// und legt die Bilder in /tmp/pai-macshots ab. Der Test startet sie nur
    /// und wartet, denn er selbst sieht ohne Bedienungshilfen kein Fenster.
    func testCaptureStoreShots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_ATLAS"] == "1"
                          || ProcessInfo.processInfo.environment["TEST_RUNNER_RUN_ATLAS"] == "1")
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-skip-onboarding", "-demo-content", "-AppleLanguages", "(de)",
                               "-store-shots", "/tmp/pai-macshots"]
        app.launch()
        let last = URL(fileURLWithPath: "/tmp/pai-macshots/mac-07-meine-tags.png")
        for _ in 0..<60 where !FileManager.default.fileExists(atPath: last.path) { sleep(2) }
    }
}
