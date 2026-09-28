//
//  ChatConversation.swift
//  PodcastAIKnowledge
//
//  Eine Unterhaltung im Chat: Fragen und Antworten eines Bereichs in ihrer
//  Reihenfolge, über einen Neustart hinweg und auf allen Geräten.
//
//  Es gibt zwei Arten von Bereichen. Der Chat „Frag deine Podcasts“ führt
//  Unterhaltungen über die Mediathek, auch wenn sich die Eingrenzung
//  zwischen zwei Fragen ändert; jede Antwort trägt ihren eigenen Bereich.
//  Jede Folge hat ihre eigene Unterhaltung, im Reiter „Fragen“ und im Chat,
//  wenn er der laufenden oder einer gewählten Folge folgt. Ihre Kennung
//  folgt aus der Folge (``ChatConversationKey/stableConversationID``). So
//  landen Fragen, die zwei Geräte vor dem Abgleich an dieselbe Folge
//  stellen, in derselben Unterhaltung statt in zwei, von denen eine
//  unsichtbar bliebe.
//
//  Drei Regeln stehen hier im Code:
//
//  - **Folge löschen** (Regel 5): Eine Unterhaltung einer gelöschten Folge
//    geht ganz. In anderen Unterhaltungen verliert eine Antwort die Belege
//    aus der Folge und ihren Text, denn der ist aus diesen Belegen
//    formuliert. Bleibt kein Beleg, geht die Runde, wie bei
//    ``KnowledgeTrail/removing(evidence:)``. „Audio entfernen“ ändert nichts.
//  - **Zuletzt geschrieben gilt.** Ändern zwei Geräte dieselbe Unterhaltung,
//    bevor der Abgleich sie erreicht, gilt die Fassung mit dem jüngeren
//    Stand ganz (``resolved(local:remote:)``). Die Frage des anderen Geräts
//    fehlt dann in dieser Unterhaltung. Das Gerät mit der jüngeren Fassung
//    schreibt sie zurück, falls die Datenbank die ältere hält.
//  - **Fassung im Datensatz.** Die Unterhaltung liegt als JSON mit einer
//    Formatnummer in der Datenbank. Eine ältere App liest eine neuere
//    Fassung, soweit sie sie kennt, und hängt nichts daran an; eine neue
//    Frage beginnt dort eine neue Unterhaltung. Sonst gingen beim nächsten
//    Speichern Felder verloren, die nur die neuere App kennt.
//

import Foundation
import PodcastAICore
import PodcastAIIntelligence

/// Worüber eine Unterhaltung geht: die Mediathek oder eine Folge.
public enum ChatConversationKey: Hashable, Sendable {
    case library
    case episode(EpisodeID)

    /// Fragen an eine Folge gehören zu ihrer Unterhaltung, alles andere zur
    /// Mediathek, gleich wie eingegrenzt.
    public init(scope: ChatScope) {
        if case .episode(let id) = scope { self = .episode(id) } else { self = .library }
    }

    /// So steht der Bereich in der Datenbank.
    public var rawValue: String {
        switch self {
        case .library: "library"
        case .episode(let id): "episode:" + id.rawValue
        }
    }

    public init?(rawValue: String) {
        if rawValue == "library" {
            self = .library
        } else if rawValue.hasPrefix("episode:"), rawValue.count > "episode:".count {
            self = .episode(EpisodeID(rawValue: String(rawValue.dropFirst("episode:".count))))
        } else {
            return nil
        }
    }

    public var episodeID: EpisodeID? {
        if case .episode(let id) = self { return id }
        return nil
    }

