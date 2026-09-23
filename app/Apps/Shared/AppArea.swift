//
//  AppArea.swift
//  PodcastAI
//
//  Die fünf Bereiche der App.
//
//  Nicht `Tab` genannt: das verdeckte `SwiftUI.Tab` im eigenen
//  Gültigkeitsbereich, und die Aufrufe darunter hätten versucht, das Enum
//  als Funktion zu benutzen. Ein Fehler, den man einmal macht.
//
//  Der Typ liegt hier und nicht in der Ansicht, weil `AppModel` ihn hält:
//  ein leerer Zustand muss auf den nächsten Schritt zeigen können, und der
//  liegt in einem anderen Bereich.
//

import Foundation

public enum AppArea: Hashable, Sendable, CaseIterable {
    case forYou, feeds, ask, library, knowledge

    public var title: String {
        switch self {
        case .forYou: "Für dich"
        case .feeds: "Meine Feeds"
        case .ask: "Fragen"
        case .library: "Mediathek"
        case .knowledge: "Wissen"
        }
    }
}
