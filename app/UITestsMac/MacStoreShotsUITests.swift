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

    private func snap(_ app: XCUIApplication, _ name: String) {
        sleep(2)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "mac-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCaptureStoreShots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_ATLAS"] == "1"
                          || ProcessInfo.processInfo.environment["TEST_RUNNER_RUN_ATLAS"] == "1")
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-skip-onboarding", "-demo-content", "-AppleLanguages", "(de)"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        sleep(3)
        for (key, name) in [("1", "01"), ("2", "02"), ("3", "03"), ("4", "04"), ("5", "05")] {
            app.typeKey(key, modifierFlags: .command)
            snap(app, name)
        }
    }
}
