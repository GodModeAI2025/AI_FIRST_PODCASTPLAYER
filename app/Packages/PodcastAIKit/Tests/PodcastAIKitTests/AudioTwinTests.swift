//
//  AudioTwinTests.swift
//  PodcastAIKitTests
//
//  Untertitel des YouTube-Zwillings für eine Audiofolge: den Zwilling
//  finden (abonnierter Kanal, Suche), die Wartezeit nach einer Suche, die
//  Reihenfolge der Schritte, der Abgleich der Zeiten mit dem Ton und die
//  Lage des Tons in einer MP3-Datei. Kein Test geht ins Netz, keiner
//  braucht Spracherkennung.
//

import Foundation
import Synchronization
import Testing
import PodcastAIKit
@testable import PodcastAISources
@testable import PodcastAITranscription
@testable import PodcastAIMedia

private let now = Date(timeIntervalSince1970: 1_790_140_000)
private let day: TimeInterval = 24 * 3600

private func audioEpisode(_ title: String, published: Date? = now, minutes: Int? = 62) -> Episode {
    Episode(id: EpisodeID(rawValue: "audio"), sourceID: SourceID(rawValue: "podcast"), title: title,
            publishedAt: published, declaredDuration: minutes.map { MediaDuration(minutes: $0) },
            audioURL: URL(string: "https://example.com/folge.mp3"))
}

private func video(_ id: String, _ title: String, published: Date?, minutes: Int? = nil) -> Episode {
    Episode(id: EpisodeID(rawValue: id), sourceID: SourceID(rawValue: "channel"), title: title,
            publishedAt: published, declaredDuration: minutes.map { MediaDuration(minutes: $0) },
            webPageURL: URL(string: "https://www.youtube.com/watch?v=\(id)"))
}

// MARK: - Den Zwilling finden

@Suite("YouTube-Zwilling einer Audiofolge")
struct AudioTwinMatchingTests {

    @Test("Aus einem abonnierten Kanal: Titel ohne Podcastnamen, Datum und Länge")
    func fromSubscribedChannel() {
        let episode = audioEpisode("#87 Bienen im Winter")
        let videos = [
            video("aaaaaaaaaaa", "Bienen im Winter | Imkerfunk #87", published: now.addingTimeInterval(day), minutes: 60),
            video("bbbbbbbbbbb", "Bienen im Winter | Imkerfunk #87", published: now.addingTimeInterval(5 * day)),
            video("ccccccccccc", "Etwas ganz anderes", published: now),
        ]
        let match = AudioTwinMatcher.fromChannel(episode: episode, videos: videos, ignoring: ["Imkerfunk"])
        #expect(match?.id.rawValue == "aaaaaaaaaaa")

        // Ein Ausschnitt von acht Minuten ist nicht die Folge.
        let clip = [video("ddddddddddd", "Bienen im Winter | Imkerfunk #87", published: now, minutes: 8)]
        #expect(AudioTwinMatcher.fromChannel(episode: episode, videos: clip, ignoring: ["Imkerfunk"]) == nil)
        // Zu weit auseinander erschienen.
        let late = [video("eeeeeeeeeee", "#87 Bienen im Winter", published: now.addingTimeInterval(4 * day))]
        #expect(AudioTwinMatcher.fromChannel(episode: episode, videos: late, ignoring: []) == nil)
    }

    /// Die Form folgt der OpenAPI-Beschreibung von Supadata
    /// (docs.supadata.ai, `GET /youtube/search`), nicht einem Live-Abruf.
    private let searchBody = """
        {"query":"Imkerfunk Bienen im Winter","results":[
          {"type":"video","id":"aaaaaaaaaaa","title":"Bienen im Winter | Imkerfunk #87","description":"...",
           "thumbnail":"https://i.ytimg.com/vi/aaaaaaaaaaa/hqdefault.jpg","duration":3700,"viewCount":1200,
           "uploadDate":"2026-09-24T10:00:00.000Z","channel":{"id":"UCuAXFkgsw1L7xaCfnd5JJOw","name":"Imkerfunk"}},
          {"type":"video","id":"bbbbbbbbbbb","title":"Bienen im Winter in 5 Minuten","duration":300,
           "uploadDate":"2026-09-24T10:00:00.000Z","channel":{"id":"UCo2aQmvWjo91O8usRBHFZJw","name":"Garten TV"}},
          {"type":"channel","id":"UCo2aQmvWjo91O8usRBHFZJw","title":"Garten TV"},
          {"type":"video","id":"kaputt","title":"ungültige Kennung"}
        ],"totalResults":3}
        """

