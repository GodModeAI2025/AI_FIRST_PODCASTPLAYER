//
//  ShareInbox.swift
//  PodcastAIShareInbox
//
//  Der Eingang im Ordner der App Group. Jeder Eintrag ist eine eigene
//  JSON-Datei unter `Items`, eine geteilte Audiodatei liegt als Kopie
//  unter `Files`. So überschreibt keine Freigabe eine andere, auch wenn
//  zwei kurz hintereinander kommen, und die App liest nie einen halben
//  Eintrag: Die Datei wird zuerst kopiert, der Eintrag danach in einem
//  Schritt geschrieben.
//
//  Nur Foundation. Die Erweiterung lädt damit keine großen Frameworks.
//

import Foundation

public enum ShareInboxError: Error, LocalizedError, Equatable, Sendable {
    /// Der Ordner der App Group fehlt, etwa ohne Berechtigung im Build.
    case unavailable
    /// In der Freigabe steckt kein Link, den die App lesen kann.
    case noLink
    case fileTooLarge(limit: Int64)
    case emptyFile
    case notAudio
    case fileMissing
    case tooManyPending(Int)
    case unreadableEntry

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "PodcastAI kann gerade nichts übernehmen. Öffne die App einmal und versuche es dann noch einmal.", bundle: .module)
        case .noLink:
            String(localized: "Darin steckt kein Link, den PodcastAI lesen kann.", bundle: .module)
        case .fileTooLarge(let limit):
            String(localized: "Die Datei ist größer als \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)). So große Dateien nimmt PodcastAI nicht an.", bundle: .module)
        case .emptyFile:
            String(localized: "Die Datei ist leer.", bundle: .module)
        case .notAudio:
            String(localized: "Das ist keine Audiodatei, die PodcastAI lesen kann. MP3, M4A, AAC, WAV, FLAC und Ogg gehen.", bundle: .module)
        case .fileMissing:
            String(localized: "Die geteilte Datei ist nicht mehr da. Teile sie bitte noch einmal.", bundle: .module)
        case .tooManyPending(let count):
            String(localized: "Es warten schon \(count) Übergaben. Öffne PodcastAI, dann geht es weiter.", bundle: .module)
        case .unreadableEntry:
            String(localized: "Die Übergabe ließ sich nicht lesen.", bundle: .module)
        }
    }
}

public struct ShareInbox: Sendable {

    /// Dieselbe App Group wie für das Widget.
    public static let appGroupIdentifier = "group.com.godmodeai.podcastai"

    /// Öffnet die App und lässt sie den Eingang lesen. Die Adresse trägt
    /// keine Daten; was ankommt, steht nur im Ordner der App Group.
    public static let openAppURL = URL(string: "podcastai://share-inbox")!

    /// Wie beim Laden einer Folge (`MediaDownloader.maximumBytes`).
    public static let maximumFileBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Mehr wartende Übergaben nimmt die Erweiterung nicht an.
    public static let maximumPendingItems = 20

