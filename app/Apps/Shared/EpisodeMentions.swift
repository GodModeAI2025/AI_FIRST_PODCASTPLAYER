//
//  EpisodeMentions.swift
//  PodcastAI
//
//  „Erwähnt“: welche Links, Termine, Adressen, Telefonnummern,
//  E-Mail-Adressen, Personen, Organisationen und Orte eine Folge nennt.
//
//  Die Nennungen entstehen auf Abruf aus Transkript und Shownotes, ohne
//  Sprachmodell (``MentionExtractor``). Die Datenbank bleibt, wie sie ist:
//  Das Ergebnis liegt je Folge im Speicher und als Datei unter Application
//  Support, mit einem Schlüssel aus Folge, Transkript, Fassung und
//  Shownotes. Ändert sich eines davon, wird neu erkannt. „Folge löschen“
//  nimmt die Datei mit, „Audio entfernen“ lässt sie stehen.
//
//  Fragen nach Nennungen („Welche Links werden genannt?“) beantwortet der
//  Chat hier, aus den Nennungen, auch ohne Apple Intelligence.
//

import Foundation
import Synchronization
import PodcastAIKit

/// Die Nennungen einer Folge und ob das Transkript schon mitgezählt hat.
struct EpisodeMentions: Codable, Sendable, Equatable {
    let key: String
    let mentions: [Mention]
    let hasTranscript: Bool
}

// MARK: - Zwischenspeicher

enum MentionCache {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("PodcastAI/Mentions", isDirectory: true)
    }

    static func file(for id: EpisodeID) -> URL {
        directory.appendingPathComponent("\(id.rawValue).json")
    }

    /// Was die Nennungen bestimmt. Ändert sich das Transkript, die Fassung,
    /// die Shownotes oder eine Regel, passt der gespeicherte Stand nicht mehr.
    static func key(for episode: Episode, transcript: Transcript?) -> String {
        var parts = ["v\(MentionExtractor.version)", episode.id.rawValue]
        if let transcript {
            parts += [transcript.id.rawValue, "r\(transcript.revision.value)", "\(transcript.segments.count)",
                      "\(transcript.segments.last?.range.end.milliseconds ?? 0)"]
        } else {
            parts.append("ohne-transkript")
        }
        parts.append(StableDigest.hex(of: episode.shownotesHTML ?? episode.summary ?? ""))
        parts.append("\(Int(episode.publishedAt?.timeIntervalSince1970 ?? 0))")
        return parts.joined(separator: "|")
    }

    private struct State {
        var memory: [EpisodeID: EpisodeMentions] = [:]
        var removals = 0
        var removed: [EpisodeID: Int] = [:]
    }

    private static let state = Mutex(State())

    /// Höchstens so viele Folgen im Speicher. Der Rest liegt als Datei.
    private static let memoryLimit = 200

    /// Der Stand der Löschungen, gezogen vor dem Erkennen. Geschrieben wird
    /// nur, wenn die Folge seitdem nicht gelöscht wurde.
    static var ticket: Int { state.withLock { $0.removals } }

    static func cached(_ id: EpisodeID, key: String) -> EpisodeMentions? {
        state.withLock { $0.memory[id] }.flatMap { $0.key == key ? $0 : nil }
    }

    /// Aus der Datei, außerhalb des Hauptthreads.
    static func load(_ id: EpisodeID, key: String) async -> EpisodeMentions? {
        let stored = await Task.detached(priority: .userInitiated) { () -> EpisodeMentions? in
            guard let data = try? Data(contentsOf: file(for: id)) else { return nil }
            return try? JSONDecoder().decode(EpisodeMentions.self, from: data)
        }.value
        guard let stored, stored.key == key else { return nil }
        remember(stored, for: id)
        return stored
    }

    static func save(_ value: EpisodeMentions, for id: EpisodeID, ticket: Int) async {
        let removed = state.withLock { state in
            if let at = state.removed[id], at > ticket { return true }
            return false
        }
        guard !removed else { return }
        remember(value, for: id)
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            // Prüfen und Schreiben unter derselben Sperre wie das Löschen,
            // sonst legte ein später Lauf die Datei einer gelöschten Folge neu an.
            state.withLock { state in
                if let at = state.removed[id], at > ticket { return }
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: file(for: id), options: .atomic)
            }
        }.value
    }

    private static func remember(_ value: EpisodeMentions, for id: EpisodeID) {
        state.withLock { state in
            if state.memory.count >= memoryLimit, state.memory[id] == nil {
                state.memory.removeAll(keepingCapacity: true)
            }
            state.memory[id] = value
        }
    }

    /// Entfernt, was zu diesen Folgen erkannt wurde, im Speicher und als Datei.
    static func remove(episodes: [EpisodeID]) {
        guard !episodes.isEmpty else { return }
        state.withLock { state in
            state.removals += 1
            for id in episodes {
                state.removed[id] = state.removals
                state.memory[id] = nil
                try? FileManager.default.removeItem(at: file(for: id))
            }
        }
    }
}

