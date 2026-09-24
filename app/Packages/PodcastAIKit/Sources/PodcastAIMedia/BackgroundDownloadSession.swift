//
//  BackgroundDownloadSession.swift
//  PodcastAIMedia
//
//  Lädt Ton über die Sitzung des Systems, damit ein Download im WLAN
//  weiterläuft, wenn die App in den Hintergrund geht oder das System sie
//  anhält.
//
//  Drei Dinge unterscheiden sie vom Laden im Vordergrund:
//
//  1. Wer wartet, kann gehen, ohne die Übertragung abzubrechen. Hält die
//     Warteschlange an, weil die Zeit im Hintergrund endet, lädt das
//     System weiter. Abgebrochen wird nur ausdrücklich (`cancel`, `suspend`).
//  2. Kommt eine Datei an, während niemand wartet, etwa nach einem Neustart
//     der App im Hintergrund, liegt sie danach geprüft am endgültigen Ort.
//     Das Transkript findet sie dort (`MediaDownloader.existing`).
//  3. Weiterleitungen folgt das System ohne Rückfrage. Geprüft wird deshalb
//     nach dem Download (`DownloadValidation`), bevor die Datei bleibt.
//

import Foundation
import Synchronization
import PodcastAICore

/// Wie eine Übertragung über die Sitzung im Hintergrund ausging.
public enum BackgroundTransferOutcome: Sendable, Equatable {
    /// Geprüft an der Stelle, die der Aufrufer genannt hat.
    case staged(byteCount: Int64, mimeType: String?)
    /// Kam an, während niemand wartete, und liegt schon am endgültigen Ort.
    case stored
}

public final class BackgroundDownloadSession: Sendable {

    public enum Mode: String, Sendable {
        /// Von Hand angefordert: das System lädt sofort.
        case manual
        /// Von selbst eingereiht: das System wählt den Moment.
        case automatic
    }

    public static let identifierPrefix = "com.godmodeai.podcastai.downloads"

    public static func identifier(for mode: Mode) -> String {
        "\(identifierPrefix).\(mode.rawValue)"
    }

    public let mode: Mode
    public let identifier: String
    private let session: URLSession
    private let delegate: Delegate

    /// Je Kennung genau einmal je Prozess anlegen. Eine zweite Sitzung mit
    /// derselben Kennung bekäme keine Ereignisse.
    ///
    /// `onEventsFinished` meldet, dass das System alle Ereignisse für diese
    /// Sitzung zugestellt hat; danach darf der Abschlussblock aus
    /// `handleEventsForBackgroundURLSession` laufen. `onArrival` meldet eine
    /// Datei, die ohne Wartenden am endgültigen Ort angekommen ist.
    public init(
        mode: Mode, mediaDirectory: URL, limit: Int64 = MediaDownloader.maximumBytes,
        onEventsFinished: @escaping @Sendable (String) -> Void = { _ in },
        onArrival: @escaping @Sendable (MediaVersionID) -> Void = { _ in }
    ) {
        self.mode = mode
        identifier = Self.identifier(for: mode)
        delegate = Delegate(
            mediaDirectory: mediaDirectory, limit: limit,
            onEventsFinished: onEventsFinished, onArrival: onArrival)
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = mode == .automatic
        // Nur im WLAN ohne Datenlimit. Mobilfunk bleibt dem Vordergrund und
        // der Zustimmung vorbehalten.
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        // Dieselben Regeln wie `SafeHTTP.makeSession`: keine Cookies, keine
        // gespeicherten Zugangsdaten.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Lädt `url` nach `staging`. Läuft für diese Fassung schon eine
    /// Übertragung, etwa aus einem früheren Start, wartet der Aufrufer auf
    /// sie, statt eine zweite zu beginnen. Liegt ein Stand zum Fortsetzen
    /// vor, setzt sie dort an.
    ///
    /// Wird die umgebende Aufgabe abgebrochen, endet nur das Warten: die
    /// Übertragung läuft weiter und legt ihre Datei am endgültigen Ort ab.
    public func download(
        _ url: URL, mediaVersionID: MediaVersionID, to staging: URL,
        progress: (@Sendable (_ received: Int64, _ expected: Int64?) -> Void)? = nil
    ) async throws -> BackgroundTransferOutcome {
        // Vor der ersten Anfrage dieselbe Prüfung wie im Vordergrund, samt https.
        let request = try SafeHTTP.request(for: url)
        let key = mediaVersionID.rawValue
        let running = await hasTask(for: key)
        let delegate = delegate
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let start = delegate.register(key: key, staging: staging, progress: progress,
                                              continuation: continuation)
                guard start, !running else { return }
                let task: URLSessionDownloadTask
                if let resume = delegate.takeResumeData(for: key) {
                    task = session.downloadTask(withResumeData: resume)
                } else {
                    task = session.downloadTask(with: request)
                }
                task.taskDescription = key
                task.resume()
            }
        } onCancel: {
            delegate.detach(key: key)
        }
    }

    /// Bricht die Übertragung einer Fassung ab und verwirft ihren Stand zum
    /// Fortsetzen. Für Löschen, „Laden abbrechen“ und „Alle abbrechen“.
    public func cancel(_ mediaVersionID: MediaVersionID) {
        let key = mediaVersionID.rawValue
        delegate.discardResumeData(for: key)
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == key { task.cancel() }
        }
    }

    /// Hält die Übertragung einer Fassung an und merkt sich den Stand, damit
    /// der nächste Versuch dort weitermacht. Für „Pausieren“.
    public func suspend(_ mediaVersionID: MediaVersionID) {
        let key = mediaVersionID.rawValue
        let delegate = delegate
        session.getAllTasks { tasks in
            for case let task as URLSessionDownloadTask in tasks where task.taskDescription == key {
                task.cancel(byProducingResumeData: { data in
                    if let data { delegate.storeResumeData(data, for: key) }
                })
            }
        }
    }

    /// Läuft für diese Fassung schon eine Übertragung?
    private func hasTask(for key: String) async -> Bool {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.contains {
                    $0.taskDescription == key && ($0.state == .running || $0.state == .suspended)
                })
            }
        }
    }
}