    @Test("Suchergebnisse lesen: nur Videos mit gültiger Kennung, Länge, Datum, Kanal")
    func decodesVideoSearch() throws {
        let results = try SupadataDecoding.videos(from: Data(searchBody.utf8))
        #expect(results.map(\.id) == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        #expect(results[0].duration?.milliseconds == 3_700_000)
        #expect(results[0].channelID == "UCuAXFkgsw1L7xaCfnd5JJOw")
        #expect(results[0].channelName == "Imkerfunk")
        #expect(results[0].uploadDate != nil)
        #expect(results[0].watchURL?.absoluteString == "https://www.youtube.com/watch?v=aaaaaaaaaaa")
    }

    @Test("Die Suche fragt eine Seite Videos, ohne limit")
    func searchRequestShape() async throws {
        let seen = Mutex<[URL]>([])
        let body = searchBody
        let client = SupadataTranscriptClient(
            transport: { url, _ in
                seen.withLock { $0.append(url) }
                return SupadataHTTPResponse(status: 200, body: Data(body.utf8))
            }, sleep: { _ in }, random: { 1 })
        let results = try await client.searchVideos("Imkerfunk Bienen im Winter", apiKey: "k")
        #expect(results.count == 2)
        let url = try #require(seen.withLock { $0.first })
        #expect(url.path() == "/v1/youtube/search")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "type" }?.value == "video")
        #expect(items.first { $0.name == "query" }?.value == "Imkerfunk Bienen im Winter")
        #expect(!items.contains { $0.name == "limit" })
    }

    @Test("Suchtreffer: der Kanal des Podcasts gewinnt, Ausschnitte und fremde Kopien nicht")
    func matchesSearchResults() throws {
        let results = try SupadataDecoding.videos(from: Data(searchBody.utf8))
        let uploaded = try #require(results[0].uploadDate)
        let episode = audioEpisode("#87 Bienen im Winter", published: uploaded.addingTimeInterval(-3600))
        let match = AudioTwinMatcher.fromSearch(episode: episode, podcastTitle: "Imkerfunk", podcastAuthor: nil,
                                                results: results, preferredChannelID: nil)
        #expect(match?.id == "aaaaaaaaaaa")

        // Ohne den Kanal des Podcasts bleibt nur der Ausschnitt: abgelehnt.
        #expect(AudioTwinMatcher.fromSearch(episode: episode, podcastTitle: "Imkerfunk", podcastAuthor: nil,
                                            results: [results[1]], preferredChannelID: nil) == nil)

        // Ein fremder Kanal mit gleichem Titel, aber anderem Datum: abgelehnt.
        let copy = SupadataVideoResult(id: "ccccccccccc", title: "#87 Bienen im Winter",
                                       duration: MediaDuration(minutes: 62),
                                       uploadDate: uploaded.addingTimeInterval(20 * day),
                                       channelID: "UCo2aQmvWjo91O8usRBHFZJw", channelName: "Reuploads")
        #expect(AudioTwinMatcher.fromSearch(episode: episode, podcastTitle: "Imkerfunk", podcastAuthor: nil,
                                            results: [copy], preferredChannelID: nil) == nil)

        // Der gemerkte Kanal gilt als vertraut, auch wenn er anders heißt.
        let renamed = SupadataVideoResult(id: "ddddddddddd", title: "Bienen im Winter (Folge 87)",
                                          duration: nil, uploadDate: uploaded,
                                          channelID: "UCo2aQmvWjo91O8usRBHFZJw", channelName: "Studio Nord")
        #expect(AudioTwinMatcher.fromSearch(episode: episode, podcastTitle: "Imkerfunk", podcastAuthor: nil,
                                            results: [renamed], preferredChannelID: nil) == nil)
        #expect(AudioTwinMatcher.fromSearch(episode: episode, podcastTitle: "Imkerfunk", podcastAuthor: nil,
                                            results: [renamed], preferredChannelID: "UCo2aQmvWjo91O8usRBHFZJw")?.id
                == "ddddddddddd")
    }

    @Test("Suchanfrage: Podcast und Folge, der Podcast nur einmal")
    func searchQuery() {
        #expect(AudioTwinMatcher.searchQuery(podcastTitle: "Imkerfunk", episodeTitle: "#87 Bienen")
                == "Imkerfunk #87 Bienen")
        #expect(AudioTwinMatcher.searchQuery(podcastTitle: "Imkerfunk", episodeTitle: "Imkerfunk #87 Bienen")
                == "Imkerfunk #87 Bienen")
    }
}

