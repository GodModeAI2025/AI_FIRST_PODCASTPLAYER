//
//  BackgroundDownloadSession.swift
//  PodcastAIMedia
//
//  Lädt Ton über die Sitzung des Systems, damit ein Download im WLAN
//  weiterläuft, wenn die App in den Hintergrund geht oder das System sie
//  anhält.
//
//  Vier Dinge unterscheiden sie vom Laden im Vordergrund:
//
//  1. Wer wartet, kann gehen, ohne die Übertragung abzubrechen. Hält die
//     Warteschlange an, weil die Zeit im Hintergrund endet, lädt das
//     System weiter. Abgebrochen wird nur ausdrücklich (`cancel`,
//     `cancelUnlessAwaited`, `suspend`).
//  2. Je Fassung gibt es eine Übertragung, auf die beliebig viele warten
//     dürfen, etwa das Transkript und „Laden (offline)“ derselben Folge.
//     Die beiden Sitzungen (sofort und nach Wahl des Systems) teilen sich
//     einen Delegaten; läuft die Fassung schon in der anderen, wartet man
//     dort mit, statt ein zweites Mal zu laden.
//  3. Jede fertige Datei liegt danach geprüft am endgültigen Ort, ob jemand
//     wartet oder nicht, etwa nach einem Neustart der App im Hintergrund.
//     Das Transkript findet sie dort (`MediaDownloader.existing`).
//  4. Weiterleitungen folgt das System ohne Rückfrage. Geprüft wird deshalb
//     nach dem Download (`DownloadValidation`), bevor die Datei bleibt.
//
//  Ergebnisse einer Übertragung erreichen die Wartenden nur, wenn es die
//  aktuelle ihrer Fassung ist. Eine angehaltene, die sich erst meldet, wenn
//  schon die nächste läuft, weckt niemanden.
//

import Foundation
import Synchronization
import PodcastAICore

public final class BackgroundDownloadSession: Sendable {

    public enum Mode: String, Sendable {
        /// Von Hand angefordert oder vorn gebraucht: das System lädt sofort.
        case manual
        /// Im Hintergrund von selbst begonnen: das System wählt den Moment.
        case automatic
    }

    public static let identifierPrefix = "com.godmodeai.podcastai.downloads"

    public static func identifier(for mode: Mode) -> String {
        "\(identifierPrefix).\(mode.rawValue)"
    }

    public let mode: Mode
    public let identifier: String
    private let session: URLSession
    /// Die andere Sitzung des Paars. Läuft eine Fassung dort, wartet man mit.
    private let sibling: URLSession
    private let delegate: Delegate

    /// Legt beide Sitzungen an, mit einem gemeinsamen Delegaten. Je Prozess
    /// genau einmal: eine zweite Sitzung mit derselben Kennung bekäme keine
    /// Ereignisse.
    ///
    /// `onEventsFinished` meldet, dass das System alle Ereignisse einer
    /// Sitzung zugestellt hat; danach darf der Abschlussblock aus
    /// `handleEventsForBackgroundURLSession` laufen. `onArrival` meldet eine
    /// Datei, die ohne Wartenden am endgültigen Ort angekommen ist.
    public static func makePair(
        mediaDirectory: URL, limit: Int64 = MediaDownloader.maximumBytes,
        onEventsFinished: @escaping @Sendable (String) -> Void = { _ in },
        onArrival: @escaping @Sendable (MediaVersionID) -> Void = { _ in }
    ) -> (manual: BackgroundDownloadSession, automatic: BackgroundDownloadSession) {
        let delegate = Delegate(
            mediaDirectory: mediaDirectory, limit: limit,
            onEventsFinished: onEventsFinished, onArrival: onArrival)
        let manual = makeURLSession(.manual, delegate: delegate)
        let automatic = makeURLSession(.automatic, delegate: delegate)
        return (
            BackgroundDownloadSession(mode: .manual, session: manual, sibling: automatic, delegate: delegate),
            BackgroundDownloadSession(mode: .automatic, session: automatic, sibling: manual, delegate: delegate)
        )
    }

    private init(mode: Mode, session: URLSession, sibling: URLSession, delegate: Delegate) {
        self.mode = mode
        identifier = Self.identifier(for: mode)
        self.session = session
        self.sibling = sibling
        self.delegate = delegate
    }

    private static func makeURLSession(_ mode: Mode, delegate: Delegate) -> URLSession {
        URLSession(configuration: configuration(for: mode), delegate: delegate, delegateQueue: nil)
    }

