//
//  PlayerDownloads.swift
//  PodcastAIPlayerKit
//
//  Folgen zum Hören ohne Netz, vor allem für die Uhr. Der Download läuft im
//  Vordergrund über `MediaDownloader` (Adressprüfung, Größengrenze, atomares
//  Ablegen) und nur, solange die App offen ist. Eine Sitzung im Hintergrund
//  braucht auf der Uhr eigene Hintergrundaufgaben; die gibt es hier nicht.
//
//  Geladen wird nur auf Wunsch: ein Tipp auf „Laden“. Es gibt kein
//  automatisches Vorladen.
//

import Foundation
import Observation
import PodcastAICore
import PodcastAIMedia

@MainActor
@Observable
public final class PlayerDownloads {

    public enum Status: Equatable, Sendable {
        case notDownloaded
        /// Anteil von 0 bis 1, `nil` wenn die Größe unbekannt ist.
        case downloading(Double?)
        case downloaded
        case failed
    }

    public let directory: URL
    public private(set) var active: [EpisodeID: Status] = [:]

    @ObservationIgnored private let downloader: MediaDownloader
    @ObservationIgnored private var tasks: [EpisodeID: Task<Void, Never>] = [:]

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = directory
        try? excluded.setResourceValues(values)
        self.downloader = MediaDownloader(directory: directory)
    }

    private func fileURL(for item: PlayerItem) -> URL? {
        item.episode.streamMediaVersionID.map { directory.appending(path: $0.rawValue) }
    }

    /// Die geladene Datei, falls es sie gibt.
    public func localURL(for item: PlayerItem) -> URL? {
        guard let url = fileURL(for: item),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return nil }
        return url
    }

    public func status(for item: PlayerItem) -> Status {
        if let state = active[item.id] { return state }
        return localURL(for: item) != nil ? .downloaded : .notDownloaded
    }

    /// Lädt die Folge. Nur auf ausdrücklichen Wunsch aufrufen.
    public func download(_ item: PlayerItem) {
        guard let media = item.episode.streamMediaVersionID, let url = item.streamURL,
              tasks[item.id] == nil, localURL(for: item) == nil else { return }
        let id = item.id
        active[id] = .downloading(nil)
        let report: @Sendable (Int64, Int64?) -> Void = { [weak self] received, expected in
            let fraction = expected.flatMap { $0 > 0 ? Double(received) / Double($0) : nil }
            Task { @MainActor [weak self] in self?.active[id] = .downloading(fraction) }
        }
        tasks[id] = Task { [weak self, downloader] in
            do {
                _ = try await downloader.download(from: url, mediaVersionID: media, progress: report)
                self?.finish(id, status: nil)
            } catch is CancellationError {
                self?.finish(id, status: nil)
            } catch {
                self?.finish(id, status: .failed)
            }
        }
    }

    public func cancel(_ item: PlayerItem) {
        tasks[item.id]?.cancel()
    }

    private func finish(_ id: EpisodeID, status: Status?) {
        tasks[id] = nil
        active[id] = status
    }

    /// Löscht die geladene Datei. Die Folge bleibt in der Bibliothek.
    public func remove(_ item: PlayerItem) {
        tasks[item.id]?.cancel()
        if let url = fileURL(for: item) { try? FileManager.default.removeItem(at: url) }
        active[item.id] = nil
    }

    /// Speicher der geladenen Folgen in Byte.
    public var usedBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