// MARK: - Reihenfolge und Wartezeit

@Suite("Reihenfolge für eine Folge mit Ton")
struct AudioTwinPlannerTests {

    @Test("Mit Schlüssel: Transkript des Podcasts, dann Zwilling, dann eigene Erkennung")
    func orderWithKey() {
        let inputs = AudioTwinPlanner.Inputs(hasPublisherTranscript: true, supadataAllowed: true,
                                             networkAllowed: true, searchQuery: "Imkerfunk #87", now: now)
        #expect(AudioTwinPlanner.steps(inputs)
                == [.publisherTranscript, .twinCaptions(.search(query: "Imkerfunk #87")), .localTranscription])
    }

    @Test("Ohne Schlüssel ändert sich nichts")
    func orderWithoutKey() {
        let inputs = AudioTwinPlanner.Inputs(hasPublisherTranscript: true, supadataAllowed: false,
                                             networkAllowed: true, subscribedTwinVideoID: "aaaaaaaaaaa",
                                             searchQuery: "Imkerfunk #87", now: now)
        #expect(AudioTwinPlanner.steps(inputs) == [.publisherTranscript, .localTranscription])
        var noPublisher = inputs
        noPublisher.hasPublisherTranscript = false
        #expect(AudioTwinPlanner.steps(noPublisher) == [.localTranscription])
    }

    @Test("Kein Abruf für Ton, der sich nicht abgleichen lässt")
    func audioFormatPrecheck() {
        let mp3 = URL(string: "https://example.com/folge.mp3?ref=feed")!
        let m4a = URL(string: "https://example.com/folge.M4A")!
        #expect(AudioTwinPlanner.audioAllowsAlignment(audioURL: mp3, onDevice: false, declaredDuration: nil))
        #expect(!AudioTwinPlanner.audioAllowsAlignment(audioURL: m4a, onDevice: false, declaredDuration: nil))
        // Auf dem Gerät geht jedes Format.
        #expect(AudioTwinPlanner.audioAllowsAlignment(audioURL: m4a, onDevice: true, declaredDuration: nil))
        #expect(!AudioTwinPlanner.audioAllowsAlignment(audioURL: mp3, onDevice: true,
                                                       declaredDuration: MediaDuration(minutes: 3)))
    }

    @Test("Ohne erlaubtes Netz kein Zwilling, abonnierter Kanal vor Suche")
    func networkAndSources() {
        var inputs = AudioTwinPlanner.Inputs(supadataAllowed: true, networkAllowed: false,
                                             subscribedTwinVideoID: "aaaaaaaaaaa", searchQuery: "x", now: now)
        #expect(AudioTwinPlanner.twinSource(inputs) == nil)
        inputs.networkAllowed = true
        #expect(AudioTwinPlanner.twinSource(inputs) == .subscribedChannel(videoID: "aaaaaaaaaaa"))
        inputs.subscribedTwinVideoID = nil
        inputs.record = AudioTwinRecord(searchedAt: now.addingTimeInterval(-day), videoID: "bbbbbbbbbbb")
        #expect(AudioTwinPlanner.twinSource(inputs) == .rememberedVideo(videoID: "bbbbbbbbbbb"))
    }

    @Test("Höchstens eine Suche je Folge und Woche, auch nach einem Fehlschlag")
    func searchCooldown() {
        var inputs = AudioTwinPlanner.Inputs(supadataAllowed: true, networkAllowed: true,
                                             record: AudioTwinRecord(searchedAt: now.addingTimeInterval(-2 * day)),
                                             searchQuery: "Imkerfunk #87", now: now)
        #expect(AudioTwinPlanner.twinSource(inputs) == nil)
        inputs.now = now.addingTimeInterval(4 * day)
        #expect(AudioTwinPlanner.twinSource(inputs) == nil)
        inputs.now = now.addingTimeInterval(5 * day + 1)
        #expect(AudioTwinPlanner.twinSource(inputs) == .search(query: "Imkerfunk #87"))

        // „Kein Zwilling“ gemerkt: eine Woche Ruhe, dann wieder.
        inputs.record = AudioTwinRecord(searchedAt: now, failure: CaptionFailure(kind: .lasting, at: now))
        inputs.now = now.addingTimeInterval(3 * day)
        #expect(AudioTwinPlanner.twinSource(inputs) == nil)
        inputs.now = now.addingTimeInterval(8 * day)
        #expect(AudioTwinPlanner.twinSource(inputs) == .search(query: "Imkerfunk #87"))

        // Ein neues Video im abonnierten Kanal ist neue Auskunft, trotz Wartezeit.
        inputs.now = now.addingTimeInterval(day)
        inputs.subscribedTwinVideoID = "ccccccccccc"
        #expect(AudioTwinPlanner.twinSource(inputs) == .subscribedChannel(videoID: "ccccccccccc"))
        // Dasselbe Video wie beim Fehlschlag wartet.
        inputs.record?.videoID = "ccccccccccc"
        #expect(AudioTwinPlanner.twinSource(inputs) == nil)
    }
}