    /// Die Einstellungen einer Sitzung. Eigene Funktion, damit Tests sie prüfen.
    static func configuration(for mode: Mode) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier(for: mode))
        configuration.sessionSendsLaunchEvents = true
        // Bis 0.11 war die Sitzung für Automatisches zurückhaltend
        // (`isDiscretionary`): Das System durfte ihre Übertragungen verschieben,
        // bis das Gerät am Strom hängt, also oft bis in die Nacht. Der Ton wird
        // aber für das nächste Transkript gebraucht. Was im Hintergrund beginnt,
        // behandelt das System ohnehin nach eigenem Ermessen; alles, was die
        // App vorn beginnt, lädt jetzt sofort.
        configuration.isDiscretionary = false
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
        return configuration
    }

    /// Lädt `url` an den endgültigen Ort der Fassung im Audioordner. Läuft
    /// für diese Fassung schon eine Übertragung, in dieser oder der anderen
    /// Sitzung, etwa aus einem früheren Start, wartet der Aufrufer auf sie,
    /// statt eine zweite zu beginnen. Liegt ein Stand zum Fortsetzen vor,
    /// setzt sie dort an.
    ///
    /// Wird die umgebende Aufgabe abgebrochen, endet nur das Warten: die
    /// Übertragung läuft weiter und legt ihre Datei am endgültigen Ort ab.
    public func download(
        _ url: URL, mediaVersionID: MediaVersionID,
        progress: (@Sendable (_ received: Int64, _ expected: Int64?) -> Void)? = nil
    ) async throws {
        // Vor der ersten Anfrage dieselbe Prüfung wie im Vordergrund, samt https.
        let request = try SafeHTTP.request(for: url)
        let key = mediaVersionID.rawValue
        let token = UUID()
        let delegate = delegate, own = session, other = sibling
        let promotes = mode == .manual
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard delegate.register(key: key, token: token, progress: progress,
                                        continuation: continuation) else { return }
                own.getAllTasks { ownTasks in
                    other.getAllTasks { otherTasks in
                        delegate.startOrJoin(
                            key: key, request: request, own: own, ownTasks: ownTasks,
                            other: other, otherTasks: otherTasks, promotes: promotes)
                    }
                }
            }
        } onCancel: {
            delegate.detach(key: key, token: token)
        }
    }

    /// Beginnt eine Übertragung, auf die niemand wartet, etwa für die
    /// nächsten Folgen der Warteschlange, solange die App vorn ist. Sie läuft
    /// weiter, wenn die App in den Hintergrund geht, und legt ihre Datei
    /// geprüft am endgültigen Ort ab. Läuft für die Fassung schon eine,
    /// in dieser oder der anderen Sitzung, oder liegt die Datei schon da,
    /// geschieht nichts. Wer später wartet, schließt sich ihr an.
    public func prefetch(_ url: URL, mediaVersionID: MediaVersionID) throws {
        let request = try SafeHTTP.request(for: url)
        let key = mediaVersionID.rawValue
        let delegate = delegate, own = session, other = sibling
        own.getAllTasks { ownTasks in
            other.getAllTasks { otherTasks in
                delegate.startUnattended(key: key, request: request, in: own, running: ownTasks + otherTasks)
            }
        }
    }

    /// Bricht die Übertragung einer Fassung ab, in beiden Sitzungen, und
    /// verwirft ihren Stand zum Fortsetzen. Wer wartet, bekommt einen
    /// Abbruch. Für „Folge löschen“: nichts von ihr bleibt.
    public func cancel(_ mediaVersionID: MediaVersionID) {
        let key = mediaVersionID.rawValue
        delegate.discard(key: key, onlyIfUnawaited: false)
        cancelTasks(key)
    }

    /// Wie `cancel`, aber nur, solange niemand mehr wartet. Für „Laden
    /// abbrechen“ und „Alle abbrechen“: lädt das Transkript oder „Laden
    /// (offline)“ dieselbe Datei noch, läuft sie für den anderen weiter.
    public func cancelUnlessAwaited(_ mediaVersionID: MediaVersionID) {
        let key = mediaVersionID.rawValue
        guard delegate.discard(key: key, onlyIfUnawaited: true) else { return }
        cancelTasks(key)
    }

    /// Hält die Übertragung einer Fassung an und merkt sich den Stand, damit
    /// der nächste Versuch dort weitermacht. Für „Pausieren“. Wartet noch
    /// jemand, etwa „Laden (offline)“, läuft sie weiter.
    public func suspend(_ mediaVersionID: MediaVersionID) {
        let key = mediaVersionID.rawValue
        guard !delegate.isAwaited(key) else { return }
        let delegate = delegate
        for session in [session, sibling] {
            session.getAllTasks { tasks in
                for case let task as URLSessionDownloadTask in tasks
                where task.taskDescription == key && Delegate.isActive(task) {
                    delegate.suspend(task, in: session, key: key)
                }
            }
        }
    }

    private func cancelTasks(_ key: String) {
        for session in [session, sibling] {
            session.getAllTasks { tasks in
                for task in tasks where task.taskDescription == key { task.cancel() }
            }
        }
    }
}

