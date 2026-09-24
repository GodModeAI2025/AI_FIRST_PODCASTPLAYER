//
//  SupadataTranscriptClient.swift
//  PodcastAISources
//
//  Holt vorhandene Untertitel eines YouTube-Videos über Supadata.
//
//  Supadata ist ein unabhängiger Dienst. Wer einen eigenen Schlüssel hat,
//  trägt ihn in den Einstellungen ein; ohne Schlüssel fragt die App dort
//  nie an. Angefragt wird nur `mode=native`, also Untertitel, die es beim
//  Video schon gibt. Supadata soll nichts mit eigener KI erzeugen, denn als
//  Sprachmodell arbeitet in dieser App nur Apple Intelligence.
//
//  Was hier robust sein muss:
//
//  * Wiederholt wird nur, was sich lohnt: 429, 5xx und Netzfehler, höchstens
//    dreimal, mit wachsender Pause und etwas Zufall.
//  * Lange Videos beantwortet Supadata mit 202 und einer Auftragsnummer.
//    Der Client fragt nach, bis zu einer festen Gesamtfrist, und merkt sich
//    den Auftrag, damit ein späterer Versuch weiterfragt statt neu zu bestellen.
//  * Ein abgelehnter Schlüssel (401) oder ein aufgebrauchtes Kontingent
//    öffnet den Schutzschalter. Danach geht keine Anfrage mehr raus, bis
//    die Wartezeit um ist oder jemand einen neuen Schlüssel einträgt. So
//    hämmert die Warteschlange nicht Folge um Folge gegen den Dienst.
//  * Der Schlüssel steht nie in einer Fehlermeldung und nie im Protokoll.
//

import Foundation
import PodcastAICore

// MARK: - Antworten

/// Eine Zeile der Untertitel, so wie Supadata sie liefert: Zeit in
/// Millisekunden ab Videobeginn.
public struct SupadataCaption: Hashable, Sendable {
    public let text: String
    public let offsetMilliseconds: Int64
    public let durationMilliseconds: Int64
    public let lang: String?

    public init(text: String, offsetMilliseconds: Int64, durationMilliseconds: Int64, lang: String? = nil) {
        self.text = text
        self.offsetMilliseconds = offsetMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.lang = lang
    }
}

/// Die Untertitel eines Videos in einer Sprache.
public struct SupadataTranscript: Hashable, Sendable {
    /// Sprache der gelieferten Untertitel, etwa „en“.
    public let lang: String?
    /// In welchen Sprachen das Video Untertitel hat.
    public let availableLangs: [String]
    public let captions: [SupadataCaption]

    public init(lang: String?, availableLangs: [String], captions: [SupadataCaption]) {
        self.lang = lang
        self.availableLangs = availableLangs
        self.captions = captions
    }
}

/// Was `GET /me` über das Konto sagt. Die Organisation lässt die App weg,
/// sie braucht sie nicht.
public struct SupadataAccount: Hashable, Sendable {
    public let plan: String?
    public let maxCredits: Int?
    public let usedCredits: Int?

    public init(plan: String?, maxCredits: Int?, usedCredits: Int?) {
        self.plan = plan
        self.maxCredits = maxCredits
        self.usedCredits = usedCredits
    }

    /// Das Kontingent dieses Abrechnungszeitraums ist aufgebraucht.
    public var isExhausted: Bool {
        guard let maxCredits, let usedCredits, maxCredits > 0 else { return false }
        return usedCredits >= maxCredits
    }
}

// MARK: - Fehler

