//
//  StoredChatConversation.swift
//  PodcastAIPersistence
//
//  Eine Unterhaltung im Chat, seit dem Schema nach 0.13.
//
//  Wie bei den gesicherten Antworten (`StoredKnowledgeTrail`) liegt der
//  Inhalt als JSON in einem Feld, daneben stehen nur die Spalten, nach
//  denen gefragt wird: Kennung, Bereich, Titel und Stand. Das JSON trägt
//  seine eigene Formatnummer (`ChatConversation.formatVersion`), eine
//  Kopie steht in `formatVersion`.
//
//  CloudKit-tauglich wie alle Modelle: jedes Feld mit Standardwert, keine
//  eindeutigen Schlüssel, keine Beziehungen. Doppelte Zeilen derselben
//  Unterhaltung räumt `LibraryStore+Conversations.swift` beim Lesen und
//  Speichern selbst auf.
//

#if canImport(SwiftData)
import Foundation
import SwiftData

@Model
public final class StoredChatConversation {
    #Index<StoredChatConversation>([\.identifier], [\.scopeKey], [\.updatedAt])
    /// `ChatConversation.id` als Text.
    public var identifier: String = ""
    /// „library“ oder „episode:<Kennung der Folge>“ (`ChatConversationKey`).
    public var scopeKey: String = ""
    /// Die erste Frage, für die Liste, ohne das JSON zu lesen.
    public var title: String = ""
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var turnCount: Int = 0
    public var formatVersion: Int = 1
    @Attribute(.externalStorage) public var payload: Data = Data()

    public init(identifier: String, scopeKey: String, title: String, createdAt: Date, updatedAt: Date,
                turnCount: Int, formatVersion: Int, payload: Data) {
        self.identifier = identifier
        self.scopeKey = scopeKey
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turnCount = turnCount
        self.formatVersion = formatVersion
        self.payload = payload
    }
}
#endif