// MARK: - Delegat

extension BackgroundDownloadSession {

    /// Eine Übertragung, eindeutig über beide Sitzungen.
    struct TaskRef: Hashable, Sendable {
        let session: String
        let task: Int

        init(_ session: URLSession, _ task: URLSessionTask) {
            self.session = session.configuration.identifier ?? ""
            self.task = task.taskIdentifier
        }
    }

    /// Hält den Zustand hinter einem Schloss. Das System ruft auf eigenen
    /// Warteschlangen, die App aus Aufgaben.
    final class Delegate: NSObject, URLSessionDownloadDelegate, Sendable {

        /// So viel muss sich ändern, bevor der Fortschritt gemeldet wird.
        /// Das System meldet alle paar Kilobyte; jede Meldung zeichnet in
        /// der App eine Zeile neu.
        static let progressStep: Int64 = 1024 * 1024

        struct Waiter {
            let progress: (@Sendable (Int64, Int64?) -> Void)?
            let continuation: CheckedContinuation<Void, any Error>
            var lastReported: Int64 = -1
        }

        /// Eine Übertragung, die beginnt, sobald eine andere angehalten ist.
        struct Pending {
            let session: URLSession
            let request: URLRequest
        }

        struct State {
            /// Je Fassung alle, die auf sie warten.
            var waiters: [String: [UUID: Waiter]] = [:]
            /// Die Übertragung, deren Ergebnis die Wartenden bekommen. Fehlt
            /// sie, etwa nach einem Neustart, gilt die, die sich meldet.
            var current: [String: TaskRef] = [:]
            /// Ergebnis aus `didFinishDownloadingTo`, bis `didCompleteWithError` es abholt.
            var outcomes: [TaskRef: Result<Void, any Error>] = [:]
            /// Angekommen, als niemand wartete. Wer danach fragt, ist gleich fertig.
            var arrivedUnattended: Set<String> = []
            /// Abgebrochen und verworfen. Kommt die Datei trotzdem an, wird sie gelöscht.
            var discarded: Set<String> = []
            /// Angehalten mit Stand zum Fortsetzen. Ihr Ende weckt niemanden.
            var suspending: Set<TaskRef> = []
            /// Je Fassung die Angehaltenen, deren Stand zum Fortsetzen noch
            /// nicht da ist. Solange beginnt keine neue Übertragung.
            var awaitingResume: [String: Set<TaskRef>] = [:]
            /// Wartet darauf, dass eine angehaltene Übertragung ihren Stand liefert.
            var pending: [String: Pending] = [:]
            /// Die geprüfte Anfrage je Fassung (`SafeHTTP.request`). Damit
            /// beginnt eine neue Übertragung, wenn eine angehaltene Wartende
            /// hatte, nie mit einer Adresse aus einer Weiterleitung.
            var requests: [String: URLRequest] = [:]
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

        static func isActive(_ task: URLSessionTask) -> Bool {
            task.state == .running || task.state == .suspended
        }

        private func destination(for key: String) -> URL {
            mediaDirectory.appendingPathComponent(key)
        }

        // MARK: Warten

        /// Trägt einen Wartenden ein. `false`, wenn schon entschieden ist:
        /// die Datei liegt längst da, oder die Aufgabe ist abgebrochen.
        func register(
            key: String, token: UUID, progress: (@Sendable (Int64, Int64?) -> Void)?,
            continuation: CheckedContinuation<Void, any Error>
        ) -> Bool {
            let destination = destination(for: key)
            return state.withLock { state in
                // Wer neu fragt, will die Datei wieder.
                state.discarded.remove(key)
                // Nur wenn die Datei noch da ist. „Audio entfernen“ kann sie
                // inzwischen gelöscht haben.
                if state.arrivedUnattended.remove(key) != nil,
                   FileManager.default.fileExists(atPath: destination.path) {
                    continuation.resume()
                    return false
                }
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return false
                }
                state.waiters[key, default: [:]][token] = Waiter(progress: progress, continuation: continuation)
                return true
            }
        }