public enum SupadataError: Error, Equatable, Sendable, LocalizedError {
    /// Kein Schlüssel eingetragen. Dann fragt die App gar nicht erst.
    case missingKey
    /// 401: Supadata kennt den Schlüssel nicht (mehr).
    case unauthorized
    /// 404 oder ein Video, das es nicht gibt.
    case notFound
    /// Das Video hat keine Untertitel (206, leerer Inhalt, `transcript-unavailable`).
    case noTranscript
    /// 429: zu viele Anfragen. `retryAfter` in Sekunden, falls genannt.
    case rateLimited(retryAfter: TimeInterval?)
    /// 402 oder `upgrade-required`: Kontingent aufgebraucht.
    case quota
    /// 403 oder `forbidden`: für dieses Video nicht erlaubt, etwa privat.
    case forbidden
    /// 400: Supadata versteht die Anfrage nicht.
    case invalidRequest
    /// 5xx oder ein Status, den der Client nicht kennt.
    case server(status: Int)
    /// Keine Verbindung, Zeitüberschreitung einer einzelnen Anfrage.
    case network
    /// Die Antwort ließ sich nicht lesen oder war zu groß.
    case decoding
    /// Der Auftrag für ein langes Video ist bei Supadata gescheitert.
    case jobFailed
    /// Die Gesamtfrist ist um, der Auftrag läuft womöglich noch.
    case timeout
    /// Die Arbeit wurde abgebrochen, etwa weil die Folge gelöscht wurde.
    case cancelled

    /// Bringt ein späterer Versuch etwas? Dann versucht die Warteschlange es
    /// noch einmal, sonst merkt sie sich das Video als erledigt.
    public var isTransient: Bool {
        switch self {
        // Eine unlesbare Antwort kann an Supadata liegen, nicht am Video.
        case .rateLimited, .server, .network, .timeout, .jobFailed, .cancelled, .decoding: true
        case .missingKey, .unauthorized, .notFound, .noTranscript, .quota, .forbidden,
             .invalidRequest: false
        }
    }

    /// Betrifft der Fehler den Schlüssel oder das Konto und damit jedes
    /// Video, nicht nur dieses?
    public var affectsAccount: Bool {
        switch self {
        case .missingKey, .unauthorized, .quota: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            String(localized: "Für YouTube-Transkripte ist kein Supadata-Schlüssel eingetragen.", bundle: .module)
        case .unauthorized:
            String(localized: "Supadata hat den Schlüssel abgelehnt.", bundle: .module)
        case .notFound:
            String(localized: "Supadata findet dieses Video nicht.", bundle: .module)
        case .noTranscript:
            String(localized: "Zu diesem Video gibt es keine Untertitel.", bundle: .module)
        case .rateLimited:
            String(localized: "Supadata bittet um eine Pause. Die App versucht es später noch einmal.", bundle: .module)
        case .quota:
            String(localized: "Das Kontingent bei Supadata ist aufgebraucht.", bundle: .module)
        case .forbidden:
            String(localized: "Für dieses Video gibt Supadata keine Untertitel heraus.", bundle: .module)
        case .invalidRequest:
            String(localized: "Supadata konnte mit der Anfrage nichts anfangen.", bundle: .module)
        case .server:
            String(localized: "Supadata antwortet gerade nicht richtig.", bundle: .module)
        case .network:
            String(localized: "Keine Verbindung zu Supadata.", bundle: .module)
        case .decoding:
            String(localized: "Die Antwort von Supadata ließ sich nicht lesen.", bundle: .module)
        case .jobFailed:
            String(localized: "Supadata konnte die Untertitel nicht zusammenstellen.", bundle: .module)
        case .timeout:
            String(localized: "Supadata braucht für dieses Video länger. Die App fragt später noch einmal nach.",
                   bundle: .module)
        case .cancelled:
            String(localized: "Abgebrochen.", bundle: .module)
        }
    }
}

// MARK: - Transport

/// Antwort eines Abrufs, ohne Urteil über den Status.
public struct SupadataHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    /// Kopfzeile `Retry-After` in Sekunden, falls der Dienst sie nennt.
    public let retryAfter: TimeInterval?

    public init(status: Int, body: Data, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }
}

/// Holt eine Adresse mit Kopfzeilen. Im Betrieb über `SafeHTTP`, in Tests
/// aus festen Antworten.
public typealias SupadataTransport = @Sendable (_ url: URL, _ headers: [String: String]) async throws -> SupadataHTTPResponse