    /// Was so lange niemand geöffnet hat, verwirft die App.
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    /// Eine Datei ohne Eintrag ist ein Rest einer abgebrochenen Freigabe.
    /// Die Frist lässt einer laufenden Freigabe Zeit, ihren Eintrag zu schreiben.
    public static let orphanLifetime: TimeInterval = 60 * 60

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Der Eingang im Ordner der App Group, `nil` ohne Berechtigung.
    public static func appGroup() -> ShareInbox? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            .map { ShareInbox(directory: $0.appendingPathComponent("ShareInbox", isDirectory: true)) }
    }

    var itemsDirectory: URL { directory.appendingPathComponent("Items", isDirectory: true) }
    var filesDirectory: URL { directory.appendingPathComponent("Files", isDirectory: true) }

    // MARK: Schreiben (Erweiterung)

    /// Legt einen Link in den Eingang.
    @discardableResult
    public func deposit(link text: String, now: Date = Date()) throws -> ShareInboxItem {
        guard let url = SharedLinks.link(in: text) else { throw ShareInboxError.noLink }
        try ensureRoom()
        let item = ShareInboxItem.link(url, at: now)
        try write(item)
        return item
    }

    /// Kopiert eine Audiodatei in den Eingang und legt den Eintrag dazu an.
    /// Ob es Ton ist, prüft die Erweiterung am Typ und die App noch einmal
    /// am Anfang der Datei.
    @discardableResult
    public func deposit(audioFileAt source: URL, originalName: String?, now: Date = Date()) throws -> ShareInboxItem {
        let size = try Self.fileSize(of: source)
        guard size > 0 else { throw ShareInboxError.emptyFile }
        guard size <= Self.maximumFileBytes else { throw ShareInboxError.fileTooLarge(limit: Self.maximumFileBytes) }
        try ensureRoom()

        let id = UUID()
        let name = originalName ?? source.lastPathComponent
        let stored = Self.storedFileName(id: id, fileExtension: (name as NSString).pathExtension)
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        let target = filesDirectory.appendingPathComponent(stored)
        try FileManager.default.copyItem(at: source, to: target)
        let item = ShareInboxItem(id: id, createdAt: now, kind: .audioFile, storedFileName: stored,
                                  displayName: Self.title(fromFileName: name), byteCount: size)
        do {
            try write(item)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return item
    }

    private func ensureRoom() throws {
        let waiting = (try? FileManager.default.contentsOfDirectory(atPath: itemsDirectory.path))?
            .filter { $0.hasSuffix(".json") }.count ?? 0
        guard waiting < Self.maximumPendingItems else { throw ShareInboxError.tooManyPending(waiting) }
    }

    private func write(_ item: ShareInboxItem) throws {
        try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        try ShareInboxItem.encode(item).write(to: entryURL(for: item.id), options: .atomic)
    }

    private func entryURL(for id: UUID) -> URL {
        itemsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: Lesen (App)

    /// Die wartenden Einträge, älteste zuerst. Was sich nicht lesen lässt,
    /// zu alt ist oder seine Datei verloren hat, räumt die Methode dabei weg,
    /// ebenso Dateien ohne Eintrag.
    public func pending(now: Date = Date()) -> [ShareInboxItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: itemsDirectory.path)) ?? []
        var items: [ShareInboxItem] = []
        for name in names where name.hasSuffix(".json") {
            let url = itemsDirectory.appendingPathComponent(name)
            guard let item = Self.readEntry(at: url), "\(item.id.uuidString).json" == name else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard now.timeIntervalSince(item.createdAt) <= Self.lifetime, (try? content(of: item)) != nil else {
                remove(item)
                continue
            }
            items.append(item)
        }
        removeOrphanFiles(keeping: Set(items.compactMap(\.storedFileName)), now: now)
        return items.sorted { $0.createdAt < $1.createdAt }
    }

    /// Prüft einen Eintrag und liefert, was darin steckt.
    public func content(of item: ShareInboxItem) throws -> SharedContent {
        switch item.kind {
        case .link:
            guard let text = item.link, let url = SharedLinks.accepted(text) else { throw ShareInboxError.noLink }
            return .link(url)
        case .audioFile:
            guard let stored = item.storedFileName, Self.isValidStoredName(stored, id: item.id)
            else { throw ShareInboxError.unreadableEntry }
            let file = filesDirectory.appendingPathComponent(stored)
            guard let size = try? Self.fileSize(of: file) else { throw ShareInboxError.fileMissing }
            guard size > 0 else { throw ShareInboxError.emptyFile }
            guard size <= Self.maximumFileBytes else { throw ShareInboxError.fileTooLarge(limit: Self.maximumFileBytes) }
            return .audioFile(file, displayName: Self.sanitizedTitle(item.displayName ?? ""), byteCount: size)
        }
    }

    /// Entfernt einen Eintrag samt Datei. Hat die App die Datei schon
    /// übernommen, ist nur noch der Eintrag da.
    public func remove(_ item: ShareInboxItem) {
        try? FileManager.default.removeItem(at: entryURL(for: item.id))
        if let stored = item.storedFileName, Self.isValidStoredName(stored, id: item.id) {
            try? FileManager.default.removeItem(at: filesDirectory.appendingPathComponent(stored))
        }
    }

    /// Leert den Eingang, etwa für UI-Tests mit leerem Speicher.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Das Alter einer Datei zählt ab ihrer letzten Statusänderung (ctime),
    /// nicht ab dem Änderungsdatum des Inhalts. Die Kopie der Erweiterung
    /// übernimmt Änderungs- und Erstelldatum des Originals; eine Stunden alte
    /// Aufnahme sähe so schon vor ihrem Eintrag wie ein Rest aus und ginge
    /// weg, wenn die App genau dann liest. Die Statusänderung setzt jede
    /// Kopie neu.
    private func removeOrphanFiles(keeping kept: Set<String>, now: Date) {
        let keys: Set<URLResourceKey> = [.attributeModificationDateKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: filesDirectory, includingPropertiesForKeys: Array(keys))) ?? []
        for file in files where !kept.contains(file.lastPathComponent) {
            let values = try? file.resourceValues(forKeys: keys)
            let changed = values?.attributeModificationDate ?? values?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(changed) > Self.orphanLifetime {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func readEntry(at url: URL) -> ShareInboxItem? {
        guard let size = try? fileSize(of: url), size <= ShareInboxItem.maximumEncodedBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? ShareInboxItem.decode(data)
    }

    // MARK: Namen und Größen

    static func fileSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else { throw ShareInboxError.fileMissing }
        return Int64(size)
    }

    /// `<Kennung>.<Endung>`, die Endung nur aus Buchstaben und Ziffern.
    static func storedFileName(id: UUID, fileExtension: String) -> String {
        let cleaned = String(fileExtension.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
            .prefix(8).map(Character.init))
        return cleaned.isEmpty ? id.uuidString : "\(id.uuidString).\(cleaned)"
    }

    /// Nur Namen, die `storedFileName` selbst bildet. Kein Pfad, kein `..`.
    static func isValidStoredName(_ name: String, id: UUID) -> Bool {
        guard name.hasPrefix(id.uuidString), !name.contains("/"), !name.contains("\\") else { return false }
        let rest = name.dropFirst(id.uuidString.count)
        if rest.isEmpty { return true }
        guard rest.first == ".", rest.count <= 9 else { return false }
        return rest.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Der Titel aus dem Dateinamen, ohne Endung.
    static func title(fromFileName name: String) -> String {
        sanitizedTitle((name.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).deletingPathExtension)
    }

    /// Ohne Steuerzeichen und höchstens 120 Zeichen. Ein leerer Titel wird
    /// zu „Geteilte Audiodatei“.
    static func sanitizedTitle(_ text: String) -> String {
        let cleaned = String(text.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(Character.init))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleaned.isEmpty ? String(localized: "Geteilte Audiodatei", bundle: .module) : cleaned
        return String(title.prefix(120))
    }
}