// MARK: - Nennungen einer Folge

extension AppModel {

    /// Die Nennungen einer Folge: aus dem Speicher, aus der Datei oder neu erkannt.
    func mentions(for episode: Episode) async -> EpisodeMentions {
        let transcript = await transcript(for: episode)
        let key = MentionCache.key(for: episode, transcript: transcript)
        if let cached = MentionCache.cached(episode.id, key: key) { return cached }
        if let stored = await MentionCache.load(episode.id, key: key) { return stored }
        let ticket = MentionCache.ticket
        let source = sources.first { $0.id == episode.sourceID }
        let input = MentionExtractor.Input(
            shownotes: episode.shownotesHTML ?? episode.summary,
            segments: transcript?.segments ?? [],
            languageCode: transcript?.locale ?? source?.language,
            publishedAt: episode.publishedAt,
            ownHosts: [source?.feedURL, source?.websiteURL].compactMap { $0?.host() })
        let found = await Task.detached(priority: .userInitiated) {
            MentionExtractor().mentions(in: input)
        }.value
        let result = EpisodeMentions(key: key, mentions: found,
                                     hasTranscript: !(transcript?.segments.isEmpty ?? true))
        await MentionCache.save(result, for: episode.id, ticket: ticket)
        return result
    }

    /// Kurzer Block für das Sprachmodell zu einer Folge.
    func mentionContext(for episode: Episode) async -> String? {
        MentionSummary.modelContext(await mentions(for: episode).mentions, limit: 500)
    }