// MARK: - Client

public actor SupadataTranscriptClient {

    public struct Configuration: Sendable {
        public var baseURL: URL
        /// Wiederholungen nach dem ersten Versuch, nur bei 429, 5xx und Netzfehlern.
        public var maxRetries: Int
        public var initialBackoff: TimeInterval
        public var maxBackoff: TimeInterval
        /// Abstand zwischen zwei Nachfragen zu einem laufenden Auftrag.
        public var pollInterval: TimeInterval
        /// Gesamtfrist für ein Video, Wiederholungen und Nachfragen eingeschlossen.
        /// Kurz genug, dass eine YouTube-Folge die Warteschlange nicht lange aufhält.
        public var deadline: TimeInterval
        /// So lange ruht der Client nach aufgebrauchtem Kontingent.
        public var quotaCooldown: TimeInterval
        /// So lange ruht er, wenn Supadata auch nach allen Wiederholungen drosselt.
        public var rateLimitCooldown: TimeInterval
        /// Obergrenze einer Antwort. Ein Video von zehn Stunden bleibt darunter.
        public var responseLimit: Int64

        public init(
            baseURL: URL = URL(string: "https://api.supadata.ai/v1")!,
            maxRetries: Int = 3,
            initialBackoff: TimeInterval = 1,
            maxBackoff: TimeInterval = 20,
            pollInterval: TimeInterval = 3,
            deadline: TimeInterval = 90,
            quotaCooldown: TimeInterval = 6 * 3600,
            rateLimitCooldown: TimeInterval = 15 * 60,
            responseLimit: Int64 = 16 * 1024 * 1024
        ) {
            self.baseURL = baseURL
            self.maxRetries = maxRetries
            self.initialBackoff = initialBackoff
            self.maxBackoff = maxBackoff
            self.pollInterval = pollInterval
            self.deadline = deadline
            self.quotaCooldown = quotaCooldown
            self.rateLimitCooldown = rateLimitCooldown
            self.responseLimit = responseLimit
        }
    }

    /// Der Schutzschalter. Offen heißt: keine Anfrage, bis `until` vorbei
    /// ist. Ohne `until` bleibt er offen, bis `resetBreaker()` kommt, also
    /// bis ein neuer Schlüssel eingetragen ist.
    public enum Breaker: Equatable, Sendable {
        case closed
        case open(reason: SupadataError, until: Date?)
    }

    public nonisolated let configuration: Configuration
    private let transport: SupadataTransport
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let clock: @Sendable () -> Date
    private let random: @Sendable () -> Double

    public private(set) var breaker: Breaker = .closed
    /// Laufende Aufträge je Video und Sprache. Ein späterer Versuch fragt
    /// dort nach, statt das Video noch einmal zu bestellen.
    private var pendingJobs: [String: String] = [:]
    /// Metadaten je Adresse, für die Dauer der Sitzung.
    private var metadataCache: [String: SupadataMetadata] = [:]

    public init(
        configuration: Configuration = Configuration(),
        transport: @escaping SupadataTransport = SupadataTranscriptClient.liveTransport(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        clock: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.sleep = sleep
        self.clock = clock
        self.random = random
    }

    /// Über `SafeHTTP`: Adressprüfung, keine Cookies, Obergrenze beim Laden.
    public static func liveTransport(responseLimit: Int64 = 16 * 1024 * 1024) -> SupadataTransport {
        let session = SafeHTTP.makeSession { configuration in
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
        }
        return { url, headers in
            let (data, response) = try await SafeHTTP.loadResponse(url, using: session, limit: responseLimit,
                                                                     headers: headers)
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return SupadataHTTPResponse(status: response.statusCode, body: data, retryAfter: retryAfter)
        }
    }

    /// Ein neuer Schlüssel: alles, was der alte ausgelöst hat, ist vergessen.
    public func resetBreaker() {
        breaker = .closed
        pendingJobs.removeAll()
    }

    /// Ist der Schutzschalter gerade offen? Nach Ablauf der Wartezeit schließt er sich.
    public func openBreakerReason() -> SupadataError? {
        guard case .open(let reason, let until) = breaker else { return nil }
        if let until, clock() >= until {
            breaker = .closed
            return nil
        }
        return reason
    }

    // MARK: Untertitel

    /// Die Untertitel eines Videos, bevorzugt in einer der `preferredLanguages`.
    ///
    /// Erst eine Anfrage ohne Sprache: Supadata liefert dann die Sprache des
    /// Videos und nennt, welche es noch gibt. Steht die bevorzugte Sprache
    /// darunter und ist es nicht schon diese, folgt eine zweite Anfrage.
    /// Scheitert die zweite, bleibt es bei der ersten.
    public func transcript(
        videoURL: URL, apiKey: String, preferredLanguages: [String]
    ) async throws(SupadataError) -> SupadataTranscript {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw .missingKey }
        let start = clock()
        let first = try await fetch(videoURL: videoURL, lang: nil, apiKey: key, startedAt: start)
        guard let wanted = SupadataLanguage.preferred(
            among: first.availableLangs, current: first.lang, preferred: preferredLanguages) else {
            return first
        }
        do {
            let second = try await fetch(videoURL: videoURL, lang: wanted, apiKey: key, startedAt: start)
            return second.captions.isEmpty ? first : second
        } catch where !error.affectsAccount {
            return first
        }
    }

    /// Prüft den Schlüssel mit `GET /me`. Das kostet keine Untertitel.
    public func account(apiKey: String) async throws(SupadataError) -> SupadataAccount {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw .missingKey }
        let url = configuration.baseURL.appending(path: "me")
        let response = try await send(url, apiKey: key, startedAt: clock())
        switch response.status {
        case 200:
            guard let decoded = try? JSONDecoder().decode(AccountBody.self, from: response.body) else {
                throw .decoding
            }
            let account = SupadataAccount(plan: decoded.plan, maxCredits: decoded.maxCredits,
                                          usedCredits: decoded.usedCredits)
            // Eine erfolgreiche Prüfung hebt einen alten Schutzschalter auf.
            breaker = .closed
            return account
        default:
            throw failure(for: response)
        }
    }

    // MARK: Für Erweiterungen in diesem Modul

    func cachedMetadata(for url: URL) -> SupadataMetadata? { metadataCache[url.absoluteString] }

    func rememberMetadata(_ metadata: SupadataMetadata, for url: URL) {
        if metadataCache.count > 500 { metadataCache.removeAll() }
        metadataCache[url.absoluteString] = metadata
    }

    /// Eine Anfrage mit denselben Regeln wie für Untertitel: Schutzschalter,
    /// Wiederholungen, Frist.
    func sendRequest(_ url: URL, apiKey: String) async throws(SupadataError) -> SupadataHTTPResponse {
        try await send(url, apiKey: apiKey, startedAt: clock())
    }

    // MARK: Ablauf

    private func fetch(
        videoURL: URL, lang: String?, apiKey: String, startedAt: Date
    ) async throws(SupadataError) -> SupadataTranscript {
        let jobKey = videoURL.absoluteString + "|" + (lang ?? "")
        if let jobID = pendingJobs[jobKey] {
            do {
                let result = try await poll(jobID: jobID, apiKey: apiKey, startedAt: startedAt)
                pendingJobs[jobKey] = nil
                return result
            } catch .notFound {
                // Supadata kennt den Auftrag nicht mehr: neu bestellen.
                pendingJobs[jobKey] = nil
            } catch {
                if error != .timeout && error != .cancelled { pendingJobs[jobKey] = nil }
                throw error
            }
        }

        guard var components = URLComponents(url: configuration.baseURL.appending(path: "transcript"),
                                             resolvingAgainstBaseURL: false) else { throw .invalidRequest }
        var items = [
            URLQueryItem(name: "url", value: videoURL.absoluteString),
            URLQueryItem(name: "mode", value: "native"),
        ]
        if let lang { items.append(URLQueryItem(name: "lang", value: lang)) }
        components.queryItems = items
        guard let url = components.url else { throw .invalidRequest }

        let response = try await send(url, apiKey: apiKey, startedAt: startedAt)
        switch response.status {
        case 200:
            return try SupadataDecoding.transcript(from: response.body)
        case 202:
            guard let jobID = SupadataDecoding.jobID(from: response.body) else { throw .decoding }
            pendingJobs[jobKey] = jobID
            do {
                let result = try await poll(jobID: jobID, apiKey: apiKey, startedAt: startedAt)
                pendingJobs[jobKey] = nil
                return result
            } catch {
                // Nur ein noch laufender Auftrag bleibt gemerkt.
                if error != .timeout && error != .cancelled { pendingJobs[jobKey] = nil }
                throw error
            }
        default:
            throw failure(for: response)
        }
    }

    /// Fragt einen Auftrag ab, bis er fertig oder gescheitert ist oder die Frist um ist.
    private func poll(jobID: String, apiKey: String, startedAt: Date) async throws(SupadataError) -> SupadataTranscript {
        let safeID = jobID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safeID.isEmpty else { throw .decoding }
        let url = configuration.baseURL.appending(path: "transcript").appending(path: safeID)
        while true {
            let response = try await send(url, apiKey: apiKey, startedAt: startedAt)
            if response.status == 202 {
                try await pause(configuration.pollInterval, startedAt: startedAt)
                continue
            }
            guard response.status == 200 else { throw failure(for: response) }
            switch try SupadataDecoding.job(from: response.body) {
            case .completed(let transcript):
                return transcript
            case .failed(let code):
                throw SupadataDecoding.error(forCode: code) ?? .jobFailed
            case .running:
                try await pause(configuration.pollInterval, startedAt: startedAt)
            }
        }
    }

    /// Eine Anfrage mit Wiederholungen. Gibt jede Antwort zurück, deren
    /// Status der Aufrufer deutet; wiederholt nur 429 und 5xx.
    private func send(_ url: URL, apiKey: String, startedAt: Date) async throws(SupadataError) -> SupadataHTTPResponse {
        if let reason = openBreakerReason() { throw reason }
        var attempt = 0
        while true {
            if Task.isCancelled { throw .cancelled }
            let response: SupadataHTTPResponse
            do {
                response = try await transport(url, ["x-api-key": apiKey, "Accept": "application/json"])
            } catch is CancellationError {
                throw .cancelled
            } catch let error as HTTPTransferError {
                // Zu groß oder ein Ziel, das die App nicht abruft: ein zweiter
                // Versuch änderte nichts.
                if case .tooLarge = error { throw .decoding }
                throw .network
            } catch {
                if (error as? URLError)?.code == .cancelled || Task.isCancelled { throw .cancelled }
                guard attempt < configuration.maxRetries else { throw .network }
                try await pause(backoff(attempt), startedAt: startedAt)
                attempt += 1
                continue
            }

            let status = response.status
            // Schlüssel oder Konto: kein zweiter Versuch, Schutzschalter auf.
            // Auch ein 429 kann ein aufgebrauchtes Kontingent melden.
            let mapped = (200..<300).contains(status) ? nil : failure(for: response)
            if mapped == .unauthorized || mapped == .quota {
                breaker = .open(reason: mapped!,
                                until: mapped == .unauthorized ? nil : clock().addingTimeInterval(configuration.quotaCooldown))
                throw mapped!
            }
            if status == 429 || (500..<600).contains(status) {
                guard attempt < configuration.maxRetries else {
                    if status == 429 { openForRateLimit(retryAfter: response.retryAfter) }
                    throw failure(for: response)
                }
                var wait = backoff(attempt)
                if let retryAfter = response.retryAfter, retryAfter > wait { wait = retryAfter }
                // Länger warten, als die Frist hergibt, lohnt nicht.
                if clock().timeIntervalSince(startedAt) + wait > configuration.deadline {
                    if status == 429 { openForRateLimit(retryAfter: response.retryAfter) }
                    throw failure(for: response)
                }
                try await pause(wait, startedAt: startedAt)
                attempt += 1
                continue
            }
            return response
        }
    }

    private func openForRateLimit(retryAfter: TimeInterval?) {
        let wait = max(retryAfter ?? 0, configuration.rateLimitCooldown)
        breaker = .open(reason: .rateLimited(retryAfter: retryAfter), until: clock().addingTimeInterval(wait))
    }

    /// Wartet, sofern die Frist das zulässt, und bricht bei Abbruch ab.
    private func pause(_ seconds: TimeInterval, startedAt: Date) async throws(SupadataError) {
        if clock().timeIntervalSince(startedAt) + seconds > configuration.deadline { throw .timeout }
        do {
            try await sleep(seconds)
        } catch {
            throw .cancelled
        }
        if Task.isCancelled { throw .cancelled }
    }

    /// Exponentiell wachsende Pause mit Zufall zwischen halber und ganzer Länge.
    nonisolated func backoff(_ attempt: Int) -> TimeInterval {
        Self.backoff(attempt: attempt, initial: configuration.initialBackoff,
                     maximum: configuration.maxBackoff, random: random())
    }

    /// Rein und prüfbar: `initial · 2^attempt`, gedeckelt, mal `0,5 … 1`.
    public static func backoff(attempt: Int, initial: TimeInterval, maximum: TimeInterval, random: Double) -> TimeInterval {
        let exponent = min(max(attempt, 0), 16)
        let base = min(maximum, initial * pow(2, Double(exponent)))
        let jitter = 0.5 + 0.5 * min(max(random, 0), 1)
        return base * jitter
    }

    /// Deutet einen Status, der kein Erfolg ist.
    private func failure(for response: SupadataHTTPResponse) -> SupadataError {
        SupadataDecoding.error(status: response.status, body: response.body, retryAfter: response.retryAfter)
    }

    private struct AccountBody: Decodable {
        let plan: String?
        let maxCredits: Int?
        let usedCredits: Int?
    }
}