    /// Die feste Kennung der Unterhaltung einer Folge, auf jedem Gerät
    /// dieselbe: die ersten 16 Byte aus SHA-256 über den Bereich, als UUID
    /// der Version 8. `nil` für die Mediathek, dort gibt es viele.
    public var stableConversationID: UUID? {
        guard case .episode = self else { return nil }
        let hex = Array(SecureDigest.hex(of: "PodcastAI.ChatConversation." + rawValue))
        guard hex.count >= 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = stride(from: 0, to: 32, by: 2).compactMap { UInt8(String(hex[$0...$0 + 1]), radix: 16) }
        guard bytes.count == 16 else { return nil }
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Eine Runde: die Antwort samt Frage und Bereich.
public struct ChatTurn: Sendable, Identifiable {
    public var answer: ChatAnswer
    /// Der Antworttext ist weg, weil eine Folge gelöscht wurde, auf die er
    /// sich stützte. Frage und übrige Belege bleiben.
    public var isWithdrawn: Bool

    public var id: UUID { answer.id }

    public init(answer: ChatAnswer, isWithdrawn: Bool = false) {
        self.answer = answer
        self.isWithdrawn = isWithdrawn
    }
}

/// Eine Unterhaltung im Chat.
public struct ChatConversation: Sendable, Identifiable {

    /// Das Format, das diese App schreibt.
    public static let formatVersion = 1
    /// Mehr Runden hält eine Unterhaltung nicht. Die ältesten fallen dann weg.
    public static let turnLimit = 200

    public let id: UUID
    public let key: ChatConversationKey
    public private(set) var turns: [ChatTurn]
    public let createdAt: Date
    /// Stand der letzten Änderung. Steigt mit jeder Änderung, auch wenn die
    /// Uhr des Geräts zurückspringt.
    public private(set) var updatedAt: Date
    /// Das Format, in dem die Unterhaltung zuletzt geschrieben wurde.
    public let storedFormat: Int

    /// Ohne `id` bekommt die Unterhaltung einer Folge ihre feste Kennung,
    /// eine der Mediathek eine neue.
    public init(
        id: UUID? = nil, key: ChatConversationKey, turns: [ChatTurn] = [],
        createdAt: Date = Date(), updatedAt: Date? = nil, storedFormat: Int = ChatConversation.formatVersion
    ) {
        self.id = id ?? key.stableConversationID ?? UUID()
        self.key = key
        self.turns = turns
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.storedFormat = storedFormat
    }

    public var isEmpty: Bool { turns.isEmpty }

    /// Von einer neueren App geschrieben: lesen ja, anhängen nein.
    public var isFromNewerVersion: Bool { storedFormat > Self.formatVersion }

    /// Die erste Frage, als Titel in der Liste der Unterhaltungen.
    public var title: String { turns.first?.answer.question ?? "" }

    public var answers: [ChatAnswer] { turns.map(\.answer) }

    /// Der Bereich der letzten Frage.
    public var lastScope: ChatScope? { turns.last?.answer.scope }

    /// Die Eingrenzung, mit der eine Unterhaltung über die Mediathek
    /// weitergeht, wenn sie nach einem Neustart oder aus der Liste wieder
    /// geöffnet wird: die der letzten Frage. Ohne Eingrenzung alles.
    /// `nil` bei einer Folge und ohne Frage.
    public var inheritedFilter: LibraryFilter? {
        guard key == .library, let scope = lastScope else { return nil }
        switch scope {
        case .library(let filter): return filter
        case .allAnalyzed: return LibraryFilter()
        case .episode, .episodes, .smartFeed: return nil
        }
    }

    // MARK: - Ändern

    /// Hängt eine Antwort an. Mehr als ``turnLimit`` Runden hält die
    /// Unterhaltung nicht.
    public mutating func append(_ answer: ChatAnswer, at date: Date = Date()) {
        turns.append(ChatTurn(answer: answer))
        if turns.count > Self.turnLimit { turns.removeFirst(turns.count - Self.turnLimit) }
        touch(date)
    }

    /// Nimmt eine Runde heraus. `false`, wenn es sie nicht gab.
    @discardableResult
    public mutating func removeTurn(_ id: UUID, at date: Date = Date()) -> Bool {
        let before = turns.count
        turns.removeAll { $0.id == id }
        guard turns.count != before else { return false }
        touch(date)
        return true
    }

    /// Wieder geöffnet: Die Unterhaltung gilt als zuletzt benutzt und kommt
    /// nach einem Neustart zurück.
    public mutating func markUsed(at date: Date = Date()) {
        touch(date)
    }

    private mutating func touch(_ date: Date) {
        updatedAt = max(date, updatedAt.addingTimeInterval(0.001))
    }

    // MARK: - Löschen einer Folge

    public enum Pruning: Sendable {
        case unchanged
        case changed(ChatConversation)
        /// Nichts bleibt: Die Unterhaltung galt der Folge, oder keine Runde
        /// hat noch einen Beleg.
        case removed
    }

    /// Die Unterhaltung ohne das, was aus gelöschten Folgen oder Belegen
    /// entstanden ist (Regel 5).
    ///
    /// - Galt die Unterhaltung einer dieser Folgen, geht sie ganz.
    /// - Galt eine Frage einer dieser Folgen, auch als eingegrenzte Folge,
    ///   geht die Runde.
    /// - Stützt sich eine Antwort auf eine dieser Folgen oder nennt ihr Text
    ///   eine, gehen deren Belege und der Text. Bleibt kein Beleg, geht die
    ///   Runde. Sonst bleiben Frage und übrige Belege, als zurückgezogen
    ///   markiert.
    public func pruning(
        removedEpisodes: Set<EpisodeID>, removedEvidence: Set<EvidenceID> = [], at date: Date = Date()
    ) -> Pruning {
        guard !removedEpisodes.isEmpty || !removedEvidence.isEmpty else { return .unchanged }
        if let episode = key.episodeID, removedEpisodes.contains(episode) { return .removed }
        var kept: [ChatTurn] = []
        var changed = false
        for turn in turns {
            switch turn.pruned(removedEpisodes: removedEpisodes, removedEvidence: removedEvidence) {
            case .none:
                changed = true
            case .some(let result):
                if result.changed { changed = true }
                kept.append(result.turn)
            }
        }
        guard changed else { return .unchanged }
        guard !kept.isEmpty else { return .removed }
        var copy = self
        copy.turns = kept
        copy.touch(date)
        return .changed(copy)
    }

    // MARK: - Folgefragen

    /// Die letzten Runden für den Block BISHERIGES GESPRÄCH. Einen Kernsatz
    /// hat nur eine Antwort des Modells, deren Text noch da ist.
    public func historyTurns(limit: Int = ConversationHistory.maximumTurns) -> [ConversationHistory.Turn] {
        turns.suffix(max(0, limit)).map { turn in
            let answer = turn.answer
            let core = turn.isWithdrawn || answer.modelLabel == nil
                ? nil : ConversationHistory.coreSentence(of: answer.text)
            return ConversationHistory.Turn(
                question: answer.question, core: core, evidenceIDs: Self.orderedCitations(of: answer).map(\.id))
        }
    }

    /// Was die nächste Frage von dieser Unterhaltung wissen muss: die
    /// letzten Fragen und die Belege der letzten Antwort, die welche hat.
    public func followUp(limit: Int = ConversationHistory.maximumTurns) -> ChatFollowUp {
        let recent = turns.suffix(max(0, limit))
        let cited = recent.last { !$0.answer.citations.isEmpty }.map { Self.orderedCitations(of: $0.answer) } ?? []
        return ChatFollowUp(
            questions: recent.map(\.answer.question),
            evidenceIDs: cited.map(\.id),
            episodeIDs: Set(cited.map(\.episodeID)))
    }

    /// Die Belege in der Reihenfolge ihrer Verweisnummern, danach die übrigen.
    static func orderedCitations(of answer: ChatAnswer) -> [Evidence] {
        let byID = Dictionary(answer.citations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<EvidenceID> = []
        var ordered = answer.citationNumbers.sorted { $0.key < $1.key }
            .compactMap { byID[$0.value] }
            .filter { seen.insert($0.id).inserted }
        ordered += answer.citations.filter { seen.insert($0.id).inserted }
        return ordered
    }

    // MARK: - Abgleich

    /// Zwei Fassungen derselben Unterhaltung, etwa die im Speicher und die,
    /// die über iCloud kam: Es gilt die mit dem jüngeren Stand, ganz. Bei
    /// gleichem Stand die mit mehr Runden, sonst die eigene.
    public static func resolved(local: ChatConversation, remote: ChatConversation) -> ChatConversation {
        if remote.updatedAt != local.updatedAt { return remote.updatedAt > local.updatedAt ? remote : local }
        return remote.turns.count > local.turns.count ? remote : local
    }
}

// MARK: - Löschen einer Folge je Runde

extension ChatTurn {

    /// `nil`: Die Runde geht. Sonst die Runde und ob sie sich geändert hat.
    func pruned(removedEpisodes: Set<EpisodeID>, removedEvidence: Set<EvidenceID>) -> (turn: ChatTurn, changed: Bool)? {
        let scopeHit = switch answer.scope {
        case .episode(let id): removedEpisodes.contains(id)
        case .episodes(let ids): ids.contains(where: removedEpisodes.contains)
        case .library(let filter): filter.episodeIDs.contains(where: removedEpisodes.contains)
        case .smartFeed, .allAnalyzed: false
        }
        if scopeHit { return nil }
        let kept = answer.citations.filter {
            !removedEpisodes.contains($0.episodeID) && !removedEvidence.contains($0.id)
        }
        let numbersHit = answer.citationNumbers.values.contains(where: removedEvidence.contains)
        let referencedHit = answer.referencedEpisodeIDs.contains(where: removedEpisodes.contains)
        guard kept.count < answer.citations.count || numbersHit || referencedHit else { return (self, false) }
        guard !kept.isEmpty else { return nil }
        let keptIDs = Set(kept.map(\.id))
        let withdrawn = ChatAnswer(
            id: answer.id, question: answer.question, scope: answer.scope, text: "",
            citations: kept, coverageCaveat: answer.coverageCaveat, caveatKind: answer.caveatKind,
            answeredAt: answer.answeredAt, modelLabel: answer.modelLabel,
            citationNumbers: answer.citationNumbers.filter { keptIDs.contains($0.value) },
            referencedEpisodeIDs: answer.referencedEpisodeIDs.filter { !removedEpisodes.contains($0) },
            askedAtPosition: answer.askedAtPosition)
        return (ChatTurn(answer: withdrawn, isWithdrawn: true), true)
    }
}

// MARK: - Liste der Unterhaltungen

/// Eine Zeile in „Frühere Unterhaltungen“, ohne die Runden selbst.
public struct ChatConversationSummary: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let key: ChatConversationKey
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
    public let turnCount: Int

    public init(id: UUID, key: ChatConversationKey, title: String, createdAt: Date, updatedAt: Date, turnCount: Int) {
        self.id = id; self.key = key; self.title = title
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.turnCount = turnCount
    }
}

// MARK: - Gespeicherte Form

extension ChatConversation {

    /// Die Unterhaltung als JSON für die Datenbank.
    public func encoded() throws -> Data {
        try Self.encoder.encode(ConversationPayload(self))
    }

    /// Liest eine gespeicherte Unterhaltung, auch aus einer neueren App.
    /// Unbekannte Felder werden übergangen, fehlende bekommen ihren
    /// Standardwert. Nur ohne Kennung oder bekannten Bereich gibt es keine.
    public static func decoded(from data: Data) throws -> ChatConversation {
        try decoder.decode(ConversationPayload.self, from: data).conversation()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

/// Die Unterhaltung, wie sie als JSON gespeichert wird. Die Namen der
/// Schlüssel sind Teil des Formats und bleiben, auch wenn sich die Typen
/// in der App ändern.
struct ConversationPayload: Codable {
    var format: Int
    var id: UUID
    var key: String
    var createdAt: Date
    var updatedAt: Date
    var turns: [TurnPayload]

    init(_ conversation: ChatConversation) {
        format = ChatConversation.formatVersion
        id = conversation.id
        key = conversation.key.rawValue
        createdAt = conversation.createdAt
        updatedAt = conversation.updatedAt
        turns = conversation.turns.map(TurnPayload.init)
    }

    private enum CodingKeys: String, CodingKey { case format, id, key, createdAt, updatedAt, turns }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(Int.self, forKey: .format) ?? 1
        id = try container.decode(UUID.self, forKey: .id)
        key = try container.decode(String.self, forKey: .key)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSinceReferenceDate: 0)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        // Eine Runde, die sich nicht lesen lässt, fällt weg, die übrigen bleiben.
        turns = try container.decodeIfPresent([Lenient<TurnPayload>].self, forKey: .turns)?.compactMap(\.value) ?? []
    }

    func conversation() throws -> ChatConversation {
        guard let key = ChatConversationKey(rawValue: key) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unbekannter Bereich \(self.key)"))
        }
        return ChatConversation(
            id: id, key: key, turns: turns.map { $0.turn(in: key) },
            createdAt: createdAt, updatedAt: updatedAt, storedFormat: format)
    }
}

/// Liest einen Wert oder übergeht ihn, statt die ganze Liste scheitern zu lassen.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}

struct TurnPayload: Codable {
    var id: UUID
    var question: String
    var scope: ScopePayload?
    var text: String
    var withdrawn: Bool?
    var citations: [Evidence]
    var citationNumbers: [Int: EvidenceID]?
    var referencedEpisodeIDs: [EpisodeID]?
    var caveat: String?
    var caveatKind: String?
    var answeredAt: Date
    var modelLabel: String?
    var askedAtMs: Int64?

