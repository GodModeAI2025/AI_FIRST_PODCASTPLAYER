//
//  ShareInboxTests.swift
//  PodcastAIKitTests
//
//  „An PodcastAI senden“: der Eingang in der App Group. Einträge als JSON
//  hin und zurück, was die Erweiterung annimmt und was die App beim Lesen
//  verwirft, und dass die Einordnung der Links dieselben Regeln nimmt wie
//  das Blatt „Hinzufügen“.
//

import Foundation
import Testing
@testable import PodcastAIShareInbox
@testable import PodcastAISources
import PodcastAIMedia

// MARK: - Hilfen

/// Ein Eingang in einem eigenen temporären Ordner, der nach dem Test weg ist.
private struct TemporaryInbox {
    let root: URL
    let inbox: ShareInbox

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareInboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        inbox = ShareInbox(directory: root.appendingPathComponent("ShareInbox", isDirectory: true))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// Eine kleine Datei, die wie MP3 beginnt.
    func audioFile(named name: String, bytes: Int = 2048) throws -> URL {
        let url = root.appendingPathComponent(name)
        var data = Data("ID3".utf8)
        data.append(Data(repeating: 0, count: max(0, bytes - 3)))
        try data.write(to: url)
        return url
    }

    func entryURL(_ id: UUID) -> URL { inbox.itemsDirectory.appendingPathComponent("\(id.uuidString).json") }

    /// Schreibt einen Eintrag an der Erweiterung vorbei, etwa einen manipulierten.
    func writeRaw(_ item: ShareInboxItem) throws {
        try FileManager.default.createDirectory(at: inbox.itemsDirectory, withIntermediateDirectories: true)
        try ShareInboxItem.encode(item).write(to: entryURL(item.id))
    }
}

// MARK: - JSON

@Suite("Eingang: Einträge als JSON")
struct ShareInboxEncodingTests {

    @Test("Link und Audiodatei kommen unverändert zurück")
    func roundTrip() throws {
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.25)
        let link = ShareInboxItem.link(URL(string: "https://youtu.be/pOX1l1edBME?si=abc")!, at: date)
        let file = ShareInboxItem(createdAt: date, kind: .audioFile,
                                  storedFileName: "\(UUID().uuidString).m4a",
                                  displayName: "Sprachmemo 12", byteCount: 123_456)
        for item in [link, file] {
            let decoded = try ShareInboxItem.decode(try ShareInboxItem.encode(item))
            #expect(decoded == item)
        }
    }

    @Test("Das Format ist lesbar und stabil: sortierte Schlüssel, Art als Wort")
    func stableFormat() throws {
        let id = UUID(uuidString: "6F1C2A34-0000-4000-8000-000000000001")!
        let item = ShareInboxItem.link(URL(string: "https://example.com/feed.xml")!, id: id,
                                       at: Date(timeIntervalSinceReferenceDate: 0))
        let json = String(decoding: try ShareInboxItem.encode(item), as: UTF8.self)
        #expect(json.contains(#""kind":"link""#))
        #expect(json.contains(#""version":1"#))
        #expect(json.contains(id.uuidString))
        let keys = ["createdAt", "id", "kind", "link", "version"]
        let positions = keys.compactMap { json.range(of: "\"\($0)\"")?.lowerBound }
        #expect(positions.count == keys.count)
        #expect(positions == positions.sorted())
    }

    @Test("Unbekannte Fassung, fremdes JSON und zu große Einträge werden verworfen")
    func rejectsForeignEntries() throws {
        var future = ShareInboxItem.link(URL(string: "https://example.com/feed.xml")!, at: Date())
        future.version = ShareInboxItem.currentVersion + 1
        #expect(throws: ShareInboxError.unreadableEntry) { try ShareInboxItem.decode(try ShareInboxItem.encode(future)) }
        #expect(throws: ShareInboxError.unreadableEntry) { try ShareInboxItem.decode(Data("{\"kind\":\"script\"}".utf8)) }
        #expect(throws: ShareInboxError.unreadableEntry) { try ShareInboxItem.decode(Data("kein json".utf8)) }
        let huge = Data(repeating: 0x20, count: ShareInboxItem.maximumEncodedBytes + 1)
        #expect(throws: ShareInboxError.unreadableEntry) { try ShareInboxItem.decode(huge) }
    }
}

