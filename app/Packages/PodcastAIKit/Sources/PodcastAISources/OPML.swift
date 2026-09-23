//
//  OPML.swift
//  PodcastAISources
//
//  Abos mitnehmen und mitbringen. Fast jede Podcast-App exportiert ihre
//  Abos als OPML: eine XML-Datei, in der je Podcast ein `<outline>` mit
//  der Feed-Adresse in `xmlUrl` steht. Wer mit 20 Abos aus Overcast oder
//  Pocket Casts kommt, soll nicht jedes einzeln suchen müssen.
//
//  Die Datei ist fremde Eingabe. Gelesen werden nur Titel und Adressen,
//  abonniert wird danach über denselben Weg wie ein eingefügter Link, mit
//  derselben Adressprüfung.
//

import Foundation

/// Ein Podcast aus einer OPML-Datei.
public struct OPMLFeed: Sendable, Hashable, Identifiable {
    public let title: String
    public let feedURL: URL
    public let websiteURL: URL?
    public var id: URL { feedURL }

    public init(title: String, feedURL: URL, websiteURL: URL? = nil) {
        self.title = title
        self.feedURL = feedURL
        self.websiteURL = websiteURL
    }
}

public enum OPMLError: Error, LocalizedError, Equatable {
    case notOPML
    case noFeeds
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .notOPML:
            "Diese Datei ist keine OPML-Liste. Exportiere die Abos in deiner bisherigen App als OPML und wähle diese Datei."
        case .noFeeds:
            "In dieser Datei steht kein Podcast-Feed."
        case .tooLarge:
            "Die Datei ist zu groß für eine Abo-Liste."
        }
    }
}

public enum OPML {

    /// Obergrenze für die Datei. Eine Abo-Liste hat wenige Kilobyte, ein
    /// Export mit allen Folgen (Overcast) einige Megabyte.
    public static let maximumBytes = 20 * 1024 * 1024
    /// Obergrenze für Feeds je Datei.
    public static let maximumFeeds = 1_000

    /// Alle Feeds einer OPML-Datei in der Reihenfolge ihres Vorkommens,
    /// jede Adresse nur einmal. Gruppen (verschachtelte `<outline>`) werden
    /// aufgelöst.
    public static func feeds(in data: Data) throws -> [OPMLFeed] {
        guard data.count <= maximumBytes else { throw OPMLError.tooLarge }
        guard !data.isEmpty else { throw OPMLError.notOPML }

        let delegate = OPMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // Keine externen Entitäten, kein Netzwerkzugriff beim Lesen.
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false

        let completed = parser.parse()
        guard delegate.sawRoot else { throw OPMLError.notOPML }
        // Ein Fehler weit hinten in der Datei macht die Feeds davor nicht
        // wertlos.
        if !completed && delegate.feeds.isEmpty { throw OPMLError.notOPML }
        guard !delegate.feeds.isEmpty else { throw OPMLError.noFeeds }
        return delegate.feeds
    }

    /// Schreibt eine OPML-Datei, die andere Podcast-Apps einlesen können.
    public static func document(title: String, feeds: [OPMLFeed], created: Date = Date()) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0">"#,
            "  <head>",
            "    <title>\(escape(title))</title>",
            "    <dateCreated>\(rfc822(created))</dateCreated>",
            "  </head>",
            "  <body>",
        ]
        for feed in feeds {
            var attributes = [
                ("type", "rss"),
                ("text", feed.title),
                ("title", feed.title),
                ("xmlUrl", feed.feedURL.absoluteString),
            ]
            if let site = feed.websiteURL { attributes.append(("htmlUrl", site.absoluteString)) }
            let rendered = attributes.map { "\($0.0)=\"\(escape($0.1))\"" }.joined(separator: " ")
            lines.append("    <outline \(rendered)/>")
        }
        lines += ["  </body>", "</opml>", ""]
        return lines.joined(separator: "\n")
    }

    // MARK: - Hilfen

    /// Abo-Schemata, die für https stehen.
    static let feedSchemes: Set<String> = ["feed", "podcast", "pcast", "itpc"]

    /// Nimmt nur Adressen, die sich abonnieren lassen. `feed://` und
    /// Verwandte werden zu https, damit dieselbe Adresse nicht zweimal
    /// auftaucht.
    static func feedURL(from raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased() else { return nil }
        if feedSchemes.contains(scheme) {
            components.scheme = "https"
        } else if scheme != "http" && scheme != "https" {
            return nil
        }
        guard let url = components.url, url.host?.isEmpty == false else { return nil }
        return url
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\n", "\r", "\t": result += " "
            default:
                // Steuerzeichen sind in XML 1.0 nicht erlaubt.
                if scalar.value >= 0x20 { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }

    static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}

// MARK: - Delegate

private final class OPMLParserDelegate: NSObject, XMLParserDelegate {

    var feeds: [OPMLFeed] = []
    var sawRoot = false
    private var seen = Set<String>()
    private var depth = 0

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1
        let name = elementName.lowercased()
        if depth == 1 {
            // Die Wurzel entscheidet. Ein RSS-Feed oder eine beliebige
            // XML-Datei ist keine Abo-Liste.
            guard name == "opml" else {
                parser.abortParsing()
                return
            }
            sawRoot = true
            return
        }
        guard name == "outline" else { return }

        // Attributnamen ohne Rücksicht auf Groß- und Kleinschreibung:
        // `xmlUrl` ist Standard, `xmlURL` kommt vor.
        var attributes: [String: String] = [:]
        for (key, value) in attributeDict where attributes[key.lowercased()] == nil {
            attributes[key.lowercased()] = value
        }
        guard let feedURL = OPML.feedURL(from: attributes["xmlurl"]),
              seen.insert(feedURL.absoluteString).inserted else { return }

        let title = [attributes["text"], attributes["title"]]
            .compactMap { $0?.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty }
        feeds.append(OPMLFeed(
            title: title ?? feedURL.host ?? feedURL.absoluteString,
            feedURL: feedURL,
            websiteURL: OPML.feedURL(from: attributes["htmlurl"])
        ))
        if feeds.count >= OPML.maximumFeeds { parser.abortParsing() }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        depth -= 1
    }
}
