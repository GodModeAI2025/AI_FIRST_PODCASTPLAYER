//
//  ShareInboxItem.swift
//  PodcastAIShareInbox
//
//  Was „An PodcastAI senden“ an die App übergibt: ein Link oder eine
//  Audiodatei. Die Erweiterung legt nichts an. Sie schreibt einen kleinen
//  Eintrag in den gemeinsamen Ordner der App Group, die App liest ihn beim
//  Start oder beim Wechsel in den Vordergrund und zeigt die Vorschau.
//
//  Der Eintrag ist fremde Eingabe, auch wenn nur die eigene Erweiterung ihn
//  schreiben kann: Beim Lesen prüft die App Link, Dateiname und Größe noch
//  einmal, bevor sie damit etwas tut.
//

import Foundation

/// Ein Eintrag im Eingang, so wie er als JSON im Ordner der App Group liegt.
public struct ShareInboxItem: Codable, Sendable, Equatable, Identifiable {

    public enum Kind: String, Codable, Sendable {
        case link
        case audioFile
    }

    /// Die Fassung des Formats. Ältere Einträge liest die App weiter,
    /// neuere, die sie nicht kennt, verwirft sie.
    public static let currentVersion = 1

    public var version: Int
    public let id: UUID
    public let createdAt: Date
    public let kind: Kind
    /// Nur bei `link`: die geteilte Adresse.
    public let link: String?
    /// Nur bei `audioFile`: der Name der Kopie im Ordner `Files`, immer
    /// `<Kennung>.<Endung>`.
    public let storedFileName: String?
    /// Nur bei `audioFile`: der ursprüngliche Name ohne Endung, als Titel.
    public let displayName: String?
    /// Nur bei `audioFile`: die Größe der Kopie in Byte.
    public let byteCount: Int64?

    public init(
        id: UUID = UUID(), createdAt: Date, kind: Kind, link: String? = nil,
        storedFileName: String? = nil, displayName: String? = nil, byteCount: Int64? = nil,
        version: Int = ShareInboxItem.currentVersion
    ) {
        self.version = version
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.link = link
        self.storedFileName = storedFileName
        self.displayName = displayName
        self.byteCount = byteCount
    }

    /// Ein Link-Eintrag.
    public static func link(_ url: URL, id: UUID = UUID(), at date: Date) -> ShareInboxItem {
        ShareInboxItem(id: id, createdAt: date, kind: .link, link: url.absoluteString)
    }

    // MARK: JSON

    /// Größer wird ein Eintrag nie. Was größer ist, liest die App gar nicht erst.
    public static let maximumEncodedBytes = 16 * 1024

    public static func encode(_ item: ShareInboxItem) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(item)
    }

    public static func decode(_ data: Data) throws -> ShareInboxItem {
        guard data.count <= maximumEncodedBytes else { throw ShareInboxError.unreadableEntry }
        do {
            let item = try JSONDecoder().decode(ShareInboxItem.self, from: data)
            guard (1...currentVersion).contains(item.version) else { throw ShareInboxError.unreadableEntry }
            return item
        } catch let error as ShareInboxError {
            throw error
        } catch {
            throw ShareInboxError.unreadableEntry
        }
    }
}

/// Der geprüfte Inhalt eines Eintrags.
public enum SharedContent: Sendable, Equatable {
    /// Ein Link, den die App wie einen eingefügten behandelt.
    case link(URL)
    /// Eine Audiodatei im Ordner der App Group.
    case audioFile(URL, displayName: String, byteCount: Int64)
}