// MARK: - Schreiben und Lesen

@Suite("Eingang: Übergabe zwischen Erweiterung und App")
struct ShareInboxStoreTests {

    @Test("Ein geteilter Satz mit Link wird zu einem Link-Eintrag")
    func depositLinkFromText() throws {
        let temp = try TemporaryInbox()
        defer { temp.cleanUp() }
        let shared = "Hör dir das an: https://podcasts.apple.com/de/podcast/x/id1234567890?i=1000651234567 wirklich gut"
        let item = try temp.inbox.deposit(link: shared)
        #expect(item.kind == .link)
        let pending = temp.inbox.pending()
        #expect(pending == [item])
        #expect(try temp.inbox.content(of: item)
                == .link(URL(string: "https://podcasts.apple.com/de/podcast/x/id1234567890?i=1000651234567")!))
    }

    @Test("Ohne lesbaren Link nimmt der Eingang nichts an")
    func rejectsWithoutLink() throws {
        let temp = try TemporaryInbox()
        defer { temp.cleanUp() }
        for text in ["", "nur Text ohne Adresse", "file:///etc/hosts", "podcastai://share-inbox",
                     "javascript:alert(1)", "mailto:hallo@example.com",
                     "https://" + String(repeating: "a", count: SharedLinks.maximumLength)] {
            #expect(throws: ShareInboxError.noLink, "\(text.prefix(40))") { try temp.inbox.deposit(link: text) }
        }
        #expect(temp.inbox.pending().isEmpty)
    }

    @Test("Eine Audiodatei wird kopiert, der Titel ist der Name ohne Endung")
    func depositAudioFile() throws {
        let temp = try TemporaryInbox()
        defer { temp.cleanUp() }
        let source = try temp.audioFile(named: "Folge 12.5 Interview.mp3")
        let item = try temp.inbox.deposit(audioFileAt: source, originalName: "Folge 12.5 Interview.mp3")
        #expect(item.kind == .audioFile)
        #expect(item.storedFileName == "\(item.id.uuidString).mp3")
        #expect(item.displayName == "Folge 12.5 Interview")
        #expect(item.byteCount == 2048)
        // Die Quelle bleibt, der Eingang hat eine eigene Kopie.
        #expect(FileManager.default.fileExists(atPath: source.path))

        guard case .audioFile(let file, let name, let bytes) = try temp.inbox.content(of: item) else {
            Issue.record("Keine Audiodatei"); return
        }
        #expect(file.deletingLastPathComponent().standardizedFileURL == temp.inbox.filesDirectory.standardizedFileURL)
        #expect(name == "Folge 12.5 Interview")
        #expect(bytes == 2048)
        #expect(try Data(contentsOf: file).prefix(3) == Data("ID3".utf8))

        temp.inbox.remove(item)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(temp.inbox.pending().isEmpty)
    }

    @Test("Leere und zu große Dateien lehnt die Erweiterung ab")
    func rejectsEmptyAndHugeFiles() throws {
        let temp = try TemporaryInbox()
        defer { temp.cleanUp() }
        let empty = temp.root.appendingPathComponent("leer.m4a")
        try Data().write(to: empty)
        #expect(throws: ShareInboxError.emptyFile) { try temp.inbox.deposit(audioFileAt: empty, originalName: nil) }

        // Eine dünn belegte Datei: groß im Verzeichnis, fast nichts auf der Platte.
        let huge = temp.root.appendingPathComponent("riesig.wav")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: Data("RIFF".utf8)))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(ShareInbox.maximumFileBytes) + 1)
        try handle.close()
        #expect(throws: ShareInboxError.fileTooLarge(limit: ShareInbox.maximumFileBytes)) {
            try temp.inbox.deposit(audioFileAt: huge, originalName: "riesig.wav")
        }
        #expect(temp.inbox.pending().isEmpty)
    }

    @Test("Die Obergrenze ist dieselbe wie beim Laden einer Folge")
    func sizeLimitMatchesDownloads() {
        #expect(ShareInbox.maximumFileBytes == MediaDownloader.maximumBytes)
    }

    @Test("Mehr als 20 wartende Übergaben nimmt die Erweiterung nicht an")
    func limitsPendingItems() throws {
        let temp = try TemporaryInbox()
        defer { temp.cleanUp() }
        for index in 0..<ShareInbox.maximumPendingItems {
            try temp.inbox.deposit(link: "https://example.com/feeds/\(index).xml")
        }
        #expect(throws: ShareInboxError.tooManyPending(ShareInbox.maximumPendingItems)) {
            try temp.inbox.deposit(link: "https://example.com/feeds/zu-viel.xml")
        }
        #expect(temp.inbox.pending().count == ShareInbox.maximumPendingItems)
    }

    @Test("Älteste zuerst; Abgelaufenes geht mitsamt Datei")
    func orderAndExpiry() throws {
        let temp = try TemporaryInbox()
        defer { temp.cleanUp() }
        let now = Date()
        let newer = try temp.inbox.deposit(link: "https://example.com/b.xml", now: now.addingTimeInterval(-60))
        let older = try temp.inbox.deposit(link: "https://example.com/a.xml", now: now.addingTimeInterval(-600))
        let source = try temp.audioFile(named: "alt.mp3")
        let expired = try temp.inbox.deposit(audioFileAt: source, originalName: "alt.mp3",
                                             now: now.addingTimeInterval(-ShareInbox.lifetime - 1))
        let expiredFile = temp.inbox.filesDirectory.appendingPathComponent(expired.storedFileName!)
        #expect(FileManager.default.fileExists(atPath: expiredFile.path))

        #expect(temp.inbox.pending(now: now) == [older, newer])
        #expect(!FileManager.default.fileExists(atPath: expiredFile.path))
        #expect(!FileManager.default.fileExists(atPath: temp.entryURL(expired.id).path))
    }

    @Test("Manipulierte Einträge verwirft die App beim Lesen")
    func dropsTamperedEntries() throws {
        let temp = try TemporaryInbox()
        defer { temp.cleanUp() }
        let now = Date()
        // Ein Pfad aus dem Ordner heraus.
        let escape = ShareInboxItem(createdAt: now, kind: .audioFile, storedFileName: "../../Library/Preferences/x.plist",
                                    displayName: "x", byteCount: 1)
        // Ein Link auf eine Datei des Geräts.
        let localFile = ShareInboxItem(createdAt: now, kind: .link, link: "file:///etc/hosts")
        // Ein Link-Eintrag ohne Link.
        let empty = ShareInboxItem(createdAt: now, kind: .link)
        // Eine Audiodatei, deren Kopie fehlt.
        let missing = ShareInboxItem(createdAt: now, kind: .audioFile, storedFileName: "\(UUID().uuidString).mp3",
                                     displayName: "weg", byteCount: 10)
        for item in [escape, localFile, empty, missing] { try temp.writeRaw(item) }
        // Ein Eintrag, dessen Dateiname nicht zu seiner Kennung passt.
        let renamed = ShareInboxItem.link(URL(string: "https://example.com/feed.xml")!, at: now)
        try FileManager.default.createDirectory(at: temp.inbox.itemsDirectory, withIntermediateDirectories: true)
        try ShareInboxItem.encode(renamed).write(to: temp.entryURL(UUID()))
        // Kein JSON.
        try Data("kaputt".utf8).write(to: temp.entryURL(UUID()))

        #expect(temp.inbox.pending(now: now).isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: temp.inbox.itemsDirectory.path)
        #expect(left.isEmpty, "\(left)")
    }

    @Test("Dateien ohne Eintrag gehen nach einer Stunde, frische bleiben")
    func removesOrphanFiles() throws {
        let temp = try TemporaryInbox()
        defer { temp.cleanUp() }
        try FileManager.default.createDirectory(at: temp.inbox.filesDirectory, withIntermediateDirectories: true)
        let orphan = temp.inbox.filesDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
        try Data("ID3".utf8).write(to: orphan)

        _ = temp.inbox.pending()
        #expect(FileManager.default.fileExists(atPath: orphan.path), "Eine frische Datei ging weg")
        _ = temp.inbox.pending(now: Date().addingTimeInterval(ShareInbox.orphanLifetime + 60))
        #expect(!FileManager.default.fileExists(atPath: orphan.path), "Eine Stunde alte Datei ohne Eintrag blieb")
    }

    /// Die Erweiterung kopiert erst die Datei und schreibt dann den Eintrag.
    /// Die Kopie trägt das Änderungsdatum des Originals. Liest die App
    /// dazwischen, darf sie eine alte Aufnahme nicht für einen Rest halten.
    @Test("Eine frisch kopierte alte Aufnahme ohne Eintrag bleibt liegen")
    func keepsFreshCopyOfOldFile() throws {
        let temp = try TemporaryInbox()
        defer { temp.cleanUp() }
        let original = try temp.audioFile(named: "Alte Aufnahme.mp3")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3 * 24 * 60 * 60)], ofItemAtPath: original.path)
        try FileManager.default.createDirectory(at: temp.inbox.filesDirectory, withIntermediateDirectories: true)
        let copy = temp.inbox.filesDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
        try FileManager.default.copyItem(at: original, to: copy)
        let copied = try copy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(copied.map { Date().timeIntervalSince($0) > ShareInbox.orphanLifetime } == true,
                "Die Kopie übernimmt das alte Änderungsdatum nicht mehr; der Test prüft dann nichts")

        _ = temp.inbox.pending()
        #expect(FileManager.default.fileExists(atPath: copy.path), "Die App räumte eine Datei weg, deren Eintrag noch kommt")
    }

    @Test("Gespeicherte Namen: nur Kennung und kurze Endung")
    func storedNames() {
        let id = UUID()
        #expect(ShareInbox.storedFileName(id: id, fileExtension: "MP3") == "\(id.uuidString).mp3")
        #expect(ShareInbox.storedFileName(id: id, fileExtension: "../x") == "\(id.uuidString).x")
        #expect(ShareInbox.storedFileName(id: id, fileExtension: "") == id.uuidString)
        #expect(ShareInbox.isValidStoredName("\(id.uuidString).m4a", id: id))
        #expect(ShareInbox.isValidStoredName(id.uuidString, id: id))
        #expect(!ShareInbox.isValidStoredName("\(id.uuidString).m4a/../../x", id: id))
        #expect(!ShareInbox.isValidStoredName("\(UUID().uuidString).m4a", id: id))
        #expect(!ShareInbox.isValidStoredName("\(id.uuidString)x.m4a", id: id))
        #expect(ShareInbox.title(fromFileName: "  \u{0007}Sprachmemo.m4a ") == "Sprachmemo")
        #expect(ShareInbox.title(fromFileName: ".m4a").isEmpty == false)
        #expect(ShareInbox.sanitizedTitle(String(repeating: "x", count: 500)).count == 120)
    }
}

