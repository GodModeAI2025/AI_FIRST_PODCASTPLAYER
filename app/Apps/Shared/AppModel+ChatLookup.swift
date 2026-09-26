//
//  AppModel+ChatLookup.swift
//  PodcastAI
//
//  Der Chat schlägt selbst nach. Reichen die Stellen, die der Code vor der
//  Antwort ausgewählt hat, nicht aus, holt sich das Modell über Werkzeuge
//  weitere Stellen, die Fakten, die Nennungen oder die Kapitel einer Folge
//  (`ChatLookupLedger`, `ChatLookupTools` im Paket). Hier steht, was die
//  App dafür beiträgt:
//
//    - die Quelle der Werkzeuge. Sie liest nur, und nur im Bereich der
//      Frage: aus den Belegen, die für die Frage schon geladen sind, aus der
//      Datenbank, den erkannten Nennungen und den Kapiteln einer Folge. Was
//      seit Beginn der Frage gelöscht wurde, liefert sie nicht mehr (Regel 5).
//    - die Anzeige „Sucht weitere Stellen …“, solange ein Werkzeug läuft.
//    - den Aufruf des Extraktors mit dem Verzeichnis der Folgen vorn im
//      Kontext.
//
//  Jede Anfrage an das Modell geht wie bisher durch `AIScheduler`, als
//  Anfrage eines Menschen. Die Werkzeuge laufen innerhalb dieser Anfrage und
//  rufen selbst kein Modell. Kennungen prüft das Buch im Paket (Regel 3),
//  Ergebnisse sind dort als Daten gekennzeichnet (Regel 2). Ton entsteht
//  nirgends (Regel 1).
//

import Foundation
import Observation
import Synchronization
import SwiftUI
import PodcastAIKit

// MARK: - Anzeige

/// Was der Chat gerade nachschlägt. Nur für die Karte der offenen Frage.
///
/// Das Buch meldet aus dem Werkzeug heraus, auf einem beliebigen Faden, mit
/// einer steigenden Zahl. Eine Meldung, die verspätet ankommt, oder eine
/// Meldung zu einer Frage, die schon beantwortet oder abgebrochen ist,
/// ändert nichts mehr.
@MainActor
@Observable
final class ChatLookupStatus {

    static let shared = ChatLookupStatus()

    private(set) var kind: ChatLookupKind?
    @ObservationIgnored private var question: Int?
    @ObservationIgnored private var sequence = 0

    func begin(question number: Int) {
        question = number
        sequence = 0
        if kind != nil { kind = nil }
    }

    func report(_ reported: ChatLookupKind?, sequence reportedSequence: Int, question number: Int) {
        guard question == number, reportedSequence > sequence else { return }
        sequence = reportedSequence
        if kind != reported { kind = reported }
    }

    func end(question number: Int) {
        guard question == number else { return }
        question = nil
        if kind != nil { kind = nil }
    }
}

extension ChatLookupKind {
    /// Die ruhige Zeile auf der Karte der offenen Frage.
    var status: LocalizedStringKey {
        switch self {
        case .passages: "Sucht weitere Stellen …"
        case .facts: "Liest die Fakten der Folge …"
        case .mentions: "Sucht Nennungen in der Folge …"
        case .chapters: "Liest die Kapitel der Folge …"
        }
    }
}

// MARK: - Quelle der Werkzeuge

/// Woher die Werkzeuge des Chats lesen, im Bereich einer Frage.
///
/// Die Folgen des Bereichs sind die Folgen der Belege, die die Frage
/// ohnehin geladen hat. Der Code hat sie schon eingegrenzt, auf eine Folge,
/// einen Podcast oder einen Zeitraum; das Modell kommt nicht darüber hinaus.
/// Nennungen, Kapitel und was gelöscht wurde kennt nur das `AppModel`,
/// dorthin gehen drei Aufrufe auf den Hauptakteur.
final class LibraryLookupSource: ChatLookupSource {

