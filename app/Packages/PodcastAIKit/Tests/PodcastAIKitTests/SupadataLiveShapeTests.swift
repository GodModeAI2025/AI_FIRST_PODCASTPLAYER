//
//  SupadataLiveShapeTests.swift
//  PodcastAIKitTests
//
//  Antworten, wie Supadata sie am 24. September 2026 tatsächlich geliefert
//  hat (live abgefragt, gekürzt nur wo „...“ steht). Die Decoder müssen
//  genau diese Formen lesen. Kein Test geht ins Netz.
//

import Foundation
import Testing
import PodcastAIKit
@testable import PodcastAISources

@Suite("Supadata: echte Antworten")
struct SupadataLiveShapeTests {

    @Test("GET /v1/me")
    func me() async throws {
        let body = #"{"organizationId":"...","plan":"Mega","maxCredits":30000,"usedCredits":213}"#
        let client = SupadataTranscriptClient(
            transport: { _, _ in SupadataHTTPResponse(status: 200, body: Data(body.utf8)) },
            sleep: { _ in }, random: { 1 })
        let account = try await client.account(apiKey: "k")
        #expect(account.plan == "Mega")
        #expect(account.maxCredits == 30_000)
        #expect(account.usedCredits == 213)
        #expect(!account.isExhausted)
    }

    @Test("GET /v1/metadata für ein YouTube-Video: Autor nur mit displayName, Länge in Sekunden")
    func metadata() throws {
        let body = """
            {"platform":"youtube","type":"video","id":"dQw4w9WgXcQ","url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ",
             "title":"...","description":"...","author":{"displayName":"Rick Astley"},
             "stats":{"views":1819325203,"likes":19407664,"comments":null,"shares":null},
             "media":{"type":"video","duration":213,"thumbnailUrl":"https://i.ytimg.com/vi_webp/.../maxresdefault.webp"},
             "tags":["rick astley","never gonna give you up"],"createdAt":"2009-10-24T00:00:00.000Z",
             "additionalData":{"channelId":"UCuAXFkgsw1L7xaCfnd5JJOw"}}
            """
        let metadata = try SupadataDecoding.metadata(from: Data(body.utf8))
        #expect(metadata.platform == "youtube")
        #expect(metadata.videoID == "dQw4w9WgXcQ")
        #expect(metadata.url?.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(metadata.authorName == "Rick Astley")
        #expect(metadata.authorUsername == nil)
        #expect(metadata.authorAvatarURL == nil)
        #expect(metadata.duration?.milliseconds == 213_000)
        #expect(metadata.thumbnailURL?.host() == "i.ytimg.com")
        #expect(metadata.tags == ["rick astley", "never gonna give you up"])
        #expect(metadata.channelID == "UCuAXFkgsw1L7xaCfnd5JJOw")
        let expected = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2009-10-24T00:00:00.000Z")
        #expect(metadata.createdAt == expected)
    }

    @Test("GET /v1/youtube/channel/videos")
    func channelVideos() throws {
        let body = #"{"videoIds":["PXC_PYeB6F8","LaOUkDBDjW8","wvr7-pDJUOA"],"shortIds":[],"liveIds":[]}"#
        let list = try SupadataDecoding.videoList(from: Data(body.utf8))
        #expect(list.all == ["PXC_PYeB6F8", "LaOUkDBDjW8", "wvr7-pDJUOA"])
    }

    @Test("GET /v1/youtube/search mit type=channel: nur Titel, Bild und Handle")
    func channelSearch() throws {
        let body = """
            {"query":"heise online","results":[
              {"type":"channel","id":"UCo2aQmvWjo91O8usRBHFZJw","title":"heise online News",
               "thumbnail":"https://yt3.ggpht.com/...","handle":"@heiseonlineNews"}
            ]}
            """
        let channels = try SupadataDecoding.channels(from: Data(body.utf8))
        #expect(channels.count == 1)
        #expect(channels.first?.id == "UCo2aQmvWjo91O8usRBHFZJw")
        #expect(channels.first?.title == "heise online News")
        #expect(channels.first?.handle == "@heiseonlineNews")
        #expect(channels.first?.thumbnailURL?.host() == "yt3.ggpht.com")
        #expect(channels.first?.videoCount == nil)
    }

    @Test("GET /v1/transcript mit mode=native")
    func transcript() throws {
        let body = """
            {"lang":"en","availableLangs":["en","de"],"content":[{"lang":"en","text":"...","offset":18640,"duration":3240}]}
            """
        let transcript = try SupadataDecoding.transcript(from: Data(body.utf8))
        #expect(transcript.lang == "en")
        #expect(transcript.captions.first?.offsetMilliseconds == 18_640)
        #expect(transcript.captions.first?.durationMilliseconds == 3_240)
    }

    @Test("Profil-Adresse bei /v1/metadata: 400 invalid-request")
    func profileRejected() {
        let error = SupadataDecoding.error(status: 400, body: Data(#"{"error":"invalid-request","message":"..."}"#.utf8),
                                           retryAfter: nil)
        #expect(error == .invalidRequest)
        #expect(!error.isTransient)
    }
}