// MARK: - Einordnung der Links

@Suite("Eingang: Links wie beim Einfügen einordnen")
struct SharedLinkClassificationTests {

    private func kind(_ text: String) -> SharedLinkKind? {
        SharedLinks.link(in: text).map(SharedLinks.classify)
    }

    @Test("Jede Art von Link, die die Erweiterung annimmt")
    func table() {
        let cases: [(String, SharedLinkKind)] = [
            ("https://podcasts.apple.com/de/podcast/lage/id1234567890?i=1000651234567", .applePodcastEpisode),
            ("https://podcasts.apple.com/de/podcast/lage/id1234567890", .applePodcast),
            ("https://open.spotify.com/episode/4rOoJ6Egrf8K2IrywzwOMk", .spotify),
            ("https://youtu.be/pOX1l1edBME?si=Ab12Cd34Ef56Gh78", .youTubeVideo),
            ("https://www.youtube.com/shorts/pOX1l1edBME", .youTubeVideo),
            ("https://www.youtube.com/@Lage", .youTubeChannel),
            ("https://www.youtube.com/channel/UCBJycsmduvYEL83R_U4JriQ", .youTubeChannel),
            ("https://www.youtube.com/playlist?list=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs", .youTubePlaylist),
            ("https://www.tiktok.com/@name/video/7234567890123456789", .socialPost(.tikTok)),
            ("https://www.instagram.com/reel/C8abcDEF123/", .socialPost(.instagram)),
            ("https://www.tiktok.com/@name", .socialProfile(.tikTok)),
            ("https://cdn.example.com/folgen/folge-12.mp3?source=share", .audioFile),
            ("https://example.com/feeds/morgenlage.xml", .podcastFeed),
            ("feed://example.com/feeds/morgenlage.xml", .podcastFeed),
            ("https://lage.podigee.io/123-neue-folge", .webPage),
        ]
        for (text, expected) in cases {
            #expect(kind(text) == expected, "\(text)")
        }
    }