        /// Ein Wartender geht. Die Übertragung läuft weiter.
        func detach(key: String, token: UUID) {
            state.withLock { state in
                guard let waiter = state.waiters[key]?.removeValue(forKey: token) else { return }
                if state.waiters[key]?.isEmpty == true { state.waiters[key] = nil }
                waiter.continuation.resume(throwing: CancellationError())
            }
        }

        func isAwaited(_ key: String) -> Bool {
            state.withLock { !($0.waiters[key]?.isEmpty ?? true) }
        }

        /// Weckt alle Wartenden einer Fassung. Nur unter dem Schloss.
        private static func resolveAll(_ key: String, in state: inout State, with result: Result<Void, any Error>) {
            guard let waiters = state.waiters.removeValue(forKey: key) else { return }
            for waiter in waiters.values { waiter.continuation.resume(with: result) }
        }

        // MARK: Beginnen

        /// Entscheidet nach dem Blick auf beide Sitzungen: mitwarten, eine
        /// zurückhaltende Übertragung nach vorn holen oder neu beginnen.
        func startOrJoin(
            key: String, request: URLRequest,
            own: URLSession, ownTasks: [URLSessionTask],
            other: URLSession, otherTasks: [URLSessionTask], promotes: Bool
        ) {
            guard state.withLock({ state in
                state.requests[key] = request
                return !(state.waiters[key]?.isEmpty ?? true)
            }) else { return }
            if let running = ownTasks.first(where: { $0.taskDescription == key && Self.isActive($0) }) {
                adopt(TaskRef(own, running), for: key)
                if running.state == .suspended { running.resume() }
                return
            }
            if let running = otherTasks.first(where: { $0.taskDescription == key && Self.isActive($0) }) {
                // Die zurückhaltende Sitzung könnte Stunden warten. Wer vorn
                // wartet, holt die Übertragung samt Stand in die sofortige.
                guard promotes, let download = running as? URLSessionDownloadTask else {
                    adopt(TaskRef(other, running), for: key)
                    if running.state == .suspended { running.resume() }
                    return
                }
                state.withLock { $0.pending[key] = Pending(session: own, request: request) }
                suspend(download, in: other, key: key)
                return
            }
            // Gerade angehalten und der Stand noch unterwegs, etwa nach
            // „Pausieren“ und schnellem „Fortsetzen“: erst mit ihm beginnen.
            // Gilt auch, wenn die angehaltene Übertragung schon nicht mehr
            // in der Liste des Systems steht.
            let waitsForResume: Bool = state.withLock { state in
                guard !(state.awaitingResume[key]?.isEmpty ?? true) else { return false }
                state.pending[key] = Pending(session: own, request: request)
                return true
            }
            if waitsForResume { return }
            start(key: key, request: request, in: own)
        }

        /// Beginnt ohne Wartenden, siehe ``BackgroundDownloadSession/prefetch(_:mediaVersionID:)``.
        func startUnattended(key: String, request: URLRequest, in session: URLSession, running: [URLSessionTask]) {
            guard !running.contains(where: { $0.taskDescription == key && Self.isActive($0) }),
                  !FileManager.default.fileExists(atPath: destination(for: key).path) else { return }
            let blocked: Bool = state.withLock { state in
                // Angehalten und der Stand noch unterwegs: nicht dazwischenfunken.
                guard (state.awaitingResume[key]?.isEmpty ?? true), state.pending[key] == nil else { return true }
                state.discarded.remove(key)
                state.requests[key] = request
                return false
            }
            if !blocked { start(key: key, request: request, in: session) }
        }

        private func adopt(_ ref: TaskRef, for key: String) {
            state.withLock { $0.current[key] = ref }
        }

        /// Beginnt eine Übertragung, außer für die Fassung läuft schon eine.
        /// Fragen zwei gleichzeitig, etwa das Transkript und die neueste
        /// Folge, sehen beide beim System noch nichts; der zweite wartet
        /// dann auf die Übertragung des ersten.
        private func start(key: String, request: URLRequest, in session: URLSession) {
            let task: URLSessionDownloadTask? = state.withLock { state in
                guard state.current[key] == nil else { return nil }
                let task: URLSessionDownloadTask
                if let resume = takeResumeData(for: key) {
                    task = session.downloadTask(withResumeData: resume)
                } else {
                    task = session.downloadTask(with: request)
                }
                task.taskDescription = key
                state.current[key] = TaskRef(session, task)
                return task
            }
            task?.resume()
        }

