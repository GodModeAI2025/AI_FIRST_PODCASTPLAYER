//
//  PlayerSession.swift
//  PodcastAIPlayerKit
//
//  Verdrahtet Bibliothek, Wiedergabe und Downloads zu dem einen Objekt, das
//  eine Player-App hält. Uhr und Fernseher nutzen es gleich.
//

#if canImport(SwiftData) && canImport(AVFoundation)
import Foundation
import Observation
import PodcastAICore

@MainActor
@Observable
public final class PlayerSession {

    public private(set) var library: PlayerLibrary
    public let engine: PlaybackEngine
    /// `nil` auf Geräten ohne Downloads (Apple TV streamt nur).
    public let downloads: PlayerDownloads?

    @ObservationIgnored private var started = false

    public init(
        platform: String, storeDirectory: URL = PlayerSession.defaultStoreDirectory,
        mediaDirectory: URL?, defaults: UserDefaults = .standard
    ) {
        let deviceID = PlayerLibrary.deviceIdentifier(prefix: platform, defaults: defaults)
        var opened = PlayerLibrary.open(storeDirectory: storeDirectory, deviceID: deviceID)
        #if DEBUG
        // Mit `-player-demo` ein leerer Speicher im Arbeitsspeicher, damit
        // Beispielinhalt nie in die Datenbank oder nach iCloud gelangt.
        if ProcessInfo.processInfo.arguments.contains("-player-demo"),
           let container = try? PlayerLibrary.makeContainer(storeURL: nil, sync: false) {
            opened = PlayerLibrary(container: container, storage: .temporary, deviceID: deviceID)
        }
        #endif
        let library = opened
        let engine = PlaybackEngine(defaults: defaults)
        let downloads = mediaDirectory.map { PlayerDownloads(directory: $0) }
        // Eine Uhr hat wenig Speicher und Akku: kleinere Feed-Dateien.
        #if os(watchOS)
        library.feedByteLimit = 8 * 1024 * 1024
        #endif
        self.library = library
        self.engine = engine
        self.downloads = downloads

        engine.localFileURL = { downloads?.localURL(for: $0) }
        wire(library)
    }

    private func wire(_ library: PlayerLibrary) {
        engine.resumeProvider = { [library] in library.resume(for: $0) }
        engine.onListened = { [library] item, range in library.recordPlayed(item, range: range) }
    }

    /// Beispielmodus für Prüfung und Vorführung: eine Bibliothek nur im
    /// Arbeitsspeicher mit dem öffentlichen Podcast „Think Different. Think AI.“
    /// der Entwickler. Sie berührt weder die Datenbank noch iCloud und
    /// verschwindet mit dem Beenden der App. Startet keinen Ton (Regel 1).
    public func startExampleMode() async {
        guard !isExampleMode,
              let container = try? PlayerLibrary.makeContainer(storeURL: nil, sync: false) else { return }
        let example = PlayerLibrary(container: container, storage: .temporary, deviceID: library.deviceID)
        example.addExampleShow()
        library = example
        wire(example)
        isExampleMode = true
        await example.refreshAll(minimumInterval: 0)
    }

    public private(set) var isExampleMode = false

    /// Wohin die Datenbank des Players kommt. Apple TV darf nur in Caches
    /// schreiben; das System kann den Ordner leeren, iCloud ist dort die
    /// Wahrheit und füllt ihn wieder.
    public static var defaultStoreDirectory: URL {
        #if os(tvOS)
        URL.cachesDirectory.appending(path: "PodcastAIPlayer", directoryHint: .isDirectory)
        #else
        URL.applicationSupportDirectory.appending(path: "PodcastAIPlayer", directoryHint: .isDirectory)
        #endif
    }

    /// Lädt die Bibliothek, holt die Gemerkten für „Als Nächstes“ und liest
    /// die Feeds. Startet keinen Ton (Regel 1): es werden nur Listen gefüllt.
    public func start(refreshFeeds: Bool = true) async {
        guard !started else { return }
        started = true
        library.reload()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-player-demo") { library.loadDemoContent() }
        if ProcessInfo.processInfo.arguments.contains("-player-example") { await startExampleMode() }
        #endif
        library.observeRemoteChanges()
        engine.restoreUpNext(library.items(forIdentifiers: UpNextQueue.storedIdentifiers()))
        if refreshFeeds { await library.refreshAll() }
    }

    /// Spielt eine Folge. Nur als Folge einer Handlung der Person aufrufen.
    public func play(_ item: PlayerItem) {
        engine.play(item)
    }

    /// Eine Folge samt dem aktuellen Stand der Fortsetzungsstelle.
    public func fresh(_ item: PlayerItem) -> PlayerItem {
        library.item(for: item.episode, show: library.shows.first { $0.id == item.episode.sourceID })
    }
}
#endif
