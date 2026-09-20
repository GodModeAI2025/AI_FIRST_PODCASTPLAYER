//
//  Revision.swift
//  PodcastAICore
//

import Foundation

/// Monoton steigende Fassungsnummer eines veränderlichen Datensatzes.
public struct Revision: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {

    public let value: Int

    public init(_ value: Int) { self.value = max(0, value) }

    public static let initial = Revision(0)

    public func next() -> Revision { Revision(value + 1) }

    public static func < (lhs: Revision, rhs: Revision) -> Bool { lhs.value < rhs.value }

    public var description: String { "r\(value)" }
}

/// Woher ein Inhalt stammt. Originaltext, Modellableitung und eigene Notiz
/// bleiben unterscheidbar — Constitution V.
public enum Provenance: String, Codable, Sendable, CaseIterable {
    /// Wörtlich aus der Quelle übernommen.
    case original
    /// Von einem Apple-Modell abgeleitet.
    case derived
    /// Vom Nutzer selbst geschrieben.
    case user
    /// Aus Metadaten der Quelle, nicht aus dem Audio.
    case metadata

    public var isTrustworthyAsQuote: Bool { self == .original }

    public var label: String {
        switch self {
        case .original: "Originaltext"
        case .derived:  "KI-Ableitung"
        case .user:     "Eigene Notiz"
        case .metadata: "Quellenangabe"
        }
    }
}

/// Wie vollständig ein Inhalt erschlossen ist. Teilanalysen bleiben sichtbar,
/// statt als vollständig ausgegeben zu werden.
public enum AnalysisCoverage: Hashable, Codable, Sendable {
    /// Nichts analysiert.
    case none
    /// Teilweise: welcher Anteil der Medienzeit erschlossen ist.
    case partial(fraction: Double, analyzed: IntervalSet)
    /// Vollständig über die gesamte Medienzeit.
    case complete

    public var fraction: Double {
        switch self {
        case .none: 0
        case .partial(let f, _): min(max(f, 0), 1)
        case .complete: 1
        }
    }

    public var isComplete: Bool { if case .complete = self { true } else { false } }

    /// Darf auf dieser Grundlage eine Vollständigkeitsaussage getroffen werden?
    /// „Alle Aussagen zu X“ verlangt vollständige Abdeckung.
    public var supportsExhaustiveClaims: Bool { isComplete }

    public var label: String {
        switch self {
        case .none: "nicht analysiert"
        case .partial(let f, _): "teilweise analysiert (\(Int((f * 100).rounded())) %)"
        case .complete: "vollständig analysiert"
        }
    }
}