    init(_ turn: ChatTurn) {
        let answer = turn.answer
        id = answer.id
        question = answer.question
        scope = ScopePayload(answer.scope)
        text = answer.text
        withdrawn = turn.isWithdrawn ? true : nil
        citations = answer.citations
        citationNumbers = answer.citationNumbers.isEmpty ? nil : answer.citationNumbers
        referencedEpisodeIDs = answer.referencedEpisodeIDs.isEmpty ? nil : answer.referencedEpisodeIDs
        caveat = answer.coverageCaveat
        caveatKind = switch answer.caveatKind {
        case .transcriptCoverage: nil
        case .mentionScope: "mentionScope"
        }
        answeredAt = answer.answeredAt
        modelLabel = answer.modelLabel
        askedAtMs = answer.askedAtPosition?.milliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, question, scope, text, withdrawn, citations, citationNumbers, referencedEpisodeIDs
        case caveat, caveatKind, answeredAt, modelLabel, askedAtMs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        scope = try? container.decodeIfPresent(ScopePayload.self, forKey: .scope)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        withdrawn = try container.decodeIfPresent(Bool.self, forKey: .withdrawn)
        citations = try container.decodeIfPresent([Lenient<Evidence>].self, forKey: .citations)?
            .compactMap(\.value) ?? []
        citationNumbers = try? container.decodeIfPresent([Int: EvidenceID].self, forKey: .citationNumbers)
        referencedEpisodeIDs = try? container.decodeIfPresent([EpisodeID].self, forKey: .referencedEpisodeIDs)
        caveat = try container.decodeIfPresent(String.self, forKey: .caveat)
        caveatKind = try container.decodeIfPresent(String.self, forKey: .caveatKind)
        answeredAt = try container.decodeIfPresent(Date.self, forKey: .answeredAt) ?? Date(timeIntervalSinceReferenceDate: 0)
        modelLabel = try container.decodeIfPresent(String.self, forKey: .modelLabel)
        askedAtMs = try container.decodeIfPresent(Int64.self, forKey: .askedAtMs)
    }