// MARK: - Sprache

public enum SupadataLanguage {

    /// Welche Sprache eine zweite Anfrage holen soll, oder `nil`, wenn die
    /// erste Antwort schon passt.
    ///
    /// Bevorzugt ist die Sprache der App, sofern das Video Untertitel in ihr
    /// hat. Sonst bleibt es bei der Sprache des Videos. Verglichen wird nur
    /// der Sprachteil: „de-DE“ passt zu „de“.
    public static func preferred(among available: [String], current: String?, preferred: [String]) -> String? {
        let currentBase = current.map(base)
        for language in preferred {
            let wanted = base(language)
            guard !wanted.isEmpty else { continue }
            if wanted == currentBase { return nil }
            if let match = available.first(where: { base($0) == wanted }) { return match }
        }
        return nil
    }

    /// „de-DE“, „de_DE“ und „DE“ werden zu „de“.
    public static func base(_ identifier: String) -> String {
        String(identifier.lowercased().prefix { $0.isLetter })
    }
}

// MARK: - Lesen der Antworten

public enum SupadataDecoding {

    public enum JobState: Equatable, Sendable {
        case running
        case completed(SupadataTranscript)
        case failed(code: String?)
    }

    private struct Chunk: Decodable {
        let text: String?
        let offset: Double?
        let duration: Double?
        let lang: String?
    }