        /// Hält eine Übertragung an und merkt sich ihren Stand. Wartet eine
        /// neue auf ihn, beginnt sie danach.
        func suspend(_ task: URLSessionDownloadTask, in session: URLSession, key: String) {
            let ref = TaskRef(session, task)
            state.withLock { state in
                state.suspending.insert(ref)
                state.awaitingResume[key, default: []].insert(ref)
            }
            task.cancel(byProducingResumeData: { [self] data in
                if let data { storeResumeData(data, for: key) }
                // Erst jetzt liegt der Stand bereit. Wer danach beginnt, nimmt ihn.
                state.withLock { state in
                    state.awaitingResume[key]?.remove(ref)
                    if state.awaitingResume[key]?.isEmpty == true { state.awaitingResume[key] = nil }
                    Self.takeOverWaiters(of: ref, key: key, session: session, in: &state)
                }
                firePending(key)
            })
        }

        /// Hatte sich jemand der angehaltenen Übertragung angeschlossen, etwa
        /// nach „Pausieren“ und sofortigem „Fortsetzen“, bekäme er nie ein
        /// Ergebnis. Dann beginnt eine neue mit dem Stand. Nur unter dem Schloss.
        private static func takeOverWaiters(
            of ref: TaskRef, key: String, session: URLSession, in state: inout State
        ) {
            guard state.current[key] == ref else { return }
            state.current[key] = nil
            guard state.pending[key] == nil, !(state.waiters[key]?.isEmpty ?? true),
                  let request = state.requests[key] else { return }
            state.pending[key] = Pending(session: session, request: request)
        }

        /// Beginnt die Übertragung, die auf eine angehaltene wartete. Ist
        /// die Datei inzwischen doch fertig geworden, sind alle gleich fertig.
        /// Solange noch ein Stand zum Fortsetzen unterwegs ist, wartet sie.
        private func firePending(_ key: String) {
            let destination = destination(for: key)
            let next: Pending? = state.withLock { state in
                guard state.awaitingResume[key]?.isEmpty ?? true,
                      let pending = state.pending.removeValue(forKey: key),
                      !(state.waiters[key]?.isEmpty ?? true) else { return nil }
                if FileManager.default.fileExists(atPath: destination.path) {
                    state.arrivedUnattended.remove(key)
                    Self.resolveAll(key, in: &state, with: .success(()))
                    return nil
                }
                return pending
            }
            if let next { start(key: key, request: next.request, in: next.session) }
        }

        // MARK: Abbrechen

        /// Verwirft den Stand einer Fassung. Mit `onlyIfUnawaited` nur, wenn
        /// niemand mehr wartet; sonst bekommen alle Wartenden einen Abbruch.
        /// `true`, wenn verworfen wurde.
        @discardableResult
        func discard(key: String, onlyIfUnawaited: Bool) -> Bool {
            let dropped = state.withLock { state in
                if onlyIfUnawaited, !(state.waiters[key]?.isEmpty ?? true) { return false }
                state.discarded.insert(key)
                state.pending[key] = nil
                state.arrivedUnattended.remove(key)
                Self.resolveAll(key, in: &state, with: .failure(CancellationError()))
                return true
            }
            if dropped { discardResumeData(for: key) }
            return dropped
        }

        // MARK: Stand zum Fortsetzen

        private func resumeFile(for key: String) -> URL {
            resumeDirectory.appendingPathComponent(key)
        }

