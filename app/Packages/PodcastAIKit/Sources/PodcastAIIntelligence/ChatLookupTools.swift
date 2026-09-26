//
//  ChatLookupTools.swift
//  PodcastAIIntelligence
//
//  Die Werkzeuge, mit denen das Modell im Chat selbst nachschlägt: weitere
//  Stellen, die Fakten, die Nennungen und die Kapitel einer Folge. Sie
//  lesen nur. Jedes gibt die Anfrage an ``ChatLookupLedger`` weiter, das
//  jede Kennung prüft, die Größe begrenzt und das Ergebnis als Daten
//  kennzeichnet. Hier steht nur, was FoundationModels braucht: Namen,
//  Beschreibungen und Argumente.
//
//  Die Werkzeuge hängen an einem ``ChatLookupSlot`` statt direkt am Buch
//  einer Frage. So kann eine Sitzung vorgewärmt werden, bevor die Frage
//  feststeht; das Buch kommt erst mit der Frage in den Slot.
//
//  Ob gerade ein Werkzeug läuft, meldet das Buch selbst aus dem Aufruf
//  heraus (``ChatLookupLedger/Observer``). `onToolCall` gibt es im SDK nur
//  an einem `DynamicProfile`, also für Sitzungen, die anders gebaut werden
//  als die des Chats.
//

#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Synchronization
import PodcastAICore

/// Das Buch der laufenden Frage, für die Werkzeuge einer Sitzung.
public final class ChatLookupSlot: Sendable {

    private let current: Mutex<ChatLookupLedger?>

    public init(_ ledger: ChatLookupLedger? = nil) {
        current = Mutex(ledger)
    }

    /// Setzt das Buch einer Frage ein, etwa in eine vorgewärmte Sitzung.
    public func install(_ ledger: ChatLookupLedger?) {
        current.withLock { $0 = ledger }
    }

    /// Ohne Buch gibt es nichts nachzuschlagen, und das Modell erfährt das
    /// als Text. Eine Ausnahme bräche die ganze Antwort ab.
    func perform(_ request: ChatLookupRequest) async throws -> String {
        guard let ledger = current.withLock({ $0 }) else { return ChatLookupLedger.unavailableNotice }
        return try await ledger.perform(request)
    }
}

/// Die vier Werkzeuge des Chats.
public enum ChatLookupTools {

    /// Die Werkzeuge für eine Sitzung, alle am selben Slot.
    public static func make(slot: ChatLookupSlot) -> [any Tool] {
        [SearchPassagesTool(slot: slot), EpisodeFactsTool(slot: slot),
         EpisodeMentionsTool(slot: slot), EpisodeChaptersTool(slot: slot)]
    }

    /// Was die Beschreibungen der Werkzeuge im Fenster des Geräts kosten.
    /// Sie ändern sich nie, also einmal gezählt. `nil`, solange der
    /// Tokenizer nicht geantwortet hat; dann gilt die Schätzung aus
    /// ``ChatLookupLimits/estimatedSchemaTokens``.
    public static func schemaTokens() async -> Int? {
        if let known = countedSchema.withLock({ $0 }) { return known }
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }
        let tools = make(slot: ChatLookupSlot())
        return try? await KnowledgeExtractor.withinTokenDeadline {
            let counted = try await model.tokenCount(for: tools)
            countedSchema.withLock { $0 = counted }
            return counted
        }
    }

    private static let countedSchema = Mutex<Int?>(nil)

    /// Zählt ein Ergebnis mit dem Tokenizer des Geräts. Das Modell wartet
    /// währenddessen, deshalb nur kurz; danach gilt die vorsichtige
    /// Schätzung des Buchs.
    public static let tokenCounter: ChatLookupLedger.TokenCounter = { text in
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }
        return try? await KnowledgeExtractor.withinTokenDeadline(tokenCountDeadline) {
            try await model.tokenCount(for: text)
        }
    }

    static let tokenCountDeadline = Duration.milliseconds(300)
}

// MARK: - Werkzeuge

/// Weitere Stellen aus den Transkripten.
struct SearchPassagesTool: Tool {
    let slot: ChatLookupSlot
    let name = "searchPassages"
    let description = """
        Holt weitere Stellen aus den Transkripten, beste zuerst. Nur nutzen, wenn die \
        Abschnitte die Frage nicht beantworten.
        """

    @Generable
    struct Arguments {
        @Guide(description: "Wenige Suchbegriffe, gern in der Sprache des Podcasts.")
        let query: String
        @Guide(description: "Kennung der Folge wie F2. Leer für alle Folgen der Frage.")
        let episode: String?
        @Guide(description: "Nummer eines Kapitels dieser Folge aus episodeChapters. Leer für die ganze Folge.")
        let chapter: Int?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        try await slot.perform(.passages(query: arguments.query, episode: arguments.episode,
                                         chapter: arguments.chapter))
    }
}

/// Die gespeicherten Fakten einer Folge.
struct EpisodeFactsTool: Tool {
    let slot: ChatLookupSlot
    let name = "episodeFacts"
    let description = "Holt die Fakten einer Folge, jeder mit der Nummer seiner Stelle."

    @Generable
    struct Arguments {
        @Guide(description: "Kennung der Folge wie F2. Leer, wenn die Frage einer einzelnen Folge gilt.")
        let episode: String?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        try await slot.perform(.facts(episode: arguments.episode))
    }
}

/// Links, Termine, Adressen und Namen einer Folge.
struct EpisodeMentionsTool: Tool {
    let slot: ChatLookupSlot
    let name = "episodeMentions"
    let description = "Holt Links, Termine, Adressen, Telefonnummern, E-Mail-Adressen und Namen, die eine Folge nennt."

    @Generable
    struct Arguments {
        @Guide(description: "Kennung der Folge wie F2. Leer, wenn die Frage einer einzelnen Folge gilt.")
        let episode: String?
        @Guide(description: "Welche Art Nennung.", .anyOf(ChatLookupTools.mentionKindValues))
        let kind: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        try await slot.perform(.mentions(episode: arguments.episode, kind: arguments.kind))
    }
}

/// Die Kapitel einer Folge.
struct EpisodeChaptersTool: Tool {
    let slot: ChatLookupSlot
    let name = "episodeChapters"
    let description = "Holt die Kapitel einer Folge mit Nummer und Titel."

    @Generable
    struct Arguments {
        @Guide(description: "Kennung der Folge wie F2. Leer, wenn die Frage einer einzelnen Folge gilt.")
        let episode: String?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        try await slot.perform(.chapters(episode: arguments.episode))
    }
}

extension ChatLookupTools {
    /// Was das Modell als Art einer Nennung wählen darf.
    static let mentionKindValues = [ChatLookupLedger.allMentionKinds] + ChatLookupLedger.mentionKinds.map(\.key)
}
#endif