    private struct Body: Decodable {
        let lang: String?
        let availableLangs: [String]?
        let content: Content?
        let status: String?
        let jobId: String?
        let error: ErrorField?
    }

    /// `content` ist eine Liste von Zeilen oder, mit `text=true`, reiner Text.
    private enum Content: Decodable {
        case chunks([Chunk])
        case text(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let chunks = try? container.decode([Chunk].self) {
                self = .chunks(chunks)
            } else {
                self = .text(try container.decode(String.self))
            }
        }
    }

    /// `error` ist mal ein Code, mal ein Objekt mit Code.
    private enum ErrorField: Decodable {
        case code(String)
        case object(code: String?)

        var code: String? {
            switch self {
            case .code(let value): value
            case .object(let value): value
            }
        }

        private struct Nested: Decodable { let error: String? }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .code(value)
            } else {
                self = .object(code: try container.decode(Nested.self).error)
            }
        }
    }

    /// 200: die Untertitel. Leer heißt: keine Untertitel.
    public static func transcript(from data: Data) throws(SupadataError) -> SupadataTranscript {
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw .decoding }
        return try transcript(from: body)
    }

    private static func transcript(from body: Body) throws(SupadataError) -> SupadataTranscript {
        let captions: [SupadataCaption]
        switch body.content {
        case .chunks(let chunks)?:
            captions = chunks.compactMap { chunk in
                guard let text = chunk.text, let offset = chunk.offset, offset.isFinite, offset >= 0 else {
                    return nil
                }
                let duration = chunk.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
                return SupadataCaption(
                    text: text,
                    offsetMilliseconds: MediaTime(seconds: offset / 1000).milliseconds,
                    durationMilliseconds: MediaDuration(seconds: duration / 1000).milliseconds,
                    lang: chunk.lang)
            }
        case .text?:
            // Reiner Text trägt keine Zeitmarken. Ohne sie gibt es keinen Beleg.
            captions = []
        case nil:
            // Gar kein Inhalt heißt nicht „keine Untertitel“, sondern eine
            // Antwort in unerwarteter Form. Das Video soll dafür nicht eine
            // Woche lang als ohne Untertitel gelten.
            throw .decoding
        }
        guard !captions.isEmpty else { throw .noTranscript }
        return SupadataTranscript(lang: body.lang, availableLangs: body.availableLangs ?? [], captions: captions)
    }

    /// 202: die Nummer des Auftrags.
    public static func jobID(from data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(Body.self, from: data),
              let id = body.jobId, !id.isEmpty else { return nil }
        return id
    }

    /// Antwort auf `GET /transcript/{jobId}`.
    public static func job(from data: Data) throws(SupadataError) -> JobState {
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw .decoding }
        switch body.status?.lowercased() {
        case "queued", "active":
            return .running
        case "failed":
            return .failed(code: body.error?.code)
        case "completed", nil:
            // Ohne Status, aber mit Inhalt: so antwortet Supadata auch.
            return .completed(try transcript(from: body))
        default:
            return .running
        }
    }

    /// Ein bekannter Fehlercode von Supadata.
    public static func error(forCode code: String?) -> SupadataError? {
        switch code?.lowercased() {
        case "unauthorized"?: .unauthorized
        case "upgrade-required"?: .quota
        case "limit-exceeded"?: .rateLimited(retryAfter: nil)
        case "not-found"?: .notFound
        case "transcript-unavailable"?: .noTranscript
        case "forbidden"?: .forbidden
        case "invalid-request"?: .invalidRequest
        case "internal-error"?: .server(status: 500)
        default: nil
        }
    }

    /// Deutet einen Status samt Inhalt.
    public static func error(status: Int, body: Data, retryAfter: TimeInterval?) -> SupadataError {
        let code = (try? JSONDecoder().decode(Body.self, from: body))?.error?.code
        switch status {
        case 206: return .noTranscript
        case 400: return error(forCode: code) ?? .invalidRequest
        case 401: return .unauthorized
        case 402: return .quota
        case 403: return .forbidden
        case 404: return .notFound
        case 429:
            // Manche Konten melden das aufgebrauchte Kontingent als 429.
            if error(forCode: code) == .quota { return .quota }
            return .rateLimited(retryAfter: retryAfter)
        case 500..<600: return .server(status: status)
        default:
            if let known = error(forCode: code) { return known }
            return .server(status: status)
        }
    }
}