        /// Unter dem Schloss, damit „Folge löschen“ nicht zwischen Prüfen und
        /// Schreiben fällt und ein Stand ohne Folge liegen bleibt.
        func storeResumeData(_ data: Data, for key: String) {
            let file = resumeFile(for: key)
            state.withLock { state in
                guard !state.discarded.contains(key) else { return }
                try? FileManager.default.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
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
            let ref = TaskRef(session, downloadTask)
            // Die Grenze greift schon während der Übertragung.
            if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
                state.withLock { $0.outcomes[ref] = .failure(HTTPTransferError.tooLarge(limit: limit)) }
                downloadTask.cancel()
                return
            }
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            let reports: [@Sendable (Int64, Int64?) -> Void] = state.withLock { state in
                guard state.current[key] == nil || state.current[key] == ref,
                      var waiters = state.waiters[key] else { return [] }
                let step = max(Self.progressStep, (expected ?? 0) / 100)
                var due: [@Sendable (Int64, Int64?) -> Void] = []
                for (token, waiter) in waiters {
                    guard let progress = waiter.progress,
                          totalBytesWritten - waiter.lastReported >= step else { continue }
                    waiters[token]?.lastReported = totalBytesWritten
                    due.append(progress)
                }
                state.waiters[key] = waiters
                return due
            }
            for report in reports { report(totalBytesWritten, expected) }
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
        ) {
            guard let key = downloadTask.taskDescription, !key.isEmpty else { return }
            let ref = TaskRef(session, downloadTask)
            // Nach „Folge löschen“ oder „Laden abbrechen“ fertig geworden:
            // die Datei gehört zu nichts mehr.
            if state.withLock({ $0.discarded.contains(key) }) {
                try? FileManager.default.removeItem(at: location)
                state.withLock { $0.outcomes[ref] = .failure(CancellationError()) }
                return
            }
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
                    state.outcomes[ref] = .failure(DownloadValidation.transferError(for: rejection))
                }
                return
            }
            // Die Datei muss hier weg: nach der Rückkehr löscht das System sie.
            // Immer an den Ort, an dem Wiedergabe und Transkript die Fassung
            // suchen, ob jemand wartet oder nicht. Verschoben wird erst nach
            // der Prüfung, also liegt dort nur Vollständiges.
            let manager = FileManager.default
            let destination = destination(for: key)
            do {
                try? manager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
                try? manager.removeItem(at: destination)
                try manager.moveItem(at: location, to: destination)
            } catch {
                state.withLock { $0.outcomes[ref] = .failure(error) }
                return
            }
            discardResumeData(for: key)
            let unattended: Bool = state.withLock { state in
                let isCurrent = state.current[key] == nil || state.current[key] == ref
                if isCurrent, !(state.waiters[key]?.isEmpty ?? true), !state.suspending.contains(ref) {
                    state.outcomes[ref] = .success(())
                    return false
                }
                state.arrivedUnattended.insert(key)
                return true
            }
            if unattended { onArrival(MediaVersionID(rawValue: key)) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            guard let key = task.taskDescription, !key.isEmpty else { return }
            let ref = TaskRef(session, task)
            let urlError = error as? URLError
            let (outcome, suspended, isCurrent, discarded) = state.withLock { state in
                let outcome = state.outcomes.removeValue(forKey: ref)
                let suspended = state.suspending.remove(ref) != nil
                let isCurrent = state.current[key] == nil || state.current[key] == ref
                if suspended {
                    Self.takeOverWaiters(of: ref, key: key, session: session, in: &state)
                } else if isCurrent {
                    state.current[key] = nil
                    if state.pending[key] == nil { state.requests[key] = nil }
                }
                return (outcome, suspended, isCurrent, state.discarded.contains(key))
            }
            // Stand zum Fortsetzen: nach einer Ablehnung, etwa über der
            // Größengrenze, oder nach einem Abbruch gilt er nicht. Angehalten
            // liefert ihn `cancel(byProducingResumeData:)`. Behalten wird er
            // nach einer Unterbrechung und wenn das System die Übertragung
            // beendet, etwa weil die App aus dem Umschalter geschoben wurde.
            if case .failure? = outcome {
                discardResumeData(for: key)
            } else if !suspended, !discarded, let data = urlError?.downloadTaskResumeData,
                      urlError?.code != .cancelled || urlError?.backgroundTaskCancelledReason != nil {
                storeResumeData(data, for: key)
            }
            // Eine angehaltene oder abgelöste Übertragung weckt niemanden.
            // Wer auf eine angehaltene wartet, beginnt, sobald ihr Stand da
            // ist; `firePending` wartet selbst darauf.
            guard !suspended, isCurrent else {
                firePending(key)
                return
            }
            state.withLock { state in
                if let outcome {
                    Self.resolveAll(key, in: &state, with: outcome)
                } else if state.arrivedUnattended.contains(key) {
                    if state.waiters[key] != nil { state.arrivedUnattended.remove(key) }
                    Self.resolveAll(key, in: &state, with: .success(()))
                } else if let error {
                    let cancelled = urlError?.code == .cancelled
                    Self.resolveAll(key, in: &state, with: .failure(cancelled ? CancellationError() : error))
                } else {
                    Self.resolveAll(key, in: &state, with: .failure(HTTPTransferError.emptyResponse))
                }
            }
            firePending(key)
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            onEventsFinished(session.configuration.identifier ?? "")
        }
    }
}