// MARK: - Delegat

extension BackgroundDownloadSession {

    /// Hält den Zustand hinter einem Schloss. Das System ruft auf eigenen
    /// Warteschlangen, die App aus Aufgaben.
    final class Delegate: NSObject, URLSessionDownloadDelegate, Sendable {

        /// So viel muss sich ändern, bevor der Fortschritt gemeldet wird.
        /// Das System meldet alle paar Kilobyte; jede Meldung zeichnet in
        /// der App eine Zeile neu.
        static let progressStep: Int64 = 1024 * 1024

        struct Waiter {
            let staging: URL
            let progress: (@Sendable (Int64, Int64?) -> Void)?
            let continuation: CheckedContinuation<BackgroundTransferOutcome, any Error>
            var lastReported: Int64 = -1
        }

        struct State {
            var waiters: [String: Waiter] = [:]
            /// Ergebnis aus `didFinishDownloadingTo`, bis `didCompleteWithError` es abholt.
            var outcomes: [String: Result<BackgroundTransferOutcome, any Error>] = [:]
            /// Angekommen, als niemand wartete. Wer danach fragt, bekommt `.stored`.
            var arrivedUnattended: Set<String> = []
        }

        let mediaDirectory: URL
        let resumeDirectory: URL
        let limit: Int64
        let onEventsFinished: @Sendable (String) -> Void
        let onArrival: @Sendable (MediaVersionID) -> Void
        let state = Mutex(State())

        init(mediaDirectory: URL, limit: Int64,
             onEventsFinished: @escaping @Sendable (String) -> Void,
             onArrival: @escaping @Sendable (MediaVersionID) -> Void) {
            self.mediaDirectory = mediaDirectory
            // Neben dem Audioordner, nicht darin: dort zählt jede Datei als Ton.
            resumeDirectory = mediaDirectory.deletingLastPathComponent()
                .appendingPathComponent("DownloadResumeData", isDirectory: true)
            self.limit = limit
            self.onEventsFinished = onEventsFinished
            self.onArrival = onArrival
        }

        // MARK: Warten

        /// Trägt einen Wartenden ein. `false`, wenn schon entschieden ist:
        /// die Datei liegt längst da, oder die Aufgabe ist abgebrochen.
        func register(
            key: String, staging: URL, progress: (@Sendable (Int64, Int64?) -> Void)?,
            continuation: CheckedContinuation<BackgroundTransferOutcome, any Error>
        ) -> Bool {
            let destination = mediaDirectory.appendingPathComponent(key)
            return state.withLock { state in
                // Nur wenn die Datei noch da ist. „Audio entfernen“ kann sie
                // inzwischen gelöscht haben.
                if state.arrivedUnattended.remove(key) != nil,
                   FileManager.default.fileExists(atPath: destination.path) {
                    continuation.resume(returning: .stored)
                    return false
                }
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return false
                }
                // Nur ein Wartender je Fassung. Ein älterer geht leer aus.
                state.waiters[key]?.continuation.resume(throwing: CancellationError())
                state.waiters[key] = Waiter(staging: staging, progress: progress, continuation: continuation)
                return true
            }
        }