    @Test("Aus geteiltem Text zählt der erste lesbare Link")
    func linkInSharedText() {
        #expect(SharedLinks.link(in: "Neue Folge! https://youtu.be/pOX1l1edBME?si=x via YouTube")?.absoluteString
                == "https://youtu.be/pOX1l1edBME?si=x")
        #expect(SharedLinks.link(in: "podcastai://share-inbox https://example.com/feed.xml")?.absoluteString
                == "https://example.com/feed.xml")
        #expect(SharedLinks.link(in: "  https://example.com/feed.xml\n")?.absoluteString == "https://example.com/feed.xml")
        #expect(SharedLinks.link(in: "file:///Users/x/folge.mp3") == nil)
    }

    /// Die Erweiterung erfindet keine eigenen Regeln: Was `SourceResolver`,
    /// `EpisodeLinks` und `SocialLinks` sagen, sagt auch die Einordnung.
    @Test("Dieselben Regeln wie SourceResolver, EpisodeLinks und SocialLinks")
    func reusesExistingRules() throws {
        let forms = [
            "https://www.youtube.com/watch?v=pOX1l1edBME&si=abc", "https://youtu.be/pOX1l1edBME?t=42",
            "https://www.youtube.com/live/pOX1l1edBME?feature=share", "https://music.youtube.com/watch?v=pOX1l1edBME",
            "https://www.youtube.com/c/Lage", "https://www.youtube.com/user/Lage",
            "https://www.youtube.com/feeds/videos.xml?channel_id=UCBJycsmduvYEL83R_U4JriQ",
            "https://www.youtube.com/feeds/videos.xml?playlist_id=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs",
            "https://example.com/podcast/rss", "https://example.com/folge.m4a", "https://example.com/ueber-uns",
            "https://podcasts.apple.com/us/podcast/id1234567890?i=1000651234567",
            "https://itunes.apple.com/de/podcast/id1234567890",
            "https://www.instagram.com/p/C8abcDEF123/", "https://x.com/name/status/1790000000000000000",
        ]
        for form in forms {
            let url = try #require(SharedLinks.link(in: form), "\(form)")
            let kind = SharedLinks.classify(url)
            if let social = SocialLinks.classify(url) {
                switch social {
                case .post(let platform, _): #expect(kind == .socialPost(platform), "\(form)")
                case .profile(let platform, _): #expect(kind == .socialProfile(platform), "\(form)")
                }
                continue
            }
            if EpisodeLinks.appleEpisode(in: url) != nil {
                #expect(kind == .applePodcastEpisode, "\(form)"); continue
            }
            if EpisodeLinks.isApplePodcasts(url) {
                #expect(kind == .applePodcast, "\(form)"); continue
            }
            switch try SourceResolver().resolve(form) {
            case .youTubeVideo: #expect(kind == .youTubeVideo, "\(form)")
            case .youTubeChannel, .youTubeChannelPage: #expect(kind == .youTubeChannel, "\(form)")
            case .youTubePlaylist: #expect(kind == .youTubePlaylist, "\(form)")
            case .audioFile: #expect(kind == .audioFile, "\(form)")
            case .podcastFeed: #expect(kind == .podcastFeed, "\(form)")
            case .webPageNeedingDiscovery: #expect(kind == .webPage, "\(form)")
            case .localFile: Issue.record("Lokale Datei angenommen: \(form)")
            }
        }
    }
}