    /// Die Runde. Ein Bereich, den diese App nicht kennt, wird zum Bereich
    /// der Unterhaltung: die Folge oder alles Ausgewertete.
    func turn(in key: ChatConversationKey) -> ChatTurn {
        let fallback: ChatScope = key.episodeID.map { .episode($0) } ?? .allAnalyzed
        let answer = ChatAnswer(
            id: id, question: question, scope: scope?.scope ?? fallback, text: text,
            citations: citations, coverageCaveat: caveat,
            caveatKind: caveatKind == "mentionScope" ? .mentionScope : .transcriptCoverage,
            answeredAt: answeredAt, modelLabel: modelLabel, citationNumbers: citationNumbers ?? [:],
            referencedEpisodeIDs: referencedEpisodeIDs ?? [],
            askedAtPosition: askedAtMs.map { MediaTime(milliseconds: $0) })
        return ChatTurn(answer: answer, isWithdrawn: withdrawn ?? false)
    }
}

/// Der Bereich einer Frage. Mengen stehen sortiert da, damit dieselbe
/// Unterhaltung immer dasselbe JSON ergibt.
struct ScopePayload: Codable {
    var kind: String
    var episodeIDs: [EpisodeID]?
    var smartFeedID: SmartFeedID?
    var sourceIDs: [SourceID]?
    var period: String?
    var since: Date?
    var before: Date?
    var tagIDs: [InterestID]?

