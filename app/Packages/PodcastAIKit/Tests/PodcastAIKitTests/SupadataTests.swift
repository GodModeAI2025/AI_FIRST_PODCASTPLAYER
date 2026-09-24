//
//  SupadataTests.swift
//  PodcastAIKitTests
//
//  YouTube-Untertitel über Supadata: Antworten lesen, Wiederholungen mit
//  Pause, Aufträge für lange Videos, Schutzschalter, Sprache, Reinigen der
//  Zeilen, Zeitmarken, Belege und die Reihenfolge der Rückfälle.
//  Kein Test geht ins Netz und keiner braucht einen echten Schlüssel.
//

import Foundation
import Synchronization
import Testing
import PodcastAIKit
@testable import PodcastAISources
@testable import PodcastAITranscription

// MARK: - Hilfen

/// Spielt feste Antworten ab und merkt sich jede Anfrage. Die Uhr läuft
/// nur, wenn der Client wartet, also ohne echte Pausen.
private final class ScriptedSupadata: Sendable {
    enum Step: Sendable {
        case respond(Int, String, retryAfter: TimeInterval? = nil)
        case fail(URLError.Code)
    }

    private let steps: Mutex<[Step]>
    private let requests = Mutex<[(url: URL, headers: [String: String])]>([])
    private let sleeps = Mutex<[TimeInterval]>([])
    private let now = Mutex(Date(timeIntervalSince1970: 1_790_140_000))

    init(_ steps: [Step]) { self.steps = Mutex(steps) }

    var urls: [URL] { requests.withLock { $0.map(\.url) } }
    var headers: [[String: String]] { requests.withLock { $0.map(\.headers) } }
    var callCount: Int { requests.withLock { $0.count } }
    var pauses: [TimeInterval] { sleeps.withLock { $0 } }
    var date: Date { now.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { now.withLock { $0 = $0.addingTimeInterval(seconds) } }

    func client(_ configuration: SupadataTranscriptClient.Configuration = .init(),
                random: Double = 1) -> SupadataTranscriptClient {
        SupadataTranscriptClient(
            configuration: configuration,
            transport: { [self] url, headers in
                requests.withLock { $0.append((url, headers)) }
                let step = steps.withLock { $0.isEmpty ? nil : $0.removeFirst() }
                switch step {
                case .respond(let status, let body, let retryAfter)?:
                    return SupadataHTTPResponse(status: status, body: Data(body.utf8), retryAfter: retryAfter)
                case .fail(let code)?:
                    throw URLError(code)
                case nil:
                    Issue.record("Mehr Anfragen als erwartet: \(url)")
                    return SupadataHTTPResponse(status: 500, body: Data())
                }
            },
            sleep: { [self] seconds in
                sleeps.withLock { $0.append(seconds) }
                advance(seconds)
            },
            clock: { [self] in date },
            random: { random })
    }
}

private let video = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
private let fakeKey = "test-key-ohne-bedeutung"

private let englishBody = """
    {"lang":"en","availableLangs":["en","de"],"content":[
      {"lang":"en","text":"[♪♪♪]","offset":0,"duration":2000},
      {"lang":"en","text":"Hello and welcome\\nto the show.","offset":18640,"duration":3240},
      {"lang":"en","text":"Today we talk about bees.","offset":21500,"duration":2500}
    ]}
    """

private let germanBody = """
    {"lang":"de","availableLangs":["en","de"],"content":[
      {"lang":"de","text":"Hallo und willkommen.","offset":18640,"duration":3240}
    ]}
    """

// MARK: - Antworten lesen

@Suite("Supadata: Antworten lesen")
struct SupadataDecodingTests {

    @Test("200 liefert Zeilen mit Millisekunden, Sprache und weitere Sprachen")
    func decodesTranscript() throws {
        let transcript = try SupadataDecoding.transcript(from: Data(englishBody.utf8))
        #expect(transcript.lang == "en")
        #expect(transcript.availableLangs == ["en", "de"])
        #expect(transcript.captions.count == 3)
        #expect(transcript.captions[1].offsetMilliseconds == 18_640)
        #expect(transcript.captions[1].durationMilliseconds == 3_240)
    }

