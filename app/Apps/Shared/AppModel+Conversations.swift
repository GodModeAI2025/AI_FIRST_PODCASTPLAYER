//
//  AppModel+Conversations.swift
//  PodcastAI
//
//  Unterhaltungen im Chat. Jede Frage gehört zu einer Unterhaltung: die
//  über die Mediathek in „Frag deine Podcasts“ oder die einer Folge. Eine
//  Folgefrage bekommt die letzten Runden als Daten mit und sucht auch dort,
//  wo die Antwort davor stand (`ChatConversation`, `ChatFollowUp`,
//  `ConversationHistory` im Paket).
//
//  Unterhaltungen liegen in der Datenbank und gleichen sich über iCloud ab
//  (`StoredChatConversation`). Hier steht, was die App dazu beiträgt:
//
//    - Laden: die letzte Unterhaltung eines Bereichs, sobald sein Chat
//      aufgeht, und nach jedem Abgleich der neueste Stand der geladenen.
//      Ändern zwei Geräte dieselbe Unterhaltung, gilt der jüngere Stand ganz.
//    - Sichern: jede Änderung sofort, in einer festen Reihe. Das Kürzen nach
//      einer Löschung läuft in derselben Reihe, sonst könnte ein spätes
//      Sichern Gekürztes zurückbringen.
//    - Regel 5: Nach „Folge löschen“ und „Quelle abbestellen“ kürzt dieselbe
//      Regel die geladenen und alle gespeicherten Unterhaltungen. Beim Laden
//      prüft die App eine Unterhaltung zusätzlich gegen die Merkzeichen
//      gelöschter Folgen, falls eine Löschung sie auf einem anderen Gerät
//      noch nicht erreicht hat. „Audio entfernen“ lässt alles stehen.
//
//  Alle Anfragen an ein Modell laufen wie bisher über den Weg der Antwort
//  und `AIScheduler`. Ton entsteht hier nirgends.
//

import Foundation
import PodcastAIKit

extension AppModel {

    // MARK: - Lesen

    /// Alle Antworten der geladenen Unterhaltungen. Das Aufräumen nach einer
    /// Löschung auf einem anderen Gerät fragt damit, ob dieses Gerät noch
    /// etwas aus einer Folge zeigt.
    var chatAnswers: [ChatAnswer] { conversations.values.flatMap(\.answers) }

    /// Holt die zuletzt geänderte Unterhaltung eines Bereichs aus der
    /// Datenbank, einmal. Danach gilt die im Speicher, bis ein Abgleich
    /// einen neueren Stand bringt. Gibt es keine, beginnt eine leere, die
    /// erst mit der ersten Frage gesichert wird.
    public func restoreConversation(for key: ChatConversationKey) async {
        guard conversations[key] == nil else { return }
        await Self.conversationWrites?.value
        let stored = try? await store.latestConversation(for: key)
        let removed = stored == nil ? [] : await removedEpisodeIDs()
        // Inzwischen gefragt: Die Frage hat ihre Unterhaltung schon.
        guard conversations[key] == nil else { return }
        if let stored { Self.persistedConversations.insert(stored.id) }
        conversations[key] = stored.map { checked($0, against: removed) } ?? ChatConversation(key: key)
    }

    /// Nach dem Laden und nach jedem Abgleich (`load()`): jede geladene
    /// Unterhaltung mit ihrer Fassung in der Datenbank abgleichen.
    ///
    /// Es gilt der jüngere Stand (`ChatConversation.resolved`). Fehlt eine
    /// schon gesicherte Unterhaltung in der Datenbank, wurde sie auf einem
    /// anderen Gerät gelöscht; dann gilt die nächstjüngere ihres Bereichs.
    func reloadConversations() async {
        guard !conversations.isEmpty else { return }
        await Self.conversationWrites?.value
        let removed = await removedEpisodeIDs()
        for key in Array(conversations.keys) {
            guard let loaded = conversations[key] else { continue }
            let stored = try? await store.conversation(id: loaded.id)
            var replacement: ChatConversation?
            if stored == nil {
                guard Self.persistedConversations.contains(loaded.id) else { continue }
                replacement = (try? await store.latestConversation(for: key)) ?? ChatConversation(key: key)
            }
            // Während der Abfragen kann eine Frage dazugekommen sein.
            guard let current = conversations[key], current.id == loaded.id else { continue }
            var next: ChatConversation
            if let stored {
                next = ChatConversation.resolved(local: current, remote: stored)
            } else if let replacement {
                Self.persistedConversations.remove(loaded.id)
                if !replacement.isEmpty { Self.persistedConversations.insert(replacement.id) }
                next = replacement
            } else {
                continue
            }
            next = checked(next, against: removed)
            if !Self.sameState(next, current) { conversations[key] = next }
        }
    }