    init(_ scope: ChatScope) {
        switch scope {
        case .episode(let id):
            kind = "episode"
            episodeIDs = [id]
        case .episodes(let ids):
            kind = "episodes"
            episodeIDs = ids
        case .smartFeed(let id):
            kind = "smartFeed"
            smartFeedID = id
        case .allAnalyzed:
            kind = "allAnalyzed"
        case .library(let filter):
            kind = "library"
            sourceIDs = filter.sourceIDs.isEmpty ? nil : filter.sourceIDs.sorted { $0.rawValue < $1.rawValue }
            period = filter.period == .all ? nil : filter.period.rawValue
            since = filter.since
            before = filter.before
            tagIDs = filter.tagIDs.isEmpty ? nil : filter.tagIDs.sorted { $0.rawValue < $1.rawValue }
            episodeIDs = filter.episodeIDs.isEmpty ? nil : filter.episodeIDs.sorted { $0.rawValue < $1.rawValue }
        }
    }

    /// `nil` bei einer Art, die diese App nicht kennt.
    var scope: ChatScope? {
        switch kind {
        case "episode": return episodeIDs?.first.map { .episode($0) }
        case "episodes": return .episodes(episodeIDs ?? [])
        case "smartFeed": return smartFeedID.map { .smartFeed($0) }
        case "allAnalyzed": return .allAnalyzed
        case "library":
            return .library(LibraryFilter(
                sourceIDs: Set(sourceIDs ?? []),
                period: period.flatMap(LibraryFilter.Period.init(rawValue:)) ?? .all,
                since: since, before: before,
                tagIDs: Set(tagIDs ?? []), episodeIDs: Set(episodeIDs ?? [])))
        default: return nil
        }
    }
}
