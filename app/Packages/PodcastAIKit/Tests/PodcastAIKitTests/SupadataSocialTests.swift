//
//  SupadataSocialTests.swift
//  PodcastAIKitTests
//
//  Beiträge von TikTok, Instagram, X und Facebook erkennen, Profile
//  ablehnen, und die YouTube-Endpunkte von Supadata lesen: Kanalsuche und
//  die Videos eines Kanals oder einer Playlist. Ohne Netz.
//

import Foundation
import Synchronization
import Testing
import PodcastAIKit
@testable import PodcastAISources

private final class RecordingTransport: Sendable {
    private let responses: Mutex<[SupadataHTTPResponse]>
    private let seen = Mutex<[URL]>([])
    init(_ responses: [(Int, String)]) {
        self.responses = Mutex(responses.map { SupadataHTTPResponse(status: $0.0, body: Data($0.1.utf8)) })
    }
    var urls: [URL] { seen.withLock { $0 } }
    func client() -> SupadataTranscriptClient {
        SupadataTranscriptClient(
            transport: { [self] url, _ in
                seen.withLock { $0.append(url) }
                return responses.withLock { $0.isEmpty ? SupadataHTTPResponse(status: 500, body: Data()) : $0.removeFirst() }
            },
            sleep: { _ in }, random: { 1 })
    }
}

@Suite("Beiträge aus sozialen Netzen erkennen")
struct SocialLinkTests {

    private func classify(_ text: String) -> SocialLink? { SocialLinks.classify(URL(string: text)!) }

    @Test("Einzelne Beiträge in allen Formen")
    func recognizesPosts() {
        let posts = [
            ("https://www.tiktok.com/@imkerei/video/7301234567890123456?is_from_webapp=1", SocialPlatform.tikTok),
            ("https://m.tiktok.com/@imkerei/video/7301234567890123456", .tikTok),
            ("https://vm.tiktok.com/ZMabc123/", .tikTok),
            ("https://vt.tiktok.com/ZSxyz789/", .tikTok),
            ("https://www.tiktok.com/t/ZT8abc/", .tikTok),
            ("https://www.instagram.com/reel/C1a2B3c4D5e/", .instagram),
            ("https://instagram.com/reels/C1a2B3c4D5e", .instagram),
            ("https://www.instagram.com/p/C1a2B3c4D5e/?igsh=abc", .instagram),
            ("https://www.instagram.com/tv/C1a2B3c4D5e/", .instagram),
            ("https://www.instagram.com/imkerei/reel/C1a2B3c4D5e/", .instagram),
            ("https://x.com/imkerei/status/1834567890123456789", .x),
            ("https://twitter.com/imkerei/status/1834567890123456789?s=20", .x),
            ("https://www.facebook.com/watch?v=123456789012345", .facebook),
            ("https://www.facebook.com/imkerei/videos/123456789012345/", .facebook),
            ("https://www.facebook.com/reel/123456789012345", .facebook),
            ("https://fb.watch/abcDEF123/", .facebook),
        ]
        for (text, platform) in posts {
            guard case .post(let found, let url)? = classify(text) else {
                Issue.record("kein Beitrag: \(text)")
                continue
            }
            #expect(found == platform)
            #expect(url.scheme == "https")
        }
    }

    @Test("Profile werden erkannt, damit die App sie ablehnen kann")
    func recognizesProfiles() {
        #expect(classify("https://www.tiktok.com/@imkerei") == .profile(.tikTok, URL(string: "https://www.tiktok.com/@imkerei")!))
        #expect(classify("https://www.instagram.com/imkerei/")?.platform == .instagram)
        if case .profile? = classify("https://www.instagram.com/imkerei/") {} else { Issue.record("Instagram-Profil") }
        if case .profile? = classify("https://x.com/imkerei") {} else { Issue.record("X-Profil") }
    }

    @Test("Anderes bleibt unberührt")
    func ignoresOthers() {
        #expect(classify("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(classify("https://example.com/@name/video/123") == nil)
        #expect(classify("https://www.instagram.com/explore/") == nil)
        #expect(classify("https://x.com/home") == nil)
        #expect(classify("ftp://tiktok.com/@a/video/1") == nil)
    }
}