    @Test("Leerer Inhalt oder reiner Text heißt: keine Untertitel mit Zeitmarken")
    func emptyContentIsNoTranscript() {
        #expect(throws: SupadataError.noTranscript) {
            try SupadataDecoding.transcript(from: Data(#"{"lang":"en","availableLangs":[],"content":[]}"#.utf8))
        }
        #expect(throws: SupadataError.noTranscript) {
            try SupadataDecoding.transcript(from: Data(#"{"lang":"en","content":"nur Text"}"#.utf8))
        }
        #expect(throws: SupadataError.decoding) {
            try SupadataDecoding.transcript(from: Data("kein json".utf8))
        }
        // Ohne Feld `content` ist die Form unerwartet, nicht das Video ohne Untertitel.
        #expect(throws: SupadataError.decoding) {
            try SupadataDecoding.transcript(from: Data(#"{"lang":"en","result":{"content":[]}}"#.utf8))
        }
        #expect(SupadataError.decoding.isTransient)
    }

    @Test("202 liefert eine Auftragsnummer, der Auftrag meldet seinen Stand")
    func decodesJob() throws {
        #expect(SupadataDecoding.jobID(from: Data(#"{"jobId":"abc-123"}"#.utf8)) == "abc-123")
        #expect(try SupadataDecoding.job(from: Data(#"{"status":"queued"}"#.utf8)) == .running)
        #expect(try SupadataDecoding.job(from: Data(#"{"status":"active"}"#.utf8)) == .running)
        let failed = try SupadataDecoding.job(from: Data(
            #"{"status":"failed","error":{"error":"transcript-unavailable","message":"x"}}"#.utf8))
        #expect(failed == .failed(code: "transcript-unavailable"))
        let done = try SupadataDecoding.job(from: Data(englishBody.replacingOccurrences(
            of: #"{"lang":"en","#, with: #"{"status":"completed","lang":"en","#).utf8))
        guard case .completed(let transcript) = done else {
            Issue.record("Auftrag nicht fertig gelesen")
            return
        }
        #expect(transcript.captions.count == 3)
    }

    @Test("Fehlerstatus und Fehlercodes werden zu Fehlern der App")
    func mapsErrors() {
        func map(_ status: Int, _ body: String = "{}") -> SupadataError {
            SupadataDecoding.error(status: status, body: Data(body.utf8), retryAfter: nil)
        }
        #expect(map(401, #"{"error":"unauthorized"}"#) == .unauthorized)
        #expect(map(404, #"{"error":"not-found","details":"This video does not exist"}"#) == .notFound)
        #expect(map(206) == .noTranscript)
        #expect(map(402, #"{"error":"upgrade-required"}"#) == .quota)
        #expect(map(429, #"{"error":"limit-exceeded"}"#) == .rateLimited(retryAfter: nil))
        #expect(map(429, #"{"error":"upgrade-required"}"#) == .quota)
        #expect(map(403) == .forbidden)
        #expect(map(400) == .invalidRequest)
        #expect(map(503) == .server(status: 503))
        #expect(SupadataError.noTranscript.isTransient == false)
        #expect(SupadataError.network.isTransient)
        #expect(SupadataError.unauthorized.affectsAccount)
    }

    @Test("Keine Fehlermeldung nennt den Schlüssel")
    func errorsNeverContainKey() {
        let all: [SupadataError] = [.missingKey, .unauthorized, .notFound, .noTranscript,
                                    .rateLimited(retryAfter: 3), .quota, .forbidden, .invalidRequest,
                                    .server(status: 500), .network, .decoding, .jobFailed, .timeout, .cancelled]
        for error in all {
            let text = error.errorDescription ?? ""
            #expect(!text.isEmpty)
            #expect(!text.contains(fakeKey))
        }
    }
}

// MARK: - Client

@Suite("Supadata: Anfragen, Wiederholungen und Schutzschalter")
struct SupadataClientTests {

    @Test("Eine Anfrage mit mode=native und Schlüssel im Kopf, nicht in der Adresse")
    func sendsNativeRequest() async throws {
        let script = ScriptedSupadata([.respond(200, englishBody)])
        let transcript = try await script.client().transcript(videoURL: video, apiKey: fakeKey,
                                                              preferredLanguages: ["en"])
        #expect(transcript.lang == "en")
        #expect(script.callCount == 1)
        let url = try #require(script.urls.first)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.host() == "api.supadata.ai")
        #expect(url.path() == "/v1/transcript")
        #expect(items.contains(URLQueryItem(name: "mode", value: "native")))
        #expect(items.contains(URLQueryItem(name: "url", value: video.absoluteString)))
        #expect(!url.absoluteString.contains(fakeKey))
        #expect(script.headers.first?["x-api-key"] == fakeKey)
    }

    @Test("Ohne Schlüssel keine Anfrage")
    func missingKeySendsNothing() async {
        let script = ScriptedSupadata([])
        await #expect(throws: SupadataError.missingKey) {
            try await script.client().transcript(videoURL: video, apiKey: "  ", preferredLanguages: [])
        }
        #expect(script.callCount == 0)
    }

    @Test("Bevorzugte Sprache: zweite Anfrage mit lang, wenn das Video sie hat")
    func fetchesPreferredLanguage() async throws {
        let script = ScriptedSupadata([.respond(200, englishBody), .respond(200, germanBody)])
        let transcript = try await script.client().transcript(videoURL: video, apiKey: fakeKey,
                                                              preferredLanguages: ["de-DE"])
        #expect(transcript.lang == "de")
        #expect(script.callCount == 2)
        let second = URLComponents(url: script.urls[1], resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(second.contains(URLQueryItem(name: "lang", value: "de")))
    }

    @Test("Scheitert die zweite Sprache, bleibt die erste")
    func keepsFirstLanguageWhenSecondFails() async throws {
        let script = ScriptedSupadata([.respond(200, englishBody), .respond(404, #"{"error":"not-found"}"#)])
        let transcript = try await script.client().transcript(videoURL: video, apiKey: fakeKey,
                                                              preferredLanguages: ["de"])
        #expect(transcript.lang == "en")
    }

    @Test("429 und 5xx: höchstens drei Wiederholungen mit wachsender Pause")
    func retriesWithBackoff() async throws {
        let script = ScriptedSupadata([
            .respond(503, "{}"), .respond(429, #"{"error":"limit-exceeded"}"#), .fail(.timedOut),
            .respond(200, englishBody),
        ])
        let transcript = try await script.client().transcript(videoURL: video, apiKey: fakeKey,
                                                              preferredLanguages: ["en"])
        #expect(transcript.captions.count == 3)
        #expect(script.callCount == 4)
        #expect(script.pauses == [1, 2, 4])
    }

    @Test("Nach drei Wiederholungen ist Schluss")
    func stopsAfterMaxRetries() async {
        let script = ScriptedSupadata(Array(repeating: .respond(500, "{}"), count: 4))
        await #expect(throws: SupadataError.server(status: 500)) {
            try await script.client().transcript(videoURL: video, apiKey: fakeKey, preferredLanguages: [])
        }
        #expect(script.callCount == 4)
    }

    @Test("404 und fehlende Untertitel werden nicht wiederholt")
    func doesNotRetryPermanentErrors() async {
        let script = ScriptedSupadata([.respond(404, #"{"error":"not-found"}"#)])
        await #expect(throws: SupadataError.notFound) {
            try await script.client().transcript(videoURL: video, apiKey: fakeKey, preferredLanguages: [])
        }
        let empty = ScriptedSupadata([.respond(206, "{}")])
        await #expect(throws: SupadataError.noTranscript) {
            try await empty.client().transcript(videoURL: video, apiKey: fakeKey, preferredLanguages: [])
        }
        #expect(script.callCount == 1)
        #expect(empty.callCount == 1)
    }

    @Test("Pause mit Zufall zwischen halber und ganzer Länge, gedeckelt")
    func backoffFormula() {
        #expect(SupadataTranscriptClient.backoff(attempt: 0, initial: 1, maximum: 20, random: 1) == 1)
        #expect(SupadataTranscriptClient.backoff(attempt: 0, initial: 1, maximum: 20, random: 0) == 0.5)
        #expect(SupadataTranscriptClient.backoff(attempt: 3, initial: 1, maximum: 20, random: 1) == 8)
        #expect(SupadataTranscriptClient.backoff(attempt: 10, initial: 1, maximum: 20, random: 1) == 20)
        #expect(SupadataTranscriptClient.backoff(attempt: 99, initial: 1, maximum: 20, random: 0.5) == 15)
    }

    @Test("Retry-After zählt, wenn es länger ist als die eigene Pause")
    func honorsRetryAfter() async throws {
        let script = ScriptedSupadata([.respond(429, "{}", retryAfter: 7), .respond(200, englishBody)])
        _ = try await script.client().transcript(videoURL: video, apiKey: fakeKey, preferredLanguages: ["en"])
        #expect(script.pauses == [7])
    }

    @Test("Ein Retry-After über die Frist hinaus: gleich aufgeben und ruhen")
    func retryAfterBeyondDeadlineOpensBreaker() async throws {
        let script = ScriptedSupadata([.respond(429, "{}", retryAfter: 600)])
        let client = script.client()
        await #expect(throws: SupadataError.rateLimited(retryAfter: 600)) {
            try await client.transcript(videoURL: video, apiKey: fakeKey, preferredLanguages: [])
        }
        #expect(await client.openBreakerReason() == .rateLimited(retryAfter: 600))
        #expect(script.pauses.isEmpty)
    }

    @Test("401 öffnet den Schutzschalter: keine weitere Anfrage, bis ein neuer Schlüssel kommt")
    func unauthorizedOpensBreaker() async {
        let script = ScriptedSupadata([.respond(401, #"{"error":"unauthorized"}"#), .respond(200, englishBody)])
        let client = script.client()
        await #expect(throws: SupadataError.unauthorized) {
            try await client.transcript(videoURL: video, apiKey: fakeKey, preferredLanguages: [])
        }
        await #expect(throws: SupadataError.unauthorized) {
            try await client.transcript(videoURL: video, apiKey: fakeKey, preferredLanguages: [])
        }
        #expect(script.callCount == 1)
        // Auch nach Tagen bleibt er offen.
        script.advance(30 * 24 * 3600)
        #expect(await client.openBreakerReason() == .unauthorized)
        await client.resetBreaker()
        let transcript = try? await client.transcript(videoURL: video, apiKey: fakeKey, preferredLanguages: ["en"])
        #expect(transcript?.lang == "en")
        #expect(script.callCount == 2)
    }

    @Test("Aufgebrauchtes Kontingent: Ruhe für eine Weile, danach wieder Anfragen")
    func quotaCoolsDown() async throws {
        let script = ScriptedSupadata([.respond(402, #"{"error":"upgrade-required"}"#), .respond(200, englishBody)])
        let client = script.client()
        await #expect(throws: SupadataError.quota) {
            try await client.transcript(videoURL: video, apiKey: fakeKey, preferredLanguages: [])
        }
        await #expect(throws: SupadataError.quota) {
            try await client.transcript(videoURL: video, apiKey: fakeKey, preferredLanguages: [])
        }
        #expect(script.callCount == 1)
        script.advance(client.configuration.quotaCooldown + 1)
        _ = try await client.transcript(videoURL: video, apiKey: fakeKey, preferredLanguages: ["en"])
        #expect(script.callCount == 2)
    }

    @Test("Lange Videos: 202, dann nachfragen, bis der Auftrag fertig ist")
    func pollsJob() async throws {
        let completed = englishBody.replacingOccurrences(of: #"{"lang":"en","#,
                                                         with: #"{"status":"completed","lang":"en","#)
        let script = ScriptedSupadata([
            .respond(202, #"{"jobId":"job-42"}"#),
            .respond(200, #"{"status":"queued"}"#),
            .respond(200, #"{"status":"active"}"#),
            .respond(200, completed),
        ])
        let transcript = try await script.client().transcript(videoURL: video, apiKey: fakeKey,
                                                              preferredLanguages: ["en"])
        #expect(transcript.captions.count == 3)
        #expect(script.urls[1].path() == "/v1/transcript/job-42")
        #expect(script.pauses == [3, 3])
    }

    @Test("Gescheiterter Auftrag ohne Untertitel ist ein bleibender Fehler")
    func failedJob() async {
        let script = ScriptedSupadata([
            .respond(202, #"{"jobId":"job-1"}"#),
            .respond(200, #"{"status":"failed","error":{"error":"transcript-unavailable"}}"#),
        ])
        await #expect(throws: SupadataError.noTranscript) {
            try await script.client().transcript(videoURL: video, apiKey: fakeKey, preferredLanguages: [])
        }
    }

    @Test("Frist um: Auftrag bleibt gemerkt, der nächste Versuch fragt dort weiter")
    func timeoutResumesJob() async throws {
        var configuration = SupadataTranscriptClient.Configuration()
        configuration.deadline = 5
        let completed = englishBody.replacingOccurrences(of: #"{"lang":"en","#,
                                                         with: #"{"status":"completed","lang":"en","#)
        let script = ScriptedSupadata([
            .respond(202, #"{"jobId":"job-7"}"#),
            .respond(200, #"{"status":"active"}"#),
            .respond(200, #"{"status":"active"}"#),
            .respond(200, completed),
        ])
        let client = script.client(configuration)
        await #expect(throws: SupadataError.timeout) {
            try await client.transcript(videoURL: video, apiKey: fakeKey, preferredLanguages: ["en"])
        }
        let transcript = try await client.transcript(videoURL: video, apiKey: fakeKey, preferredLanguages: ["en"])
        #expect(transcript.captions.count == 3)
        // Kein zweites Bestellen: nach dem 202 nur noch Nachfragen.
        #expect(script.urls.dropFirst().allSatisfy { $0.path() == "/v1/transcript/job-7" })
    }

    @Test("Abbruch: keine weiteren Anfragen")
    func cancellationStops() async {
        let script = ScriptedSupadata([.respond(503, "{}"), .respond(200, englishBody)])
        let client = script.client()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.transcript(videoURL: video, apiKey: fakeKey, preferredLanguages: [])
        }
        await #expect(throws: SupadataError.cancelled) { try await task.value }
        #expect(script.callCount == 0)
    }

    @Test("Schlüssel prüfen über /me, ohne Untertitel zu kosten")
    func checksAccount() async throws {
        let script = ScriptedSupadata([
            .respond(200, #"{"organizationId":"org","plan":"Basic","maxCredits":100,"usedCredits":100}"#),
        ])
        let account = try await script.client().account(apiKey: fakeKey)
        #expect(account.plan == "Basic")
        #expect(account.isExhausted)
        #expect(script.urls.first?.path() == "/v1/me")
        let rejected = ScriptedSupadata([.respond(401, #"{"error":"unauthorized"}"#)])
        await #expect(throws: SupadataError.unauthorized) { try await rejected.client().account(apiKey: fakeKey) }
    }
}

// MARK: - Sprache

@Suite("Supadata: Sprache")
struct SupadataLanguageTests {

    @Test("Die Sprache der App, wenn das Video sie hat, sonst die des Videos")
    func choosesLanguage() {
        #expect(SupadataLanguage.preferred(among: ["en", "de"], current: "en", preferred: ["de-DE"]) == "de")
        #expect(SupadataLanguage.preferred(among: ["en", "de"], current: "de", preferred: ["de"]) == nil)
        #expect(SupadataLanguage.preferred(among: ["en", "fr"], current: "en", preferred: ["de"]) == nil)
        #expect(SupadataLanguage.preferred(among: ["en", "de"], current: "en", preferred: ["en", "de"]) == nil)
        #expect(SupadataLanguage.preferred(among: [], current: nil, preferred: ["de"]) == nil)
        #expect(SupadataLanguage.base("pt_BR") == "pt")
    }
}

// MARK: - Zeilen, Zeitmarken und Belege

@Suite("Untertitel: Reinigen, Zeitmarken und Belege")
struct CaptionTranscriptTests {

    private let media = MediaVersionID(stable: video.absoluteString)

    @Test("Marken wie [♪♪♪] und [Musik] fallen weg, Zeilen werden zu einer")
    func cleansMarkers() {
        #expect(CaptionText.clean("[♪♪♪]") == "")
        #expect(CaptionText.clean("[Musik] Hallo\nund willkommen ♪") == "Hallo und willkommen")
        #expect(CaptionText.clean(">> Ja, genau. &amp; weiter") == "Ja, genau. & weiter")
        #expect(CaptionText.clean("It&#39;s fine") == "It's fine")
    }

    @Test("Millisekunden werden Medienzeit, Überlappungen werden abgeschnitten, nicht verworfen")
    func convertsTimestamps() {
        let cues = [
            CaptionCue(text: "Hello and", start: MediaTime(milliseconds: 18_640), duration: MediaDuration(milliseconds: 3_240)),
            CaptionCue(text: "welcome to the show.", start: MediaTime(milliseconds: 20_000), duration: MediaDuration(milliseconds: 3_000)),
            CaptionCue(text: "[♪♪♪]", start: MediaTime(milliseconds: 23_000), duration: MediaDuration(milliseconds: 500)),
            CaptionCue(text: "Next topic.", start: MediaTime(milliseconds: 30_000), duration: .zero),
        ]
        let segments = CaptionTranscriptBuilder.segments(from: cues, mediaVersionID: media)
        #expect(segments.count == 2)
        #expect(segments[0].text == "Hello and welcome to the show.")
        #expect(segments[0].range.start.milliseconds == 18_640)
        #expect(segments[0].range.end.milliseconds == 23_000)
        #expect(segments[1].text == "Next topic.")
        #expect(segments[1].range.start.milliseconds == 30_000)
        #expect(segments[1].range.end.milliseconds == 32_000)
        // Keine Überlappung.
        for (a, b) in zip(segments, segments.dropFirst()) { #expect(a.range.end <= b.range.start) }
    }

    @Test("Ohne Satzzeichen endet ein Segment nach höchstens 15 Sekunden")
    func capsSegmentLength() {
        let cues = (0..<20).map {
            CaptionCue(text: "wort \($0)", start: MediaTime(milliseconds: Int64($0) * 2_000),
                       duration: MediaDuration(milliseconds: 2_000))
        }
        let segments = CaptionTranscriptBuilder.segments(from: cues, mediaVersionID: media)
        #expect(segments.count > 1)
        #expect(segments.allSatisfy { $0.range.duration <= CaptionTranscriptBuilder.maxSegmentLength })
        #expect(segments.map(\.text).joined(separator: " ").split(separator: " ").count == 40)
    }

    @Test("Belege wie bei einer Folge mit Ton: Fassung, Zeitbereich, Wortlaut")
    func buildsEvidence() throws {
        // Zehn Minuten Untertitel in Sätzen von vier Sekunden.
        let captions = (0..<150).map {
            SupadataCaption(text: "Satz Nummer \($0).", offsetMilliseconds: Int64($0) * 4_000,
                            durationMilliseconds: 4_200, lang: "de")
        }
        let result = try #require(CaptionAnalysis.build(
            captions: SupadataTranscript(lang: "de", availableLangs: ["de"], captions: captions),
            episodeID: EpisodeID(rawValue: "e1"), sourceID: SourceID(rawValue: "s1"),
            watchURL: video, fallbackLocale: "en"))
        #expect(result.transcript.origin == .youTubeCaptions)
        #expect(result.transcript.locale == "de")
        #expect(result.transcript.origin.sourceLabel?.isEmpty == false)
        #expect(result.media.remoteURL == video)
        #expect(result.media.localRelativePath == nil)
        #expect(result.media.duration?.milliseconds == 600_200)
        // Etwa eine Minute je Beleg, keiner länger als die harte Grenze.
        #expect((8...12).contains(result.evidence.count))
        for item in result.evidence {
            #expect(item.mediaVersionID == CaptionAnalysis.mediaVersionID(watchURL: video))
            #expect(item.isPlayable)
            #expect(item.quotedText.hasPrefix("Satz Nummer"))
            #expect(item.range!.duration <= MediaDuration(seconds: 150))
        }
        // Lückenlos und ohne Überlappung.
        for (a, b) in zip(result.evidence, result.evidence.dropFirst()) { #expect(a.range!.end <= b.range!.start) }
    }

    @Test("Nur Musik: kein Transkript")
    func musicOnlyBuildsNothing() {
        let captions = [SupadataCaption(text: "[♪♪♪]", offsetMilliseconds: 0, durationMilliseconds: 5_000)]
        #expect(CaptionAnalysis.build(
            captions: SupadataTranscript(lang: "en", availableLangs: [], captions: captions),
            episodeID: EpisodeID(rawValue: "e"), sourceID: SourceID(rawValue: "s"),
            watchURL: video, fallbackLocale: "en") == nil)
    }
}

// MARK: - Adressen und Rückfälle

@Suite("YouTube: Adressen und Rückfälle")
struct YouTubeFallbackTests {

    @Test("Videokennung und Adresse mit Zeitmarke")
    func watchLinks() {
        #expect(YouTubeLinks.videoID(in: URL(string: "https://youtu.be/dQw4w9WgXcQ?si=abc")) == "dQw4w9WgXcQ")
        #expect(YouTubeLinks.canonicalWatchURL(for: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=5"))
                == video)
        #expect(YouTubeLinks.videoID(in: URL(string: "https://example.com/a.mp3")) == nil)
        #expect(YouTubeLinks.watchURL(videoID: "dQw4w9WgXcQ", at: MediaTime(milliseconds: 83_900))?.absoluteString
                == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=83s")
        #expect(YouTubeLinks.watchURL(videoID: "dQw4w9WgXcQ", at: .zero) == video)
        #expect(YouTubeLinks.watchURL(videoID: "kaputt", at: nil) == nil)
    }

    private let now = Date(timeIntervalSince1970: 1_790_140_000)

    @Test("Mit Schlüssel und ohne Hindernis: Untertitel")
    func captionsFirst() {
        #expect(YouTubeTranscriptPlanner.route(.init(switchedOn: true, hasKey: true, now: now)) == .captions)
    }

    @Test("Ohne Schlüssel: Audio-Podcast, sonst Angebot, sonst nur Metadaten")
    func fallbackOrder() {
        let audio = EpisodeID(rawValue: "audio")
        #expect(YouTubeTranscriptPlanner.route(.init(switchedOn: true, hasKey: false, matchingAudioEpisode: audio,
                                                     hasCounterpartPodcast: true, now: now))
                == .counterpartEpisode(audio, gap: .noKey))
        #expect(YouTubeTranscriptPlanner.route(.init(switchedOn: true, hasKey: false,
                                                     hasCounterpartPodcast: true, now: now))
                == .offerCounterpartPodcast(gap: .noKey))
        #expect(YouTubeTranscriptPlanner.route(.init(switchedOn: true, hasKey: false, now: now))
                == .metadataOnly(gap: .noKey))
    }

    @Test("Abgelehnter Schlüssel, Schalter aus und ruhender Dienst halten Supadata an")
    func gaps() {
        #expect(YouTubeTranscriptPlanner.captionGap(.init(switchedOn: true, hasKey: true, keyRejected: true)) == .keyRejected)
        #expect(YouTubeTranscriptPlanner.captionGap(.init(switchedOn: false, hasKey: true)) == .switchedOff)
        #expect(YouTubeTranscriptPlanner.captionGap(.init(switchedOn: true, hasKey: true, serviceResting: true))
                == .serviceResting)
    }

    @Test("Gescheiterte Videos ruhen, von Hand angefordert geht es sofort wieder")
    func cooldown() {
        let lasting = CaptionFailure(error: .noTranscript, at: now)
        let passing = CaptionFailure(error: .network, at: now)
        #expect(lasting.kind == .lasting)
        #expect(passing.kind == .passing)
        let soon = now.addingTimeInterval(3600)
        #expect(YouTubeTranscriptPlanner.captionGap(.init(switchedOn: true, hasKey: true, lastFailure: lasting, now: soon))
                == .noCaptions)
        #expect(YouTubeTranscriptPlanner.captionGap(.init(switchedOn: true, hasKey: true, lastFailure: passing, now: soon))
                == .coolingDown(until: passing.retryAt))
        #expect(YouTubeTranscriptPlanner.captionGap(.init(switchedOn: true, hasKey: true, lastFailure: lasting,
                                                          requestedByHand: true, now: soon)) == nil)
        let later = now.addingTimeInterval(CaptionFailure.lastingCooldown + 1)
        #expect(YouTubeTranscriptPlanner.captionGap(.init(switchedOn: true, hasKey: true, lastFailure: lasting, now: later))
                == nil)
    }

    @Test("Nach einem Fehler von Supadata greift der Rest der Reihenfolge")
    func fallbackAfterError() {
        let audio = EpisodeID(rawValue: "audio")
        let inputs = YouTubeTranscriptPlanner.Inputs(switchedOn: true, hasKey: true, matchingAudioEpisode: audio, now: now)
        #expect(YouTubeTranscriptPlanner.fallback(after: .noTranscript, inputs: inputs)
                == .counterpartEpisode(audio, gap: .noCaptions))
        #expect(YouTubeTranscriptPlanner.fallback(after: .unauthorized,
                                                  inputs: .init(switchedOn: true, hasKey: true, now: now))
                == .metadataOnly(gap: .keyRejected))
    }

    @Test("Die passende Audiofolge: ähnlicher Titel und nah am Datum, sonst keine")
    func matchesCounterpartEpisode() {
        let day: TimeInterval = 24 * 3600
        func episode(_ id: String, _ title: String, _ offset: TimeInterval?, audio: Bool = true) -> Episode {
            Episode(id: EpisodeID(rawValue: id), sourceID: SourceID(rawValue: "podcast"), title: title,
                    publishedAt: offset.map { now.addingTimeInterval($0) },
                    audioURL: audio ? URL(string: "https://example.com/\(id).mp3") : nil)
        }
        let candidates = [
            episode("a", "Folge 12: Bienen im Winter", 5 * day),
            episode("b", "#12 Bienen im Winter (mit Gast)", 1 * day),
            episode("c", "Etwas ganz anderes", 0),
            episode("d", "Bienen im Winter", 0, audio: false),
        ]
        let match = CounterpartEpisodeMatcher.match(videoTitle: "Bienen im Winter | Folge 12",
                                                    videoPublished: now, in: candidates)
        #expect(match?.id.rawValue == "b")
        #expect(CounterpartEpisodeMatcher.match(videoTitle: "Quantenphysik", videoPublished: now, in: candidates) == nil)
        // Ohne Datum nur bei gleichem Titel.
        let undated = [episode("e", "Bienen im Winter", nil)]
        #expect(CounterpartEpisodeMatcher.match(videoTitle: "Bienen im Winter!", videoPublished: now, in: undated)?.id.rawValue
                == "e")
        #expect(CounterpartEpisodeMatcher.match(videoTitle: "Bienen im Sommer", videoPublished: now, in: undated) == nil)
    }
}