// MARK: - Abgleich der Zeiten

/// Eine erfundene Folge: Wörter im Abstand von 400 ms im Video, als
/// Untertitel zu je vier Wörtern. Der Ton hat dieselben Wörter mit Versatz,
/// dazu Werbung mit anderen Wörtern.
private struct SyntheticEpisode {
    let words: [String]
    static let wordMs: Int64 = 400

    init(count: Int, seed: UInt64 = 7) {
        var state = seed
        let syllables = ["ka", "lo", "mi", "ren", "tos", "vel", "dun", "sa", "pri", "gor", "hel", "ni"]
        var list: [String] = []
        for _ in 0..<count {
            var word = ""
            for _ in 0..<3 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                word += syllables[Int((state >> 33) % UInt64(syllables.count))]
            }
            list.append(word)
        }
        words = list
    }

    func videoTime(_ index: Int) -> Int64 { Int64(index) * Self.wordMs }

    var cues: [CaptionCue] {
        stride(from: 0, to: words.count, by: 4).map { start in
            let chunk = words[start..<min(words.count, start + 4)]
            return CaptionCue(text: chunk.joined(separator: " "), start: MediaTime(milliseconds: videoTime(start)),
                              duration: MediaDuration(milliseconds: Int64(chunk.count) * Self.wordMs))
        }
    }

    /// Die Wörter, die im Ton zwischen `start` und `start + length` liegen,
    /// mit etwa jedem achten Wort falsch erkannt.
    func window(start: Int64, length: Int64 = 25_000, audioTime: (Int64) -> Int64,
                ads: [(range: ClosedRange<Int64>, word: String)] = []) -> [AlignmentWord] {
        var result: [AlignmentWord] = []
        for (index, word) in words.enumerated() {
            let time = audioTime(videoTime(index))
            guard time >= start, time <= start + length else { continue }
            result.append(AlignmentWord(token: index % 8 == 3 ? "falsch\(index)" : word, time: time))
        }
        for ad in ads {
            var time = max(start, ad.range.lowerBound)
            while time <= min(start + length, ad.range.upperBound) {
                result.append(AlignmentWord(token: ad.word + String(time % 97), time: time))
                time += Self.wordMs
            }
        }
        return result.sorted { $0.time < $1.time }
    }
}

