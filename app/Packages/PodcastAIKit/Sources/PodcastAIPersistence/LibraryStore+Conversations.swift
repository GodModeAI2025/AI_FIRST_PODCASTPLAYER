//
//  LibraryStore+Conversations.swift
//  PodcastAIPersistence
//
//  Unterhaltungen im Chat lesen, sichern, löschen und nach dem Löschen
//  einer Folge kürzen. Die Regeln selbst stehen in `ChatConversation`
//  (PodcastAIKnowledge); hier geht es nur um die Zeilen.
//
//  CloudKit kennt keine eindeutigen Schlüssel. Kommt dieselbe Unterhaltung
//  doppelt an, gilt beim Lesen die Zeile mit dem jüngsten Stand, und das
//  nächste Speichern lässt nur eine Zeile übrig. Das allgemeine Bereinigen
//  in `removeDuplicates()` braucht es dafür nicht.
//

#if canImport(SwiftData)
import Foundation
import SwiftData
import PodcastAICore
import PodcastAIKnowledge

extension LibraryStore {

    /// Sichert eine Unterhaltung, auch eine ohne Frage. Liegt sie doppelt
    /// vor, bleibt danach eine Zeile.
    public func save(conversation: ChatConversation) throws {
        let payload = try conversation.encoded()
        let rows = try conversationRows(id: conversation.id)
        let row: StoredChatConversation
        if let existing = rows.first {
            row = existing
        } else {
            row = StoredChatConversation(
                identifier: conversation.id.uuidString, scopeKey: conversation.key.rawValue, title: "",
                createdAt: conversation.createdAt, updatedAt: conversation.updatedAt, turnCount: 0,
                formatVersion: ChatConversation.formatVersion, payload: Data())
            modelContext.insert(row)
        }
        for extra in rows.dropFirst() { modelContext.delete(extra) }
        write(conversation, payload: payload, into: row)
        try modelContext.save()
    }

    /// Eine Unterhaltung nach Kennung. Bei doppelten Zeilen die jüngste, die sich lesen lässt.
    public func conversation(id: UUID) throws -> ChatConversation? {
        for row in try conversationRows(id: id) {
            if let conversation = try? ChatConversation.decoded(from: row.payload) { return conversation }
        }
        return nil
    }

    /// Die zuletzt geänderte Unterhaltung eines Bereichs, auch eine ohne
    /// Frage: Wer „Neue Unterhaltung“ gewählt hat, beginnt nach einem
    /// Neustart nicht wieder in der alten.
    public func latestConversation(for key: ChatConversationKey) throws -> ChatConversation? {
        let raw = key.rawValue
        let descriptor = FetchDescriptor<StoredChatConversation>(
            predicate: #Predicate { $0.scopeKey == raw },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        for row in try modelContext.fetch(descriptor) {
            if let conversation = try? ChatConversation.decoded(from: row.payload) { return conversation }
        }
        return nil
    }

    /// Die Unterhaltungen eines Bereichs mit mindestens einer Frage, die
    /// zuletzt geänderte zuerst, je Unterhaltung eine Zeile.
    public func conversationSummaries(for key: ChatConversationKey) throws -> [ChatConversationSummary] {
        let raw = key.rawValue
        var descriptor = FetchDescriptor<StoredChatConversation>(
            predicate: #Predicate { $0.scopeKey == raw && $0.turnCount > 0 },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.propertiesToFetch = [\.identifier, \.title, \.createdAt, \.updatedAt, \.turnCount]
        var seen: Set<String> = []
        return try modelContext.fetch(descriptor).compactMap { row in
            guard seen.insert(row.identifier).inserted, let id = UUID(uuidString: row.identifier) else { return nil }
            return ChatConversationSummary(
                id: id, key: key, title: row.title, createdAt: row.createdAt,
                updatedAt: row.updatedAt, turnCount: row.turnCount)
        }
    }

    /// Löscht eine Unterhaltung mit allen ihren Zeilen.
    public func removeConversation(id: UUID) throws {
        for row in try conversationRows(id: id) { modelContext.delete(row) }
        try modelContext.save()
    }

    /// Löscht alle Unterhaltungen eines Bereichs, etwa die einer Folge.
    public func removeConversations(for key: ChatConversationKey) throws {
        let raw = key.rawValue
        let rows = try modelContext.fetch(FetchDescriptor<StoredChatConversation>(
            predicate: #Predicate { $0.scopeKey == raw }))
        guard !rows.isEmpty else { return }
        for row in rows { modelContext.delete(row) }
        try modelContext.save()
    }

    /// Löscht die Unterhaltungen eines Bereichs, die keine Frage haben,
    /// außer `id`. Von „Neue Unterhaltung“ bleibt so höchstens eine leere.
    public func removeEmptyConversations(for key: ChatConversationKey, keeping id: UUID) throws {
        let raw = key.rawValue
        let keep = id.uuidString
        let rows = try modelContext.fetch(FetchDescriptor<StoredChatConversation>(
            predicate: #Predicate { $0.scopeKey == raw && $0.turnCount == 0 && $0.identifier != keep }))
        guard !rows.isEmpty else { return }
        for row in rows { modelContext.delete(row) }
        try modelContext.save()
    }

    /// Kürzt alle gespeicherten Unterhaltungen nach dem Löschen von Folgen
    /// oder Belegen (Regel 5), nach denselben Regeln wie die geladenen,
    /// siehe ``ChatConversation/pruning(removedEpisodes:removedEvidence:at:)``.
    /// Gibt zurück, wie viele Zeilen sich geändert haben oder weg sind.
    @discardableResult
    public func pruneConversations(
        removedEpisodes: Set<EpisodeID>, removedEvidence: Set<EvidenceID> = [], at date: Date = Date()
    ) throws -> Int {
        guard !removedEpisodes.isEmpty || !removedEvidence.isEmpty else { return 0 }
        // Die Unterhaltung einer gelöschten Folge geht, ohne ihr JSON zu lesen.
        let removedKeys = Set(removedEpisodes.map { ChatConversationKey.episode($0).rawValue })
        var touched = 0
        for row in try modelContext.fetch(FetchDescriptor<StoredChatConversation>()) {
            if removedKeys.contains(row.scopeKey) {
                modelContext.delete(row)
                touched += 1
                continue
            }
            guard let conversation = try? ChatConversation.decoded(from: row.payload) else { continue }
            switch conversation.pruning(removedEpisodes: removedEpisodes, removedEvidence: removedEvidence, at: date) {
            case .unchanged:
                continue
            case .removed:
                modelContext.delete(row)
            case .changed(let pruned):
                write(pruned, payload: try pruned.encoded(), into: row)
            }
            touched += 1
        }
        if touched > 0 { try modelContext.save() }
        return touched
    }

    // MARK: - Zeilen

    /// Alle Zeilen einer Unterhaltung, die jüngste zuerst.
    private func conversationRows(id: UUID) throws -> [StoredChatConversation] {
        let key = id.uuidString
        return try modelContext.fetch(FetchDescriptor<StoredChatConversation>(
            predicate: #Predicate { $0.identifier == key },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
    }

    private func write(_ conversation: ChatConversation, payload: Data, into row: StoredChatConversation) {
        row.scopeKey = conversation.key.rawValue
        row.title = String(conversation.title.prefix(200))
        row.createdAt = conversation.createdAt
        row.updatedAt = conversation.updatedAt
        row.turnCount = conversation.turns.count
        row.formatVersion = ChatConversation.formatVersion
        row.payload = payload
    }
}
#endif