    let episodes: Set<EpisodeID>
    private let pool: [Evidence]
    private let titles: [EpisodeID: String]
    /// Der Podcast jeder Folge im Bereich, um eine Abbestellung zu erkennen.
    private let podcasts: [EpisodeID: SourceID]
    private let store: LibraryStore
    private let removed: @Sendable (Set<EpisodeID>, [EpisodeID: SourceID]) async -> Set<EpisodeID>
    private let mentionsOf: @Sendable (EpisodeID) async -> [ChatLookupMention]
    private let chaptersOf: @Sendable (EpisodeID) async -> [ChatLookupChapter]
    /// Kapitel ohne Feed rechnet der Code aus Satzvektoren. Einmal je Frage genügt.
    private let chapterCache = Mutex<[EpisodeID: [ChatLookupChapter]]>([:])

    /// Wie viele Stellen bei einer Suche eine Satzeinbettung bekommen. Das
    /// Modell wartet währenddessen.
    static let embeddingLimit = 16

    init(pool: [Evidence], titles: [EpisodeID: String], store: LibraryStore,
         removed: @escaping @Sendable (Set<EpisodeID>, [EpisodeID: SourceID]) async -> Set<EpisodeID>,
         mentionsOf: @escaping @Sendable (EpisodeID) async -> [ChatLookupMention],
         chaptersOf: @escaping @Sendable (EpisodeID) async -> [ChatLookupChapter]) {
        self.episodes = Set(pool.map(\.episodeID))
        self.pool = pool
        self.titles = titles
        self.podcasts = Dictionary(pool.map { ($0.episodeID, $0.sourceID) }, uniquingKeysWith: { first, _ in first })
        self.store = store
        self.removed = removed
        self.mentionsOf = mentionsOf
        self.chaptersOf = chaptersOf
    }

    func title(of episode: EpisodeID) async -> String? { titles[episode] }

    /// Die Belege im Bestand der Frage stammen von ihrem Anfang. Eine Folge
    /// zählt nur, solange die Datenbank sie noch hat und das `AppModel` sie
    /// seitdem nicht zum Löschen vorgemerkt hat; das geschieht vor dem
    /// Löschen in der Datenbank. Scheitert das Lesen, zählt keine.
    func available(_ ids: Set<EpisodeID>) async -> Set<EpisodeID> {
        guard !ids.isEmpty else { return [] }
        let stored = Set(((try? await store.episodes(ids: Array(ids))) ?? []).map(\.id)).intersection(ids)
        guard !stored.isEmpty else { return [] }
        return stored.subtracting(await removed(stored, podcasts))
    }

    func passages(matching query: String, in episode: EpisodeID?, within range: MediaTimeRange?,
                  excluding known: Set<EvidenceID>, limit: Int) async -> [Evidence] {
        let open = pool.filter { item in
            !known.contains(item.id) && (episode == nil || item.episodeID == episode)
                && (range.map { range in item.range.map { range.contains($0.start) } ?? false } ?? true)
        }
        guard !open.isEmpty, limit > 0 else { return [] }
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !terms.isEmpty {
            let ranked = PassageRanker().rank(open, for: terms, limit: limit, embeddingLimit: Self.embeddingLimit)
            // Innerhalb eines Kapitels hilft auch eine Auswahl ohne Treffer.
            if !ranked.isEmpty || range == nil { return ranked }
        }
        // Ohne Suchbegriff oder ohne Treffer im Kapitel: über die Zeit verteilt.
        let ordered = open.sorted { ($0.range?.start ?? .zero) < ($1.range?.start ?? .zero) }
        guard ordered.count > limit else { return ordered }
        let step = Double(ordered.count) / Double(limit)
        return (0..<limit).map { ordered[Int(Double($0) * step)] }
    }