@Suite("Abgleich von Untertiteln mit dem Ton")
struct CaptionAlignmentTests {

    fileprivate let episode = SyntheticEpisode(count: 4_500)   // 30 Minuten

    var captionWords: [AlignmentWord] { CaptionAlignment.words(cues: episode.cues) }

    @Test("Fester Versatz: ein längeres Intro im MP3")
    func constantOffset() throws {
        let intro: Int64 = 42_000
        let shifted: (Int64) -> Int64 = { $0 + intro }
        var anchors: [AlignmentAnchor] = []
        for start: Int64 in [180_000, 900_000, 1_530_000] {
            let match = try #require(CaptionAlignment.match(window: episode.window(start: start, audioTime: shifted),
                                                            captions: captionWords))
            #expect(abs(match.offset - intro) <= 1_000)
            #expect(match.wordOverlap >= 0.8)
            anchors.append(match.anchor)
        }
        let mapping = try CaptionAlignment.mapping(from: anchors).get()
        #expect(mapping.isConstant)
        #expect(abs(mapping.audioTime(forCaption: 600_000) - 642_000) <= 1_000)
        #expect(abs(mapping.audioTime(forCaption: 0) - 42_000) <= 1_000)
    }

    @Test("Eingefügte Werbung: Versatz stückweise, dazwischen übergeleitet")
    func insertedAd() throws {
        // 30 s Intro, bei Minute 12 im Video 90 s Werbung nur im MP3.
        let adAt: Int64 = 720_000
        let audio: (Int64) -> Int64 = { $0 < adAt ? $0 + 30_000 : $0 + 120_000 }
        let adRange = (adAt + 30_000)...(adAt + 120_000)
        func anchor(at start: Int64) -> AlignmentAnchor? {
            CaptionAlignment.match(window: episode.window(start: start, audioTime: audio, ads: [(adRange, "werbung")]),
                                   captions: captionWords)?.anchor
        }
        let first = try #require(anchor(at: 180_000))
        let second = try #require(anchor(at: 500_000))
        let third = try #require(anchor(at: 1_500_000))
        #expect(abs(first.offset - 30_000) <= 1_000)
        #expect(abs(third.offset - 120_000) <= 1_000)
        // Mitten in der Werbung passt nichts.
        #expect(anchor(at: adRange.lowerBound + 10_000) == nil)

        // Die Strecke mit dem Wechsel ist lang: ein weiteres Stück grenzt sie ein.
        let probe = try #require(CaptionAlignment.nextProbe(anchors: [first, second, third], failedProbes: []))
        #expect(probe > second.audioTime && probe < third.audioTime)
        let refined = try #require(anchor(at: 900_000))
        #expect(abs(refined.offset - 120_000) <= 1_000)

        // Noch sechseinhalb Minuten offen: zu weit, um überzuleiten.
        #expect(CaptionAlignment.mapping(from: [first, second, third, refined]) == .failure(.stepTooWide))
        let closer = try #require(anchor(at: 700_000))
        #expect(abs(closer.offset - 30_000) <= 1_000)
        let mapping = try CaptionAlignment.mapping(from: [first, second, third, refined, closer]).get()
        #expect(!mapping.isConstant)
        // Vor der Werbung 30 s, danach 120 s.
        #expect(abs(mapping.audioTime(forCaption: 300_000) - 330_000) <= 1_000)
        #expect(abs(mapping.audioTime(forCaption: 1_200_000) - 1_320_000) <= 1_000)
        // Dazwischen wird linear übergeleitet, monoton.
        let inside = mapping.audioTime(forCaption: 700_000)
        #expect(inside > mapping.audioTime(forCaption: 600_000) && inside < mapping.audioTime(forCaption: 800_000))
    }

    @Test("Eingrenzen: fiel die Mitte in Werbung, ein Viertel daneben, dann nichts mehr")
    func probesAroundFailedMiddle() {
        let anchors = [AlignmentAnchor(audioTime: 200_000, offset: 30_000),
                       AlignmentAnchor(audioTime: 1_000_000, offset: 120_000)]
        #expect(CaptionAlignment.nextProbe(anchors: anchors, failedProbes: []) == 600_000)
        #expect(CaptionAlignment.nextProbe(anchors: anchors, failedProbes: [600_000]) == 400_000)
        #expect(CaptionAlignment.nextProbe(anchors: anchors, failedProbes: [600_000, 400_000]) == 800_000)
        #expect(CaptionAlignment.nextProbe(anchors: anchors, failedProbes: [600_000, 400_000, 800_000]) == nil)
        // Gleicher Versatz oder schon eng genug: nichts einzugrenzen.
        #expect(CaptionAlignment.nextProbe(anchors: [anchors[0], AlignmentAnchor(audioTime: 1_000_000, offset: 31_000)],
                                           failedProbes: []) == nil)
        #expect(CaptionAlignment.nextProbe(anchors: [anchors[0], AlignmentAnchor(audioTime: 350_000, offset: 120_000)],
                                           failedProbes: []) == nil)
    }

    @Test("Stücke aus einer anderen Folge: kein Anker, keine Zuordnung")
    func rejectsForeignAudio() {
        let other = SyntheticEpisode(count: 4_500, seed: 99)
        let foreign = other.window(start: 300_000, audioTime: { $0 })
        #expect(CaptionAlignment.match(window: foreign, captions: captionWords) == nil)
        // Zu wenig Wörter, etwa Musik.
        let short = Array(episode.window(start: 300_000, audioTime: { $0 }).prefix(10))
        #expect(CaptionAlignment.match(window: short, captions: captionWords) == nil)

        #expect(CaptionAlignment.mapping(from: [AlignmentAnchor(audioTime: 60_000, offset: 5_000)])
                == .failure(.tooFewAnchors))
        // Im Ton später, im Video früher: dann ist es nicht dieselbe Folge.
        #expect(CaptionAlignment.mapping(from: [
            AlignmentAnchor(audioTime: 100_000, offset: 0),
            AlignmentAnchor(audioTime: 200_000, offset: 150_000),
        ]) == .failure(.notMonotonic))
        // Ein Wechsel, der sich nicht eingrenzen ließ.
        #expect(CaptionAlignment.mapping(from: [
            AlignmentAnchor(audioTime: 100_000, offset: 0),
            AlignmentAnchor(audioTime: 1_500_000, offset: 60_000),
        ]) == .failure(.stepTooWide))
        #expect(CaptionAlignment.mapping(from: [
            AlignmentAnchor(audioTime: 100_000, offset: 0),
            AlignmentAnchor(audioTime: 200_000, offset: 30 * 60_000),
        ]) == .failure(.offsetTooLarge))
    }

    @Test("Zeilen verschieben: auf die Zeit des Tons, was davor liegt, fällt weg")
    func shiftsCues() throws {
        let cues = [
            CaptionCue(text: "[Musik]", start: .zero, duration: MediaDuration(seconds: 3)),
            CaptionCue(text: "Nur im Video.", start: MediaTime(seconds: 1), duration: MediaDuration(seconds: 2)),
        ] + (0..<40).map {
            CaptionCue(text: "Satz \($0) mit Inhalt.", start: MediaTime(seconds: 10 + Double($0) * 3),
                       duration: MediaDuration(seconds: 3))
        }
        // Im Ton fehlt ein Intro von 5 s: alles 5 s früher.
        let mapping = CaptionTimeMapping(anchors: [AlignmentAnchor(audioTime: 20_000, offset: -5_000),
                                                   AlignmentAnchor(audioTime: 100_000, offset: -5_000)])
        let shifted = try CaptionAlignment.shift(cues: cues, by: mapping,
                                                 audioDuration: MediaDuration(seconds: 200)).get()
        #expect(shifted.count == 40)
        #expect(shifted.first?.start.milliseconds == 5_000)
        #expect(shifted.first?.duration.milliseconds == 3_000)

        let audioVersion = MediaVersionID(stable: "https://example.com/folge.mp3")
        let transcript = CaptionTranscriptBuilder.transcript(
            from: shifted, mediaVersionID: audioVersion, locale: "de-DE", origin: .youTubeCaptionsAligned)
        #expect(transcript.mediaVersionID == audioVersion)
        #expect(transcript.origin == .youTubeCaptionsAligned)
        #expect(transcript.segments.first?.range.start.milliseconds == 5_000)
        #expect(transcript.origin.sourceLabel?.isEmpty == false)

        // Passt die Zuordnung nicht zur Datei, landet zu viel außerhalb.
        let wrong = CaptionTimeMapping(anchors: [AlignmentAnchor(audioTime: 0, offset: -60_000),
                                                 AlignmentAnchor(audioTime: 60_000, offset: -60_000)])
        #expect(CaptionAlignment.shift(cues: cues, by: wrong, audioDuration: MediaDuration(seconds: 200))
                == .failure(.outsideAudio))
    }
}