@Suite("Supadata: YouTube-Suche und Archiv")
struct SupadataYouTubeListTests {

    @Test("Kanalsuche: nur Kanäle mit gültiger Kennung, Vorschaubild nur https")
    func decodesChannelSearch() throws {
        let body = """
            {"query":"imkerei","totalResults":3,"results":[
              {"type":"channel","id":"UCabcdefghijklmnopqrstuv","title":"Die Imkerei","handle":"@imkerei",
               "description":"Bienen","thumbnail":"//yt3.ggpht.com/a.jpg","videoCount":120},
              {"type":"video","id":"dQw4w9WgXcQ","title":"Ein Video"},
              {"type":"channel","id":"kaputt","title":"Ohne Kennung"}
            ]}
            """
        let channels = try SupadataDecoding.channels(from: Data(body.utf8))
        #expect(channels.count == 1)
        #expect(channels.first?.title == "Die Imkerei")
        #expect(channels.first?.thumbnailURL?.absoluteString == "https://yt3.ggpht.com/a.jpg")
        #expect(channels.first?.feedURL?.absoluteString
                == "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv")
    }

    @Test("Videos eines Kanals: Kennungen geprüft, ohne Doppelte")
    func decodesVideoList() throws {
        let list = try SupadataDecoding.videoList(from: Data(
            #"{"videoIds":["dQw4w9WgXcQ","kaputt","aaaaaaaaaaa"],"shortIds":["bbbbbbbbbbb","dQw4w9WgXcQ"],"liveIds":[]}"#.utf8))
        #expect(list.videoIDs == ["dQw4w9WgXcQ", "aaaaaaaaaaa"])
        #expect(list.all == ["dQw4w9WgXcQ", "aaaaaaaaaaa", "bbbbbbbbbbb"])
    }

    @Test("Anfragen an die richtigen Pfade, mit Kennung als Parameter")
    func requestPaths() async throws {
        let transport = RecordingTransport([
            (200, #"{"results":[]}"#),
            (200, #"{"videoIds":[],"shortIds":[],"liveIds":[]}"#),
            (200, #"{"videoIds":[],"shortIds":[],"liveIds":[]}"#),
        ])
        let client = transport.client()
        _ = try await client.searchChannels("Imkerei", apiKey: "k")
        _ = try await client.channelVideos(channelID: "UCabcdefghijklmnopqrstuv", apiKey: "k")
        _ = try await client.playlistVideos(playlistID: "PLabc123", apiKey: "k")
        #expect(transport.urls.map { $0.path() } == ["/v1/youtube/search", "/v1/youtube/channel/videos",
                                                     "/v1/youtube/playlist/videos"])
        let search = URLComponents(url: transport.urls[0], resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(search.contains(URLQueryItem(name: "type", value: "channel")))
        await #expect(throws: SupadataError.invalidRequest) {
            try await client.channelVideos(channelID: "kein-kanal", apiKey: "k")
        }
    }

    @Test("Ältere Videos bekommen dieselbe Kennung wie aus dem Feed: yt:video:<id>")
    func feedGuidMatchesBackCatalogKey() throws {
        let atom = """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">
              <title>Die Imkerei</title>
              <entry>
                <id>yt:video:dQw4w9WgXcQ</id>
                <yt:videoId>dQw4w9WgXcQ</yt:videoId>
                <title>Bienen im Winter</title>
                <link rel="alternate" href="https://www.youtube.com/watch?v=dQw4w9WgXcQ"/>
                <published>2026-09-20T08:00:00+00:00</published>
              </entry>
            </feed>
            """
        let feed = try FeedParser().parse(Data(atom.utf8))
        #expect(feed.items.first?.guid == "yt:video:dQw4w9WgXcQ")
    }

    @Test("Profil-Adresse bei /metadata: 400 wird zu einer ungültigen Anfrage, ohne Wiederholung")
    func profileMetadataRejected() async {
        let transport = RecordingTransport([(400, #"{"error":"invalid-request"}"#)])
        await #expect(throws: SupadataError.invalidRequest) {
            try await transport.client().metadata(for: URL(string: "https://www.tiktok.com/@imkerei")!, apiKey: "k")
        }
        #expect(transport.urls.count == 1)
    }
}
