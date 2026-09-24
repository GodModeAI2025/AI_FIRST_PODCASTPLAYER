//
//  BackgroundDownloadWaiterTests.swift
//  PodcastAIKitTests
//
//  Wer auf eine Übertragung im Hintergrund wartet: mehrere je Fassung,
//  Gehen ohne Abbruch für die anderen, Abbrechen nur ohne Wartende.
//

import Testing
import Foundation
@testable import PodcastAIMedia

@Suite struct BackgroundDownloadWaiterTests {

    private func makeDelegate() -> BackgroundDownloadSession.Delegate {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("waiter-tests-\(UUID().uuidString)/Media", isDirectory: true)
        return BackgroundDownloadSession.Delegate(
            mediaDirectory: directory, limit: 1_000, onEventsFinished: { _ in }, onArrival: { _ in })
    }

    /// Startet einen Wartenden und gibt seine Aufgabe zurück.
    private func wait(on delegate: BackgroundDownloadSession.Delegate, key: String, token: UUID) -> Task<Bool, Never> {
        Task {
            do {
                try await withCheckedThrowingContinuation { continuation in
                    _ = delegate.register(key: key, token: token, progress: nil, continuation: continuation)
                }
                return true
            } catch {
                return false
            }
        }
    }

    private func settle(_ delegate: BackgroundDownloadSession.Delegate, key: String, count: Int) async {
        for _ in 0..<200 {
            if delegate.state.withLock({ $0.waiters[key]?.count ?? 0 }) == count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func secondWaiterDoesNotEndTheFirst() async {
        let delegate = makeDelegate()
        let first = UUID(), second = UUID()
        let a = wait(on: delegate, key: "k", token: first)
        let b = wait(on: delegate, key: "k", token: second)
        await settle(delegate, key: "k", count: 2)
        #expect(delegate.isAwaited("k"))

        // Der eine geht, der andere wartet weiter.
        delegate.detach(key: "k", token: first)
        #expect(await a.value == false)
        #expect(delegate.isAwaited("k"))

        // Abbrechen ohne Wartende greift nicht, solange noch jemand wartet.
        #expect(delegate.discard(key: "k", onlyIfUnawaited: true) == false)
        #expect(delegate.isAwaited("k"))

        // „Folge löschen“ beendet auch ihn.
        #expect(delegate.discard(key: "k", onlyIfUnawaited: false))
        #expect(await b.value == false)
        #expect(!delegate.isAwaited("k"))
    }

    @Test func unawaitedCancelDiscardsResumeData() {
        let delegate = makeDelegate()
        delegate.storeResumeData(Data([1, 2, 3]), for: "k")
        #expect(delegate.discard(key: "k", onlyIfUnawaited: true))
        #expect(delegate.takeResumeData(for: "k") == nil)
        #expect(delegate.state.withLock { $0.discarded.contains("k") })
    }
}