// MARK: - MP3 stückweise

@Suite("Lage des Tons in einer MP3-Datei")
struct MPEGAudioLayoutTests {

    /// MPEG-1 Layer III, 128 kbit/s, 44,1 kHz, Stereo: 417 Byte je Rahmen.
    private func frames(_ count: Int, bitrateByte: UInt8 = 0x90, tag: String? = nil) -> Data {
        var data = Data()
        for index in 0..<count {
            var frame = Data([0xFF, 0xFB, bitrateByte, 0x00])
            let length = MPEGAudio.header(in: frame + Data(count: 4), at: 0)!.length
            frame.append(Data(count: length - 4))
            if index == 0, let tag {
                frame.replaceSubrange(36..<40, with: Data(tag.utf8))
            }
            data.append(frame)
        }
        return data
    }

    @Test("Rahmenkopf, ID3-Länge und Content-Range")
    func headers() {
        let head = MPEGAudio.header(in: frames(1), at: 0)
        #expect(head?.bitrateKbps == 128)
        #expect(head?.sampleRate == 44_100)
        #expect(head?.length == 417)
        // Syncsafe: 0x00 0x00 0x02 0x01 = 257 Byte, plus zehn Byte Kopf.
        #expect(MPEGAudio.id3Length(Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0x02, 0x01])) == 267)
        #expect(MPEGAudio.id3Length(Data(count: 10)) == 0)
        #expect(MPEGAudio.totalLength(contentRange: "bytes 0-16383/7654321") == 7_654_321)
        #expect(MPEGAudio.totalLength(contentRange: "bytes 0-16383/*") == nil)
    }

