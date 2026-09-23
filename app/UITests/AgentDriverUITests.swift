//
//  AgentDriverUITests.swift
//  PodcastAIUITests
//
//  Fernsteuerung für Testpersonen. Ein Agent legt Befehle als JSON-Dateien
//  in ein Verzeichnis, dieser Test führt sie in der App aus und schreibt
//  Elementliste und Screenshot zurück. So bedienen Personas die App wirklich,
//  statt Screenshots und Code zu lesen.
//
//  Läuft nur mit RUN_AGENT_DRIVER=1 und AGENT_DRIVER_DIR=<Verzeichnis>
//  (beim Aufruf über xcodebuild mit dem Präfix TEST_RUNNER_).
//
//  Befehle (Datei cmd-<n>.json, Antwort res-<n>.json):
//    {"op":"launch","args":["-uitest-fresh"]}
//    {"op":"tap","index":12}            Element aus der letzten Liste
//    {"op":"tap","label":"Abonnieren"}  erstes Element mit diesem Label oder dieser Kennung
//    {"op":"type","text":"Lage der Nation"}
//    {"op":"swipe","direction":"up"}    up, down, left, right
//    {"op":"back"}
//    {"op":"wait","seconds":3}
//    {"op":"look"}                      nur Liste und Screenshot
//    {"op":"end"}
//

import XCTest

@MainActor
final class AgentDriverUITests: XCTestCase {

    private struct Command: Decodable {
        let op: String
        var args: [String]?
        var index: Int?
        var label: String?
        var text: String?
        var direction: String?
        var seconds: Double?
    }

    private struct Entry {
        let type: String
        let label: String
        let identifier: String
        let value: String
        let frame: CGRect
    }

    private var app = XCUIApplication()
    private var entries: [Entry] = []

    @MainActor
    func testDrive() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_AGENT_DRIVER"] == "1", let path = environment["AGENT_DRIVER_DIR"] else {
            throw XCTSkip("Nur für die Persona-Fernsteuerung")
        }
        continueAfterFailure = true
        let directory = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "bereit".write(to: directory.appendingPathComponent("ready"), atomically: true, encoding: .utf8)

        var number = 1
        var idleSince = Date()
        while Date().timeIntervalSince(idleSince) < 45 * 60 {
            let file = directory.appendingPathComponent("cmd-\(number).json")
            guard let data = try? Data(contentsOf: file) else {
                Thread.sleep(forTimeInterval: 0.3)
                continue
            }
            idleSince = Date()
            var result: [String: Any] = ["n": number]
            do {
                let command = try JSONDecoder().decode(Command.self, from: data)
                if command.op == "end" {
                    write(["n": number, "ok": true], to: directory, number: number)
                    return
                }
                try run(command)
                result["ok"] = true
            } catch {
                result["ok"] = false
                result["error"] = "\(error)"
            }
            Thread.sleep(forTimeInterval: 0.6)
            result["elements"] = describeScreen()
            let shot = directory.appendingPathComponent("shot-\(number).png")
            try? app.screenshot().pngRepresentation.write(to: shot)
            result["screenshot"] = shot.path
            write(result, to: directory, number: number)
            number += 1
        }
    }

    private struct DriverError: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    private func run(_ command: Command) throws {
        switch command.op {
        case "launch":
            app = XCUIApplication()
            app.launchArguments = command.args ?? ["-skip-onboarding"]
            app.launch()
            Thread.sleep(forTimeInterval: 2)
        case "tap":
            if let index = command.index {
                guard entries.indices.contains(index) else { throw DriverError(description: "kein Element \(index)") }
                let frame = entries[index].frame
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            } else if let label = command.label {
                let match = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label)).firstMatch
                guard match.waitForExistence(timeout: 5), match.isHittable else {
                    throw DriverError(description: "nicht gefunden oder verdeckt: \(label)")
                }
                match.tap()
            } else {
                throw DriverError(description: "tap braucht index oder label")
            }
        case "type":
            // Ohne Fokus bricht typeText den ganzen Test ab. Dann lieber melden.
            let focused = app.descendants(matching: .any)
                .matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
            guard focused.exists else {
                throw DriverError(description: "Kein Eingabefeld hat den Fokus. Tippe zuerst ein Feld an.")
            }
            focused.typeText(command.text ?? "")
        case "swipe":
            switch command.direction {
            case "down": app.swipeDown()
            case "left": app.swipeLeft()
            case "right": app.swipeRight()
            default: app.swipeUp()
            }
        case "back":
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists, back.isHittable else { throw DriverError(description: "kein Zurück-Knopf") }
            back.tap()
        case "wait":
            Thread.sleep(forTimeInterval: min(command.seconds ?? 2, 60))
        case "look":
            break
        default:
            throw DriverError(description: "unbekannter Befehl \(command.op)")
        }
    }

    /// Sichtbare, bedienbare oder beschriftete Elemente als kurze Zeilen.
    @MainActor
    private func describeScreen() -> [String] {
        entries = []
        guard let root = try? app.snapshot() else { return ["(keine Momentaufnahme)"] }
        let screen = root.frame
        collect(root, screen: screen)
        return entries.enumerated().map { index, entry in
            var line = "[\(index)] \(entry.type)"
            if !entry.label.isEmpty { line += " \"\(entry.label.prefix(160))\"" }
            if !entry.identifier.isEmpty { line += " id=\(entry.identifier)" }
            if !entry.value.isEmpty { line += " value=\"\(entry.value.prefix(60))\"" }
            return line
        }
    }

    private static let interesting: Set<XCUIElement.ElementType> = [
        .button, .staticText, .textField, .secureTextField, .textView, .searchField, .switch, .toggle,
        .slider, .link, .cell, .tab, .segmentedControl, .menuItem, .image, .navigationBar, .alert, .sheet,
    ]

    private func collect(_ node: XCUIElementSnapshot, screen: CGRect) {
        let frame = node.frame
        let visible = frame.width > 1 && frame.height > 1 && screen.intersects(frame)
        if visible, Self.interesting.contains(node.elementType),
           !(node.label.isEmpty && node.identifier.isEmpty && node.elementType == .image) {
            let value = (node.value as? String) ?? ""
            entries.append(Entry(type: Self.name(node.elementType), label: node.label,
                                 identifier: node.identifier, value: value, frame: frame))
        }
        for child in node.children { collect(child, screen: screen) }
    }

    private static func name(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: "Button"
        case .staticText: "Text"
        case .textField, .secureTextField: "TextField"
        case .textView: "TextView"
        case .searchField: "SearchField"
        case .switch, .toggle: "Switch"
        case .slider: "Slider"
        case .link: "Link"
        case .cell: "Cell"
        case .tab: "Tab"
        case .segmentedControl: "Segmented"
        case .menuItem: "MenuItem"
        case .image: "Image"
        case .navigationBar: "NavBar"
        case .alert: "Alert"
        case .sheet: "Sheet"
        default: "Element"
        }
    }

    private func write(_ object: [String: Any], to directory: URL, number: Int) {
        let target = directory.appendingPathComponent("res-\(number).json")
        let temporary = directory.appendingPathComponent(".res-\(number).tmp")
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) {
            try? data.write(to: temporary)
            try? FileManager.default.moveItem(at: temporary, to: target)
        }
    }
}
