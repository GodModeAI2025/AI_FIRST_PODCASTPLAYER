//
//  WidgetLink.swift
//  PodcastAIWidgetData
//
//  Die Adressen, mit denen ein Widget die App öffnet:
//
//      podcastai://topicupdates        der Tab „Themen-Updates“
//      podcastai://tag/<Kennung>       die Seite eines Tags
//
//  Jede andere App kann so eine Adresse öffnen. Sie führt deshalb nur zu
//  einer Ansicht und spielt nie etwas ab (Regel 1). Unbekanntes wird
//  ignoriert.
//

import Foundation

public enum WidgetLink: Hashable, Sendable {
    case topicUpdates
    /// Die rohe Kennung des Tags.
    case tag(String)

    public static let scheme = "podcastai"

    /// Länger ist keine Kennung der App.
    static let maximumIdentifierLength = 128

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .topicUpdates:
            components.host = "topicupdates"
        case .tag(let id):
            components.host = "tag"
            components.path = "/" + id
        }
        // Die Teile sind fest oder geprüft, die Adresse entsteht immer.
        return components.url ?? URL(string: "\(Self.scheme)://topicupdates")!
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme,
              let host = components.host?.lowercased() else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        switch host {
        case "topicupdates" where parts.isEmpty:
            self = .topicUpdates
        case "tag":
            guard parts.count == 1, Self.isIdentifier(parts[0]) else { return nil }
            self = .tag(String(parts[0]))
        default:
            return nil
        }
    }

    /// Kennungen der App bestehen aus Buchstaben, Ziffern, Binde- und
    /// Unterstrichen (UUID oder Prüfsumme). Alles andere kommt nicht von uns.
    static func isIdentifier(_ value: Substring) -> Bool {
        !value.isEmpty && value.count <= maximumIdentifierLength
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