    @Test("Feste Bitrate: Anfang des Tons hinter ID3 und Info-Rahmen, Zeit aus Byte")
    func constantBitrateLayout() throws {
        var file = Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0x02, 0x01]) + Data(count: 257)
        file.append(frames(20, tag: "Info"))
        let layout = try #require(CBRAudioLayout.parse(head: file, dataOffset: 0, searchFrom: 267,
                                                       totalLength: 267 + 16_000_000))
        #expect(layout.audioStart == 267 + 417)
        #expect(layout.bitrateKbps == 128)
        // 16 000 Byte je Sekunde.
        #expect(layout.bytesPerSecond == 16_000)
        #expect(layout.milliseconds(atByte: layout.audioStart + 16_000 * 60) == 60_000)
        #expect(layout.byte(atMilliseconds: 90_000) == layout.audioStart + 1_440_000)

        // Xing heißt variable Bitrate: dann nicht.
        let variable = frames(20, tag: "Xing")
        #expect(CBRAudioLayout.parse(head: variable, dataOffset: 0, searchFrom: 0, totalLength: 1_000_000) == nil)
    }

    @Test("Ein Stück mit abweichender Bitrate gilt nicht")
    func rejectsChangingBitrate() {
        let steady = Data([0x12, 0x34]) + frames(30)
        let start = MPEGAudio.firstFrame(in: steady)
        #expect(start == 2)
        #expect(MPEGAudio.constantBitrateEnd(in: steady, from: 2, bitrateKbps: 128) == 2 + 30 * 417)
        // 160 kbit/s dazwischen.
        let mixed = frames(10) + frames(5, bitrateByte: 0xA0) + frames(10)
        #expect(MPEGAudio.constantBitrateEnd(in: mixed, from: 0, bitrateKbps: 128) == nil)
    }
}
