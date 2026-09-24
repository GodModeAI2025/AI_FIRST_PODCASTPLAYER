//
//  SocialPosts.swift
//  PodcastAISources
//
//  Einzelne Beiträge von TikTok, Instagram, X und Facebook, und was
//  Supadata sonst für YouTube kann: Kanäle suchen und das ganze Archiv
//  eines Kanals oder einer Playlist auflisten.
//
//  Alles davon gibt es nur mit einem eigenen Supadata-Schlüssel. Ein Abo auf
//  ein Profil von TikTok oder Instagram gibt es nicht: Supadata beschreibt
//  keine Profile, und die App liest Profilseiten nicht selbst aus.
//

import Foundation
import PodcastAICore

// MARK: - Links erkennen

public enum SocialPlatform: String, Codable, Sendable, CaseIterable {
    case tikTok
    case instagram
    case x
    case facebook

    /// Der Name, wie ihn die Plattform selbst schreibt.
    public var displayName: String {
        switch self {
        case .tikTok: "TikTok"
        case .instagram: "Instagram"
        case .x: "X"
        case .facebook: "Facebook"
        }
    }
}

public enum SocialLink: Equatable, Sendable {
    /// Ein einzelner Beitrag, etwa ein Video oder Reel.
    case post(SocialPlatform, URL)
    /// Ein Profil. Abonnieren lässt es sich nicht.
    case profile(SocialPlatform, URL)

    public var platform: SocialPlatform {
        switch self {
        case .post(let platform, _), .profile(let platform, _): platform
        }
    }
}

public enum SocialLinks {

    /// Ordnet eine Adresse ein, ohne Netz. `nil` für alles andere.
    public static func classify(_ url: URL) -> SocialLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = url.host()?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasPrefix("m.") { host.removeFirst(2) }
        let path = url.path().split(separator: "/").map(String.init)
        let secure = SafeHTTP.secureVariant(of: url)

        switch host {
        case "tiktok.com":
            // /@name/video/123 · /t/ABC (Kurzlink) · /@name
            if path.count >= 3, path[0].hasPrefix("@"), path[1] == "video" || path[1] == "photo",
               isDigits(path[2]) {
                return .post(.tikTok, secure)
            }
            if path.count >= 2, path[0] == "t", isToken(path[1]) { return .post(.tikTok, secure) }
            if path.count == 1, path[0].hasPrefix("@"), path[0].count > 1 { return .profile(.tikTok, secure) }
            return nil
        case "vm.tiktok.com", "vt.tiktok.com":
            return path.first.map(isToken) == true ? .post(.tikTok, secure) : nil
        case "instagram.com":
            // /reel/ID · /reels/ID · /p/ID · /tv/ID · /name/reel/ID · /name
            if let index = path.firstIndex(where: { ["reel", "reels", "p", "tv"].contains($0) }),
               index + 1 < path.count, isToken(path[index + 1]) {
                return .post(.instagram, secure)
            }
            if path.count == 1, isHandle(path[0]), !instagramReserved.contains(path[0].lowercased()) {
                return .profile(.instagram, secure)
            }
            return nil
        case "x.com", "twitter.com", "mobile.twitter.com":
            // /name/status/123 · /name
            if path.count >= 3, path[1] == "status", isDigits(path[2]) { return .post(.x, secure) }
            if path.count == 1, isHandle(path[0]), !xReserved.contains(path[0].lowercased()) {
                return .profile(.x, secure)
            }
            return nil
        case "facebook.com", "fb.watch":
            if host == "fb.watch" { return path.first.map(isToken) == true ? .post(.facebook, secure) : nil }
            // /watch?v=123 · /name/videos/123 · /reel/123
            if path.first == "watch",
               URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "v" })?.value.map(isDigits) == true {
                return .post(.facebook, secure)
            }
            if path.count >= 3, path[1] == "videos", isDigits(path[2]) { return .post(.facebook, secure) }
            if path.count >= 2, path[0] == "reel", isDigits(path[1]) { return .post(.facebook, secure) }
            if path.count == 1, isHandle(path[0]), !facebookReserved.contains(path[0].lowercased()) {
                return .profile(.facebook, secure)
            }
            return nil
        default:
            return nil
        }
    }

    private static let instagramReserved: Set<String> = ["explore", "accounts", "direct", "stories", "reels", "about"]
    private static let xReserved: Set<String> = ["home", "explore", "search", "i", "settings", "notifications", "messages"]
    private static let facebookReserved: Set<String> = ["watch", "reel", "groups", "events", "marketplace", "login"]

    static func isDigits(_ text: String) -> Bool { !text.isEmpty && text.count <= 30 && text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber) }

    static func isToken(_ text: String) -> Bool {
        (1...64).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    static func isHandle(_ text: String) -> Bool {
        (1...64).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }
    }
}

// MARK: - YouTube über Supadata

/// Ein Kanal aus der YouTube-Suche über Supadata.
public struct SupadataChannel: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let handle: String?
    public let description: String?
    public let thumbnailURL: URL?
    public let videoCount: Int?

    /// Der Atom-Feed des Kanals, wie beim Abo über einen Link.
    public var feedURL: URL? { SourceResolver.channelFeedURL(channelID: id) }
}