    /// Nennungen der neuesten Folgen im Bereich, für das Sprachmodell.
    /// Nur Folgen mit Transkript und nur wenige, der Platz ist knapp.
    func libraryMentionContext(filter: LibraryFilter) async -> String? {
        let now = Date()
        let recent = ((try? await store.episodes(ids: Array(analyzedEpisodes))) ?? [])
            .filter { filter.admits(sourceID: $0.sourceID, publishedAt: $0.publishedAt, now: now) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            .prefix(5)
        var lines: [String] = []
        for episode in recent {
            guard let block = MentionSummary.modelContext(await mentions(for: episode).mentions, limit: 260)
            else { continue }
            lines.append("„\(episode.title)“ " + block)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Antwort im Chat

    /// Höchstens so viele Folgen durchsucht eine Frage an die Mediathek:
    /// mit Transkript und, nur mit Shownotes, ohne.
    static let mentionScanLimit = (withTranscript: 40, shownotesOnly: 60)

    /// Beantwortet eine Frage nach Nennungen aus den erkannten Werten. Jeder
    /// Eintrag nennt, wo er vorkommt: Zeitmarke und Beleg aus dem Transkript
    /// oder die Shownotes, bei mehreren Folgen dazu Folge und Podcast.
    func mentionAnswer(_ question: String, kinds: [Mention.Kind], scope: ChatScope) async -> ChatAnswer {
        let (scanned, capped) = await mentionEpisodes(for: scope)
        var found: [(episode: Episode, mentions: EpisodeMentions)] = []
        for episode in scanned {
            found.append((episode, await mentions(for: episode)))
        }
        // Eine einzelne Folge: dann ohne Folge und Podcast in jeder Zeile.
        let single: Bool = switch scope {
        case .episode: true
        case .episodes(let ids): ids.count == 1
        default: false
        }

        var composer = MentionAnswerComposer(single: single, sources: sources)
        for kind in kinds {
            var groups: [String: [(episode: Episode, mention: Mention)]] = [:]
            var order: [String] = []
            for (episode, result) in found {
                for mention in result.mentions where mention.kind == kind {
                    if groups[mention.id] == nil { order.append(mention.id) }
                    groups[mention.id, default: []].append((episode, mention))
                }
            }
            var entries = order.compactMap { groups[$0] }
            if kind == .date {
                entries.sort { ($0.first?.mention.date ?? .distantFuture) < ($1.first?.mention.date ?? .distantFuture) }
            } else if kind.isName {
                entries.sort { $0.reduce(0) { $0 + $1.mention.occurrences.count }
                    > $1.reduce(0) { $0 + $1.mention.occurrences.count } }
            }
            await composer.add(kind: kind, entries: entries) { episode in
                (try? await self.store.evidence(forEpisode: episode.id)) ?? []
            }
        }

        var caveats: [String] = []
        if single, let only = found.first, !only.mentions.hasTranscript {
            caveats.append(String(localized: """
                Die Folge hat noch kein Transkript. Bisher zählen nur die Shownotes, mit dem Transkript kommt mehr dazu.
                """))
        } else if !single {
            let without = found.count { !$0.mentions.hasTranscript }
            if capped {
                caveats.append(String(localized: "Durchsucht wurden die neuesten Folgen im gewählten Bereich."))
            }
            if without > 0 {
                caveats.append(String(localized: """
                    Bei \(without) Folgen fehlt noch das Transkript, dort zählen nur die Shownotes.
                    """))
            }
        }
        if found.isEmpty {
            caveats = [String(localized: "Im gewählten Bereich gibt es keine Folge.")]
        }
        return ChatAnswer(
            question: question, scope: scope, text: composer.text,
            citations: composer.citations, coverageCaveat: caveats.isEmpty ? nil : caveats.joined(separator: " "),
            modelLabel: nil, citationNumbers: composer.numbers,
            referencedEpisodeIDs: composer.referenced)
    }

    /// Die Folgen, die eine Frage nach Nennungen durchsucht, und ob die
    /// Grenze gegriffen hat. Podcast und Zeitraum grenzt der Code vorher ein.
    private func mentionEpisodes(for scope: ChatScope) async -> (episodes: [Episode], capped: Bool) {
        switch scope {
        case .episode(let id):
            if let episode = loadedEpisode(id) { return ([episode], false) }
            return (((try? await store.episodes(ids: [id])) ?? []), false)
        case .episodes(let ids):
            return (((try? await store.episodes(ids: ids)) ?? []), false)
        case .smartFeed, .allAnalyzed:
            return await mentionEpisodes(filter: LibraryFilter())
        case .library(let filter):
            return await mentionEpisodes(filter: filter)
        }
    }

    private func mentionEpisodes(filter: LibraryFilter) async -> (episodes: [Episode], capped: Bool) {
        let now = Date()
        var pool: [EpisodeID: Episode] = [:]
        for episode in (try? await store.episodes(ids: Array(analyzedEpisodes))) ?? [] { pool[episode.id] = episode }
        for episode in episodes.values.joined() where pool[episode.id] == nil { pool[episode.id] = episode }
        let admitted = pool.values
            .filter { filter.admits(sourceID: $0.sourceID, publishedAt: $0.publishedAt, now: now) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        let analyzed = admitted.filter { analyzedEpisodes.contains($0.id) }
        let others = admitted.filter { !analyzedEpisodes.contains($0.id) }
        let limit = Self.mentionScanLimit
        let chosen = Array(analyzed.prefix(limit.withTranscript)) + Array(others.prefix(limit.shownotesOnly))
        return (chosen, analyzed.count > limit.withTranscript || others.count > limit.shownotesOnly)
    }
}

/// Setzt die Antwort zusammen: je Art eine Überschrift und die Einträge,
/// jeder mit seiner Stelle. Belege sind echte gespeicherte Stellen aus dem
/// Transkript, damit Abspielen, Sichern und Löschen wie bei jeder Antwort
/// funktionieren.
@MainActor
private struct MentionAnswerComposer {
    let single: Bool
    let sources: [Source]
    private(set) var citations: [Evidence] = []
    private(set) var numbers: [Int: EvidenceID] = [:]
    private(set) var referenced: [EpisodeID] = []
    private var blocks: [String] = []
    private var evidence: [EpisodeID: [Evidence]] = [:]

    /// Einträge je Art, mehr stehen unter „Erwähnt“ in der Folge.
    static let entryLimit = 15
    /// Folgen je Eintrag, bei Fragen an die Mediathek.
    static let placeLimit = 3

    init(single: Bool, sources: [Source]) {
        self.single = single
        self.sources = sources
    }

    var text: String { blocks.joined(separator: "\n\n") }

    mutating func add(kind: Mention.Kind, entries: [[(episode: Episode, mention: Mention)]],
                      loadEvidence: (Episode) async -> [Evidence]) async {
        guard !entries.isEmpty else {
            blocks.append(single
                ? String(localized: "\(kind.label): keine in dieser Folge.")
                : String(localized: "\(kind.label): keine in deinen Podcasts."))
            return
        }
        var lines = [single
            ? String(localized: "\(kind.label) in dieser Folge:")
            : String(localized: "\(kind.label) in deinen Podcasts:")]
        for entry in entries.prefix(Self.entryLimit) {
            guard let first = entry.first else { continue }
            var places: [String] = []
            for (episode, mention) in entry.prefix(single ? 1 : Self.placeLimit) {
                places.append(await place(of: mention, in: episode, loadEvidence: loadEvidence))
            }
            if entry.count > Self.placeLimit, !single {
                places.append(String(localized: "in \(entry.count - Self.placeLimit) weiteren Folgen"))
            }
            lines.append("• " + Self.title(first.mention) + (places.isEmpty ? "" : ", " + places.joined(separator: "; ")))
        }
        if entries.count > Self.entryLimit {
            lines.append(String(localized: "Dazu \(entries.count - Self.entryLimit) weitere."))
        }
        blocks.append(lines.joined(separator: "\n"))
    }

    /// Wo ein Wert vorkommt: „bei 9:20 [1]“, „in den Shownotes“, bei der
    /// Mediathek mit Folge und Podcast davor.
    private mutating func place(of mention: Mention, in episode: Episode,
                                loadEvidence: (Episode) async -> [Evidence]) async -> String {
        if !referenced.contains(episode.id) { referenced.append(episode.id) }
        var parts: [String] = []
        if let time = mention.firstTime {
            var spot = String(localized: "bei \(time.timecode)")
            if let number = await cite(time, in: episode, loadEvidence: loadEvidence) { spot += " [\(number)]" }
            parts.append(spot)
            let more = mention.occurrences.count { $0.time != nil } - 1
            if more > 0 {
                parts.append(String(localized: "noch \(more)-mal"))
            }
        }
        if mention.inShownotes { parts.append(String(localized: "in den Shownotes")) }
        let spots = parts.joined(separator: ", ")
        guard !single else { return spots }
        let podcast = sources.first { $0.id == episode.sourceID }?.title ?? String(localized: "Unbekannter Podcast")
        return "„\(episode.title)“ (\(podcast))" + (spots.isEmpty ? "" : " " + spots)
    }

    /// Die gespeicherte Stelle des Transkripts, in der die Zeit liegt, mit
    /// ihrer Verweisnummer. Dieselbe Stelle bekommt dieselbe Nummer.
    private mutating func cite(_ time: MediaTime, in episode: Episode,
                               loadEvidence: (Episode) async -> [Evidence]) async -> Int? {
        if evidence[episode.id] == nil { evidence[episode.id] = await loadEvidence(episode) }
        let passages = (evidence[episode.id] ?? []).filter(\.isPlayable)
            .sorted { ($0.range?.start ?? .zero) < ($1.range?.start ?? .zero) }
        let containing = passages.first { passage in
            guard let range = passage.range else { return false }
            return range.start <= time && time < range.end
        } ?? passages.last { ($0.range?.start ?? .zero) <= time }
        guard let passage = containing else { return nil }
        if let known = numbers.first(where: { $0.value == passage.id })?.key { return known }
        let number = numbers.count + 1
        numbers[number] = passage.id
        citations.append(passage)
        return number
    }

    private static func title(_ mention: Mention) -> String {
        guard mention.kind == .date, mention.isVague else { return mention.title }
        return String(localized: "\(mention.title) (ungefähr, gesagt: „\(mention.display)“)")
    }
}