    /// Die Unterhaltungen der Mediathek mit mindestens einer Frage, für
    /// „Frühere Unterhaltungen“.
    public func conversationSummaries(for key: ChatConversationKey) async -> [ChatConversationSummary] {
        await Self.conversationWrites?.value
        return (try? await store.conversationSummaries(for: key)) ?? []
    }

    // MARK: - Ändern

    /// Hängt eine Antwort an die Unterhaltung ihres Bereichs und sichert sie.
    /// Stammt die Unterhaltung aus einer neueren App, beginnt eine neue,
    /// denn beim Sichern gingen Felder verloren, die nur jene kennt.
    func appendToConversation(_ answer: ChatAnswer) {
        let key = ChatConversationKey(scope: answer.scope)
        var conversation = conversations[key] ?? ChatConversation(key: key)
        if conversation.isFromNewerVersion { conversation = ChatConversation(key: key) }
        conversation.append(answer)
        conversations[key] = conversation
        persist(conversation)
    }

    /// Nimmt eine Runde aus ihrer Unterhaltung. Gesicherte Antworten bleiben.
    func removeTurn(_ id: UUID) {
        for (key, var conversation) in conversations
        where !conversation.isFromNewerVersion && conversation.turns.contains(where: { $0.id == id }) {
            conversation.removeTurn(id)
            conversations[key] = conversation
            persist(conversation)
        }
    }

    /// „Neue Unterhaltung“: Die bisherige bleibt unter „Frühere
    /// Unterhaltungen“. Die neue wird gleich gesichert, damit nach einem
    /// Neustart nicht wieder die alte erscheint. Mehr als eine leere
    /// Unterhaltung je Bereich gibt es nicht.
    public func startNewConversation(for key: ChatConversationKey) {
        guard let current = conversations[key], !current.isEmpty else { return }
        replaceWithEmptyConversation(for: key)
    }

    /// Öffnet eine frühere Unterhaltung wieder. Sie gilt danach als zuletzt
    /// benutzt und kommt nach einem Neustart zurück.
    @discardableResult
    public func reopenConversation(_ id: UUID) async -> ChatConversation? {
        await Self.conversationWrites?.value
        guard let stored = try? await store.conversation(id: id) else { return nil }
        let removed = await removedEpisodeIDs()
        var opened = checked(stored, against: removed)
        guard opened.id == stored.id else {
            conversations[stored.key] = opened
            return opened
        }
        Self.persistedConversations.insert(opened.id)
        if !opened.isFromNewerVersion {
            opened.markUsed()
            persist(opened)
        }
        let left = conversations[opened.key]
        conversations[opened.key] = opened
        // Eine leere Unterhaltung, die dafür verlassen wird, braucht niemand.
        if let left, left.isEmpty, left.id != opened.id { forgetConversation(left.id) }
        return opened
    }

    /// Löscht eine Unterhaltung auf allen Geräten. War sie geöffnet, beginnt
    /// eine leere.
    public func deleteConversation(_ id: UUID) {
        forgetConversation(id)
        for (key, conversation) in conversations where conversation.id == id {
            if key == .library {
                replaceWithEmptyConversation(for: key)
            } else {
                conversations[key] = ChatConversation(key: key)
            }
        }
    }

    /// Löscht die Unterhaltung einer Folge, aus ihrem Chat heraus.
    public func deleteEpisodeConversation(_ episodeID: EpisodeID) {
        let key = ChatConversationKey.episode(episodeID)
        if let id = conversations[key]?.id { Self.persistedConversations.remove(id) }
        conversations[key] = ChatConversation(key: key)
        enqueueConversationWrite { store in try await store.removeConversations(for: key) }
    }

    // MARK: - Folgefragen

    /// Was eine Frage von ihrer Unterhaltung weiß: die letzten Runden für den
    /// Prompt und die Belege davor für die Auswahl der Stellen. Leer bei der
    /// ersten Frage und bei einer Unterhaltung aus einer neueren App, denn
    /// dort beginnt die Frage eine neue.
    func followUpContext(for scope: ChatScope) -> (history: [ConversationHistory.Turn], followUp: ChatFollowUp) {
        guard let conversation = conversations[ChatConversationKey(scope: scope)],
              !conversation.isEmpty, !conversation.isFromNewerVersion else { return ([], ChatFollowUp()) }
        return (conversation.historyTurns(), conversation.followUp())
    }