        /// Der Wartende geht. Die Übertragung läuft weiter.
        func detach(key: String) {
            state.withLock { state in
                state.waiters.removeValue(forKey: key)?.continuation.resume(throwing: CancellationError())
            }
        }

        // MARK: Stand zum Fortsetzen

        private func resumeFile(for key: String) -> URL {
            resumeDirectory.appendingPathComponent(key)
        }

        func storeResumeData(_ data: Data, for key: String) {
            try? FileManager.default.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
            try? data.write(to: resumeFile(for: key), options: .atomic)
        }

        /// Liest den Stand und löscht ihn: ein zweites Mal gilt er nicht.
        func takeResumeData(for key: String) -> Data? {
            let file = resumeFile(for: key)
            defer { try? FileManager.default.removeItem(at: file) }
            return try? Data(contentsOf: file)
        }

        func discardResumeData(for key: String) {
            try? FileManager.default.removeItem(at: resumeFile(for: key))
        }

        // MARK: URLSessionDownloadDelegate

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            guard let key = downloadTask.taskDescription else { return }
            // Die Grenze greift schon während der Übertragung.
            if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
                state.withLock { $0.outcomes[key] = .failure(HTTPTransferError.tooLarge(limit: limit)) }
                downloadTask.cancel()
                return
            }
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            let report: (@Sendable (Int64, Int64?) -> Void)? = state.withLock { state in
                guard var waiter = state.waiters[key], let progress = waiter.progress else { return nil }
                let step = max(Self.progressStep, (expected ?? 0) / 100)
                guard totalBytesWritten - waiter.lastReported >= step else { return nil }
                waiter.lastReported = totalBytesWritten
                state.waiters[key] = waiter
                return progress
            }
            report?(totalBytesWritten, expected)
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
        ) {
            guard let key = downloadTask.taskDescription, !key.isEmpty else { return }
            let response = downloadTask.response as? HTTPURLResponse
            let byteCount = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let rejection = DownloadValidation.check(
                original: downloadTask.originalRequest?.url,
                final: response?.url ?? downloadTask.currentRequest?.url,
                statusCode: response?.statusCode, declaredType: response?.mimeType,
                sniffedType: PlayableAsset.sniffMIMEType(at: location),
                byteCount: byteCount, limit: limit)
            if let rejection {
                // Nichts bleibt liegen, was die Prüfung nicht bestanden hat.
                try? FileManager.default.removeItem(at: location)
                state.withLock { state in
                    state.outcomes[key] = .failure(DownloadValidation.transferError(for: rejection))
                }
                return
            }
            // Die Datei muss hier weg: nach der Rückkehr löscht das System sie.
            let arrived: Bool = state.withLock { state in
                let manager = FileManager.default
                if let waiter = state.waiters[key] {
                    do {
                        try? manager.removeItem(at: waiter.staging)
                        try manager.moveItem(at: location, to: waiter.staging)
                        state.outcomes[key] = .success(.staged(byteCount: byteCount, mimeType: response?.mimeType))
                    } catch {
                        state.outcomes[key] = .failure(error)
                    }
                    return false
                }
                // Niemand wartet: gleich an den Ort, an dem Wiedergabe und
                // Transkript die Fassung suchen. Atomar, wie im Vordergrund.
                let destination = mediaDirectory.appendingPathComponent(key)
                do {
                    try? manager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
                    try? manager.removeItem(at: destination)
                    try manager.moveItem(at: location, to: destination)
                    state.arrivedUnattended.insert(key)
                    return true
                } catch {
                    return false
                }
            }
            if arrived { onArrival(MediaVersionID(rawValue: key)) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            guard let key = task.taskDescription, !key.isEmpty else { return }
            // Ein unterbrochener Download bringt meist einen Stand zum
            // Fortsetzen mit. Der nächste Versuch setzt dort an.
            if let data = (error as? URLError)?.downloadTaskResumeData {
                storeResumeData(data, for: key)
            }
            state.withLock { state in
                let outcome = state.outcomes.removeValue(forKey: key)
                guard let waiter = state.waiters.removeValue(forKey: key) else { return }
                if let outcome {
                    waiter.continuation.resume(with: outcome)
                } else if state.arrivedUnattended.remove(key) != nil {
                    waiter.continuation.resume(returning: .stored)
                } else if let error {
                    let cancelled = (error as? URLError)?.code == .cancelled
                    waiter.continuation.resume(throwing: cancelled ? CancellationError() : error)
                } else {
                    waiter.continuation.resume(throwing: HTTPTransferError.emptyResponse)
                }
            }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            onEventsFinished(session.configuration.identifier ?? "")
        }
    }
}