/// Kennungen der Videos eines Kanals oder einer Playlist.
public struct SupadataVideoList: Hashable, Sendable {
    public let videoIDs: [String]
    public let shortIDs: [String]
    public let liveIDs: [String]

    /// Alle Kennungen ohne Doppelte, in der Reihenfolge der Antwort.
    public var all: [String] {
        var seen: Set<String> = []
        return (videoIDs + liveIDs + shortIDs).filter { seen.insert($0).inserted }
    }
}

extension SupadataDecoding {

    private struct SearchBody: Decodable {
        struct Result: Decodable {
            struct Thumbnail: Decodable { let url: String? }
            let type: String?
            let id: String?
            let title: String?
            let description: String?
            let handle: String?
            let videoCount: Int?
            let thumbnail: ThumbnailField?
        }
        /// `thumbnail` ist mal eine Adresse, mal ein Objekt mit `url`.
        enum ThumbnailField: Decodable {
            case url(String)
            case object(String?)
            var value: String? {
                switch self { case .url(let value): value; case .object(let value): value }
            }
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) { self = .url(text); return }
                self = .object(try container.decode(Result.Thumbnail.self).url)
            }
        }
        let results: [Result]?
    }

    /// Antwort von `GET /v1/youtube/search`. Nur Kanäle mit gültiger Kennung.
    public static func channels(from data: Data) throws(SupadataError) -> [SupadataChannel] {
        guard let body = try? JSONDecoder().decode(SearchBody.self, from: data) else { throw .decoding }
        return (body.results ?? []).compactMap { result in
            guard result.type == nil || result.type == "channel",
                  let id = result.id, SourceResolver.isValidChannelID(id),
                  let title = SupadataText.plain(result.title, limit: 200) else { return nil }
            var thumbnail = result.thumbnail?.value
            if thumbnail?.hasPrefix("//") == true { thumbnail = "https:" + thumbnail! }
            return SupadataChannel(
                id: id, title: title, handle: SupadataText.plain(result.handle, limit: 100),
                description: SupadataText.plain(result.description, limit: 1_000),
                thumbnailURL: SupadataText.secureURL(thumbnail), videoCount: result.videoCount)
        }
    }

    private struct VideoListBody: Decodable {
        let videoIds: [String]?
        let shortIds: [String]?
        let liveIds: [String]?
    }

    /// Antwort von `GET /v1/youtube/channel/videos` und `…/playlist/videos`.
    public static func videoList(from data: Data) throws(SupadataError) -> SupadataVideoList {
        guard let body = try? JSONDecoder().decode(VideoListBody.self, from: data) else { throw .decoding }
        let valid = { (ids: [String]?) in (ids ?? []).filter(SourceResolver.isValidVideoID) }
        return SupadataVideoList(videoIDs: valid(body.videoIds), shortIDs: valid(body.shortIds),
                                 liveIDs: valid(body.liveIds))
    }
}

extension SupadataTranscriptClient {

    /// Sucht YouTube-Kanäle nach Namen. Eine Anfrage, kostet bei Supadata.
    public func searchChannels(_ query: String, apiKey: String, limit: Int = 8) async throws(SupadataError) -> [SupadataChannel] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let data = try await get(path: ["youtube", "search"], query: [
            URLQueryItem(name: "query", value: String(term.prefix(200))),
            URLQueryItem(name: "type", value: "channel"),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 50)))),
        ], apiKey: apiKey)
        return try SupadataDecoding.channels(from: data)
    }

    /// Die Videos eines Kanals, über das Fenster des Feeds hinaus.
    public func channelVideos(channelID: String, apiKey: String, limit: Int = 100) async throws(SupadataError) -> SupadataVideoList {
        guard SourceResolver.isValidChannelID(channelID) else { throw .invalidRequest }
        let data = try await get(path: ["youtube", "channel", "videos"], query: [
            URLQueryItem(name: "id", value: channelID),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 5_000)))),
        ], apiKey: apiKey)
        return try SupadataDecoding.videoList(from: data)
    }

    /// Die Videos einer Playlist.
    public func playlistVideos(playlistID: String, apiKey: String, limit: Int = 100) async throws(SupadataError) -> SupadataVideoList {
        guard SocialLinks.isToken(playlistID) else { throw .invalidRequest }
        let data = try await get(path: ["youtube", "playlist", "videos"], query: [
            URLQueryItem(name: "id", value: playlistID),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 5_000)))),
        ], apiKey: apiKey)
        return try SupadataDecoding.videoList(from: data)
    }

    /// Eine GET-Anfrage mit den üblichen Regeln; liefert den Inhalt bei 200.
    func get(path: [String], query: [URLQueryItem], apiKey: String) async throws(SupadataError) -> Data {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw .missingKey }
        let base = path.reduce(configuration.baseURL) { $0.appending(path: $1) }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw .invalidRequest }
        components.queryItems = query
        guard let url = components.url else { throw .invalidRequest }
        let response = try await sendRequest(url, apiKey: key)
        guard response.status == 200 else {
            throw SupadataDecoding.error(status: response.status, body: response.body, retryAfter: response.retryAfter)
        }
        return response.body
    }
}