    /// Der Block der früheren Runden, gekürzt auf seinen Platz im Plan und
    /// gezählt mit dem Tokenizer des Geräts. Antwortet er nicht rechtzeitig,
    /// gilt die Schätzung. Ohne frühere Runden `nil`.
    nonisolated static func fittedHistory(_ turns: [ConversationHistory.Turn]) async -> ConversationHistory? {
        guard !turns.isEmpty else { return nil }
        let history = await ChatTrace.interval("Verlauf zählen") {
            await ConversationHistory.trimmed(turns, count: ChatLookupTools.tokenCounter)
        }
        return history.isEmpty ? nil : history
    }

    // MARK: - Regel 5

    /// Kürzt die Unterhaltungen nach dem Löschen von Folgen oder Belegen:
    /// die geladenen sofort, die gespeicherten danach in der Reihe der
    /// Schreibvorgänge. Beide nach derselben Regel und mit demselben Stand,
    /// so ergibt beides dieselbe Fassung.
    func pruneConversations(removedEpisodes: Set<EpisodeID>, removedEvidence: Set<EvidenceID>) {
        guard !removedEpisodes.isEmpty || !removedEvidence.isEmpty else { return }
        let now = Date()
        for (key, conversation) in conversations {
            switch conversation.pruning(removedEpisodes: removedEpisodes, removedEvidence: removedEvidence, at: now) {
            case .unchanged:
                continue
            case .changed(let pruned):
                conversations[key] = pruned
            case .removed:
                Self.persistedConversations.remove(conversation.id)
                conversations[key] = ChatConversation(key: key)
            }
        }
        enqueueConversationWrite { store in
            try await store.pruneConversations(
                removedEpisodes: removedEpisodes, removedEvidence: removedEvidence, at: now)
        }
    }

    /// Die Unterhaltung ohne Runden aus Folgen, die inzwischen gelöscht
    /// sind. Hat sich etwas geändert, wird die gekürzte Fassung gesichert.
    private func checked(_ conversation: ChatConversation, against removed: Set<EpisodeID>) -> ChatConversation {
        guard !removed.isEmpty else { return conversation }
        switch conversation.pruning(removedEpisodes: removed) {
        case .unchanged:
            return conversation
        case .changed(let pruned):
            persist(pruned)
            return pruned
        case .removed:
            forgetConversation(conversation.id)
            return ChatConversation(key: conversation.key)
        }
    }

    /// Folgen, die ein Merkzeichen tragen, also gelöscht sind.
    private func removedEpisodeIDs() async -> Set<EpisodeID> {
        Set(((try? await store.removedEpisodes()) ?? []).map(\.id))
    }

    // MARK: - Sichern

    /// Die Reihe der Schreibvorgänge für Unterhaltungen. Jeder wartet auf
    /// den vorigen, so kommen sie in der Reihenfolge an, in der sie
    /// entstanden sind.
    private static var conversationWrites: Task<Void, Never>?
    /// Unterhaltungen, die in der Datenbank stehen oder auf dem Weg dorthin sind.
    private static var persistedConversations: Set<UUID> = []

    private func persist(_ conversation: ChatConversation) {
        Self.persistedConversations.insert(conversation.id)
        enqueueConversationWrite { store in try await store.save(conversation: conversation) }
    }

    /// Löscht eine Unterhaltung in der Datenbank.
    private func forgetConversation(_ id: UUID) {
        Self.persistedConversations.remove(id)
        enqueueConversationWrite { store in try await store.removeConversation(id: id) }
    }

    /// Eine leere Unterhaltung statt der bisherigen, gleich gesichert. Andere
    /// leere desselben Bereichs gehen.
    private func replaceWithEmptyConversation(for key: ChatConversationKey) {
        let fresh = ChatConversation(key: key)
        conversations[key] = fresh
        persist(fresh)
        let id = fresh.id
        enqueueConversationWrite { store in try await store.removeEmptyConversations(for: key, keeping: id) }
    }

    /// Ein gescheitertes Sichern wird gemeldet, nicht verschluckt.
    private func enqueueConversationWrite(_ work: @escaping @Sendable (LibraryStore) async throws -> Void) {
        let previous = Self.conversationWrites
        let store = self.store
        Self.conversationWrites = Task { [weak self] in
            await previous?.value
            do {
                try await work(store)
            } catch {
                self?.lastError = String(localized: "Konnte nicht gesichert werden: \(error.localizedDescription)")
            }
        }
    }

    /// Gleicher Stand heißt: dieselbe Unterhaltung, derselbe Zeitpunkt, gleich viele Runden.
    private static func sameState(_ first: ChatConversation, _ second: ChatConversation) -> Bool {
        first.id == second.id && first.updatedAt == second.updatedAt && first.turns.count == second.turns.count
    }
}
