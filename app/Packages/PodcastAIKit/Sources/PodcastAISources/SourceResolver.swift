//
//  SourceResolver.swift
//  PodcastAISources
//
//  Ein einziger eingefügter Link soll genügen. Der Nutzer muss keinen Feed
//  heraussuchen und nicht wissen, ob etwas ein Kanal, ein Video oder eine
//  einzelne Folge ist.
//
//  Die Auflösung bleibt dabei ehrlich: erkannt heißt nicht zugänglich.
//  Ein YouTube-Kanalfeed liefert Metadaten — daraus folgt kein Audiozugriff.
//

import Foundation
import PodcastAICore

/// Was hinter einem eingefügten Link steckt.
public enum ResolvedLink: Sendable, Equatable {
    /// Direkt ein Podcast-Feed.
    case podcastFeed(URL)
    /// Ein YouTube-Kanal, aufgelöst auf seinen Atom-Feed.
    case youTubeChannel(channelID: String, feedURL: URL)
    /// Ein einzelnes YouTube-Video. Der Kanal folgt erst nach einem Abruf.
    ///
    /// `startTime` trägt einen im Link enthaltenen Zeitstempel (`?t=1m23s`).
    /// Er ist ein **Vorschlag aus dem Link**, keine Freigabe: Wiedergabe
    /// startet weiterhin nur nach ausdrücklicher Nutzeraktion.
    case youTubeVideo(videoID: String, watchURL: URL, startTime: MediaTime?)
    /// Eine YouTube-Playlist.
    case youTubePlaylist(playlistID: String, url: URL)
    /// Ein YouTube-Kanal über seinen Namen (`/@name`, `/c/name`, `/user/name`).
    /// Die Kanalkennung steht nicht im Link, sie steht auf der Kanalseite.
    case youTubeChannelPage(handle: String, pageURL: URL)
    /// Eine Webseite, hinter der ein Feed vermutet wird — muss abgerufen werden.
    case webPageNeedingDiscovery(URL)
    /// Eine lokale Datei.
    case localFile(URL)
    /// Eine einzelne Audiodatei im Netz, etwa der Download-Link einer Folge.
    case audioFile(URL)

    public var requiresNetworkDiscovery: Bool {
        switch self {
        case .webPageNeedingDiscovery, .youTubeVideo, .youTubePlaylist, .youTubeChannelPage: true
        default: false
        }
    }
}

public enum SourceResolutionError: Error, LocalizedError, Equatable {
    case unsupportedScheme(String)
    case notAURL

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme):
            "Links vom Typ „\(scheme)“ können nicht aufgenommen werden."
        case .notAURL:
            "Das ist keine gültige Adresse."
        }
    }
}

public struct SourceResolver: Sendable {

    public init() {}

    /// Klassifiziert eine Eingabe, ohne das Netzwerk zu berühren.
    ///
    /// Bewusst netzfrei: der erste Schritt muss auch offline funktionieren und
    /// darf keinen Abruf auslösen, nur weil jemand etwas eingefügt hat.
    public func resolve(_ input: String) throws -> ResolvedLink {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SourceResolutionError.notAURL }

        // `feed://` und `podcast://` sind verbreitete Abo-Schemata für https.
        let normalized = Self.normalizeScheme(trimmed)
        guard let url = URL(string: normalized), let scheme = url.scheme?.lowercased() else {
            throw SourceResolutionError.notAURL
        }

        if scheme == "file" { return .localFile(url) }
        guard scheme == "http" || scheme == "https" else {
            throw SourceResolutionError.unsupportedScheme(scheme)
        }