    func facts(of episode: EpisodeID) async -> [ChatLookupFact] {
        guard let stored = try? await store.facts(forEpisode: episode), !stored.isEmpty,
              let evidence = try? await store.evidence(forEpisode: episode) else { return [] }
        let byID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return stored.compactMap(\.cleaned)
            .sorted { $0.range.start < $1.range.start }
            .compactMap { fact in byID[fact.evidenceID].map { ChatLookupFact(statement: fact.statement, evidence: $0) } }
    }

    func mentions(of episode: EpisodeID) async -> [ChatLookupMention] {
        await mentionsOf(episode)
    }

    func chapters(of episode: EpisodeID) async -> [ChatLookupChapter] {
        if let known = chapterCache.withLock({ $0[episode] }) { return known }
        let found = await chaptersOf(episode)
        chapterCache.withLock { $0[episode] = found }
        return found
    }
}

// MARK: - Frage mit Werkzeugen

extension AppModel {

    /// Das Buch für eine Frage: Kennungen, Nummern und Grenzen der Werkzeuge
    /// im Bereich dieser Frage. Ohne Belege gibt es nichts nachzuschlagen.
    func makeChatLookup(scope: ChatScope, pool: [Evidence], number: Int) -> ChatLookupLedger? {
        guard !pool.isEmpty else { return nil }
        var single: EpisodeID?
        if case .episode(let id) = scope { single = id }
        let ids = Set(pool.map(\.episodeID))
        var titles: [EpisodeID: String] = [:]
        let podcasts = Dictionary(sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for episode in episodes.values.joined() where ids.contains(episode.id) {
            let podcast = podcasts[episode.sourceID] ?? ""
            titles[episode.id] = podcast.isEmpty ? episode.title : "\(episode.title) (\(podcast))"
        }
        // Was ab hier gelöscht wird, liefern die Werkzeuge nicht mehr.
        let ticket = removalCount
        var source: any ChatLookupSource = LibraryLookupSource(
            pool: pool, titles: titles, store: store,
            removed: { [weak self] ids, podcasts in
                await self?.lookupRemoved(ids, podcasts: podcasts, since: ticket) ?? ids
            },
            mentionsOf: { [weak self] id in await self?.lookupMentions(id) ?? [] },
            chaptersOf: { [weak self] id in await self?.lookupChapters(id) ?? [] })
        #if DEBUG
        if ChatLookupFixture.isRequested { source = ChatLookupFixture.Slowed(base: source) }
        #endif
        return ChatLookupLedger(
            source: source, single: single, counter: ChatLookupTools.tokenCounter,
            observer: { kind, sequence in
                Task { @MainActor in ChatLookupStatus.shared.report(kind, sequence: sequence, question: number) }
            })
    }

    /// Was gerade nachgeschlagen wird, für die Karte der offenen Frage.
    var chatLookupKind: ChatLookupKind? { ChatLookupStatus.shared.kind }

    /// Stellt die Frage dem Modell, das nachschlagen darf.
    ///
    /// Die Kennungen der Folgen für die Werkzeuge stehen vorn im Kontext und
    /// kommen zum Platz des Überblicks dazu, statt ihn zu kürzen; der Plan
    /// hat sie mit dem Platz für die Werkzeuge schon freigehalten. Ohne Buch
    /// ist es die Antwort wie bisher.
    func answerWithLookup(
        question: String, candidates: [Evidence], libraryContext: String,
        device: ContextBudget, budget: ContextBudget, lookup: ChatLookupLedger?,
        status: ModelStatus, number: Int
    ) async throws -> ComposedAnswer {
        // Nur die Frage, die noch gilt, zeigt, was nachgeschlagen wird. Eine
        // abgebrochene, die spät hier ankommt, nähme sonst der neuen die Zeile.
        if number == questionTicket { ChatLookupStatus.shared.begin(question: number) }
        defer { ChatLookupStatus.shared.end(question: number) }
        let directory = await lookup?.directory(for: candidates) ?? ""
        let extra = directory.isEmpty ? 0 : directory.count + 1
        let context = directory.isEmpty ? libraryContext : directory + "\n" + libraryContext
        var deviceBudget = device
        deviceBudget.libraryContextLimit += extra
        var answerBudget = budget
        answerBudget.libraryContextLimit += extra
        var cloudBudget = ContextBudget.privateCloudCompute
        cloudBudget.libraryContextLimit += extra
        #if DEBUG
        if ChatLookupFixture.isRequested, let lookup {
            return try await ChatLookupFixture.answer(question: question, candidates: candidates,
                                                      budget: deviceBudget, lookup: lookup)
        }
        #endif
        let extractor = KnowledgeExtractor(configuration: ExtractorConfiguration(
            candidateBuilder: CandidateListBuilder(
                excerptLimit: answerBudget.excerptLimit, maximumCandidates: answerBudget.maximumCandidates),
            // Ohne diese Angabe rechnete der Extraktor auf dem Gerät mit dem
            // festen Budget aus dem Paket und kürzte den Kontext unter das,
            // was hier für das Gerät bestimmt wurde.
            onDeviceBudget: deviceBudget,
            privateCloudBudget: cloudBudget))
        return try await extractor.answer(
            question: question, from: candidates,
            libraryContext: String(context.prefix(answerBudget.libraryContextLimit)),
            availability: status, lookup: lookup,
            onPartial: { [weak self] text in await self?.showPartialAnswer(text, number: number) })
    }

    // MARK: Gelöschtes, Nennungen und Kapitel für die Werkzeuge

    /// Die Folgen unter `ids`, die seit `ticket` gelöscht oder deren Podcast
    /// seitdem abbestellt wurde, wie bei `citesRemovedContent`.
    func lookupRemoved(_ ids: Set<EpisodeID>, podcasts: [EpisodeID: SourceID],
                       since ticket: Int) -> Set<EpisodeID> {
        guard removalCount > ticket else { return [] }
        return ids.filter { id in
            if wasRemoved(id, since: ticket) { return true }
            guard let podcast = podcasts[id], !podcast.rawValue.isEmpty else { return false }
            return (removedSourceTickets[podcast] ?? 0) > ticket
        }
    }

    /// Die Nennungen einer Folge, jede mit der Stelle, an der sie zuerst fällt.
    func lookupMentions(_ id: EpisodeID) async -> [ChatLookupMention] {
        guard let episode = (try? await store.episodes(ids: [id]))?.first else { return [] }
        let found = await mentions(for: episode).mentions.sorted { $0.kind < $1.kind }
        guard !found.isEmpty else { return [] }
        let passages = ((try? await store.evidence(forEpisode: id)) ?? []).filter(\.isPlayable)
            .sorted { ($0.range?.start ?? .zero) < ($1.range?.start ?? .zero) }
        return found.map { mention in
            let passage = mention.firstTime.flatMap { time in
                passages.first { $0.range?.contains(time) ?? false }
                    ?? passages.last { ($0.range?.start ?? .zero) <= time }
            }
            return ChatLookupMention(kind: mention.kind.rawValue, title: mention.title,
                                     evidence: passage, inShownotes: mention.inShownotes)
        }
    }

    /// Die Kapitel einer Folge mit Grenzen und, falls schon formuliert, dem
    /// Satz, worum es geht. Ohne Kapitel im Feed die Abschnitte des Codes.
    func lookupChapters(_ id: EpisodeID) async -> [ChatLookupChapter] {
        guard let episode = (try? await store.episodes(ids: [id]))?.first else { return [] }
        let evidence = (try? await store.evidence(forEpisode: id)) ?? []
        let sections = await Self.chapterSections(
            chapters: feedChapters(for: episode), duration: episode.declaredDuration, evidence: evidence)
        let summaries = await storedChapterSummaries(for: episode, sections: sections, evidence: evidence)
        return sections.map { section in
            ChatLookupChapter(title: section.title, range: section.range, summary: summaries[section.id]?.text)
        }
    }
}