        if let youTube = try Self.resolveYouTube(url) { return youTube }
        if Self.looksLikeAudioURL(url) { return .audioFile(url) }
        if Self.looksLikeFeedURL(url) { return .podcastFeed(url) }
        return .webPageNeedingDiscovery(url)
    }

    // MARK: - YouTube

    static let youTubeHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com",
        "music.youtube.com", "youtu.be", "www.youtu.be",
    ]

    /// Baut die offizielle Atom-Feed-Adresse eines Kanals.
    public static func channelFeedURL(channelID: String) -> URL? {
        URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)")
    }

    public static func watchURL(videoID: String) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)")
    }

    private static func resolveYouTube(_ url: URL) throws -> ResolvedLink? {
        guard let host = url.host?.lowercased(), youTubeHosts.contains(host) else { return nil }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = url.path
        let segments = path.split(separator: "/").map(String.init)

        // Bereits ein Feed-Link.
        if path.hasPrefix("/feeds/videos.xml") {
            if let channelID = components?.queryItems?.first(where: { $0.name == "channel_id" })?.value,
               isValidChannelID(channelID), let feedURL = channelFeedURL(channelID: channelID) {
                return .youTubeChannel(channelID: channelID, feedURL: feedURL)
            }
            return .podcastFeed(url)
        }

        let start = timestamp(in: components)

        // Kurzlink youtu.be/<id>
        if host.hasSuffix("youtu.be"), let first = segments.first, isValidVideoID(first) {
            return .youTubeVideo(videoID: first, watchURL: watchURL(videoID: first) ?? url, startTime: start)
        }

        // /watch?v=<id>
        if path == "/watch",
           let videoID = components?.queryItems?.first(where: { $0.name == "v" })?.value,
           isValidVideoID(videoID) {
            return .youTubeVideo(videoID: videoID, watchURL: watchURL(videoID: videoID) ?? url, startTime: start)
        }

        // /shorts/<id>, /live/<id>, /embed/<id>
        if segments.count >= 2, ["shorts", "live", "embed", "v"].contains(segments[0]),
           isValidVideoID(segments[1]) {
            return .youTubeVideo(videoID: segments[1],
                                 watchURL: watchURL(videoID: segments[1]) ?? url,
                                 startTime: start)
        }

        // /playlist?list=<id>
        if path == "/playlist",
           let listID = components?.queryItems?.first(where: { $0.name == "list" })?.value,
           isValidPlaylistID(listID) {
            return .youTubePlaylist(playlistID: listID, url: url)
        }

        // /channel/<UC...> — direkt auflösbar.
        if segments.count >= 2, segments[0] == "channel", isValidChannelID(segments[1]),
           let feedURL = channelFeedURL(channelID: segments[1]) {
            return .youTubeChannel(channelID: segments[1], feedURL: feedURL)
        }

        // /@handle, /c/<name>, /user/<name> — die Kanalkennung steht nicht im
        // Link. Sie wird über einen regulären Abruf der Kanalseite ermittelt,
        // nicht über einen fremden Auflösungsdienst.
        if let first = segments.first, first.hasPrefix("@"), isValidHandle(first.dropFirst()),
           let page = channelPageURL(path: [first]) {
            return .youTubeChannelPage(handle: first, pageURL: page)
        }
        if segments.count >= 2, ["c", "user"].contains(segments[0]), isValidHandle(segments[1][...]),
           let page = channelPageURL(path: [segments[0], segments[1]]) {
            return .youTubeChannelPage(handle: segments[1], pageURL: page)
        }

        return .webPageNeedingDiscovery(url)
    }

    /// Die Kanalseite ohne Anhängsel. Geteilte Links tragen `?si=…` oder
    /// `?feature=…` und oft einen Reiter wie `/videos`; abgerufen wird nur
    /// die Seite des Kanals selbst.
    static func channelPageURL(path: [String]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/" + path.joined(separator: "/")
        return components.url
    }

    /// Kanalnamen bestehen aus Buchstaben, Ziffern, `_`, `-` und `.`.
    static func isValidHandle(_ name: Substring) -> Bool {
        (1...100).contains(name.count)
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    /// Kanalkennungen beginnen mit `UC` und sind 24 Zeichen lang.
    public static func isValidChannelID(_ id: String) -> Bool {
        id.count == 24 && id.hasPrefix("UC")
            && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// Videokennungen sind 11 Zeichen aus dem URL-sicheren Alphabet.
    public static func isValidVideoID(_ id: String) -> Bool {
        id.count == 11
            && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// Playlist-Kennungen sind kürzer und weniger streng genormt; geprüft wird
    /// das Alphabet und eine plausible Länge.
    public static func isValidPlaylistID(_ id: String) -> Bool {
        (2...64).contains(id.count)
            && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// Liest `?t=` bzw. `?start=` in den Formen `83`, `83s`, `1m23s`, `1h2m3s`.
    ///
    /// Ein unverständlicher Wert ergibt `nil` statt einer geratenen Zahl —
    /// ein falscher Startpunkt ist schlimmer als gar keiner.
    static func timestamp(in components: URLComponents?) -> MediaTime? {
        guard let raw = components?.queryItems?
            .first(where: { $0.name == "t" || $0.name == "start" })?.value?
            .trimmingCharacters(in: .whitespaces).lowercased(),
              !raw.isEmpty else { return nil }

        // Reine Sekundenzahl.
        if raw.allSatisfy(\.isNumber), let seconds = Int(raw) {
            return MediaTime(milliseconds: Int64(seconds) * 1000)
        }

        var total = 0
        var digits = ""
        var sawUnit = false
        for character in raw {
            if character.isNumber {
                digits.append(character)
                continue
            }
            guard let value = Int(digits) else { return nil }
            switch character {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
            digits = ""
            sawUnit = true
        }
        // Ein Rest ohne Einheit ist mehrdeutig.
        guard digits.isEmpty, sawUnit else { return nil }
        return MediaTime(milliseconds: Int64(total) * 1000)
    }

    // MARK: - Heuristik

    private static func normalizeScheme(_ input: String) -> String {
        for prefix in ["feed://", "podcast://", "pcast://", "itpc://"] {
            if input.lowercased().hasPrefix(prefix) {
                return "https://" + input.dropFirst(prefix.count)
            }
        }
        if !input.contains("://"), input.contains(".") , !input.hasPrefix("/") {
            return "https://" + input
        }
        return input
    }

    /// Reine Formheuristik. Ein Treffer heißt „wahrscheinlich ein Feed“,
    /// kein Treffer heißt nur, dass erst abgerufen werden muss.
    /// Endet der Pfad auf eine Audio-Endung, ist es eine Folge, kein Feed.
    /// Die Abfrage nach dem Fragezeichen zählt nicht: Hoster hängen dort
    /// gern Zähler an (`?source=webplayer-download`).
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "ogg", "oga", "opus", "flac", "mp4"]

    public static func looksLikeAudioURL(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    private static func looksLikeFeedURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let suffixes = [".xml", ".rss", ".atom"]
        if suffixes.contains(where: path.hasSuffix) { return true }
        let markers = ["/feed", "/rss", "/podcast.xml", "/feed.xml", "/atom"]
        return markers.contains(where: path.contains)
    }
}
