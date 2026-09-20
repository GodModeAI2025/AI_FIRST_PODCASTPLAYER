//
//  AppModel.swift
//  PodcastAI
//
//  Der gemeinsame Zustand beider Apps. Ein Composition Root, kein
//  Singleton-Netz: die Dienste werden hier einmal gebaut und nach unten
//  gereicht.
//

import Foundation
import Observation
import SwiftUI
import PodcastAIKit

@MainActor
@Observable
public final class AppModel {

    // MARK: - Zustand für die Oberfläche

    public private(set) var sources: [Source] = []
    public private(set) var relevantToday: [RelevantItem] = []
    public private(set) var smartFeeds: [SmartPodcastFeed] = []
    public private(set) var editions: [SmartFeedID: [PersonalEpisode]] = [:]
    public private(set) var profile = InterestProfile()
    public private(set) var ledger = ListeningLedger()
    public private(set) var modelStatus = ModelStatus(
        onDevice: .unavailable(.modelNotReady),
        privateCloudCompute: .unavailable(.userConsentMissing)
    )

    /// Was gerade passiert. Eine Zeile, die der Nutzer lesen kann — keine
    /// unendliche Fortschrittsanzeige ohne Aussage.
    public private(set) var activity: String?
    public private(set) var lastError: String?

    // MARK: - Dienste

    public let store: LibraryStore
    public let policy: PlaybackPolicy
    public let player: PlaybackCoordinator

    private let refresher: FeedRefresher
    private let deviceID: String

    public init(store: LibraryStore, deviceID: String = AppModel.currentDeviceID()) {
        self.store = store
        self.deviceID = deviceID
        self.policy = PlaybackPolicy(deviceID: deviceID)
        let locator = LocalMediaLocator()
        self.player = PlaybackCoordinator(locator: locator)
        self.refresher = FeedRefresher(store: store)
    }

    // MARK: - Laden

    public func load() async {
        do {
            sources = try await store.sources()
            profile = try await store.interestProfile(learningEnabled: profile.learningEnabled)
            ledger = try await store.ledger()
            modelStatus = await ModelStatusProbe.current()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Quellen

    /// Nimmt einen eingefügten Link auf.
    ///
    /// Abonnieren heißt hier ausdrücklich nicht herunterladen: die Folgen
    /// werden erfasst, nicht geladen und nicht analysiert. Was tatsächlich
    /// verarbeitet wird, entscheidet der Nutzer danach.
    public func addSource(from input: String) async {
        activity = "Link wird geprüft …"
        defer { activity = nil }
        do {
            let added = try await refresher.addSource(from: input)
            sources = try await store.sources()
            activity = "„\(added.title)“ aufgenommen · \(added.episodeCount) Folgen gefunden"
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func refreshAll() async {
        activity = "Feeds werden aktualisiert …"
        defer { activity = nil }
        do {
            let result = try await refresher.refreshAll()
            sources = try await store.sources()
            activity = result.newEpisodes > 0
                ? "\(result.newEpisodes) neue Folgen"
                : "Keine neuen Folgen"
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Interessen

    public func addInterest(_ label: String, kind: InterestKind) async {
        let interest = Interest(label: label, kind: kind, origin: .confirmedByUser)
        do {
            try await store.upsert(interest: interest)
            profile = try await store.interestProfile(learningEnabled: profile.learningEnabled)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func removeInterest(_ id: InterestID) async {
        do {
            try await store.removeInterest(id)
            profile = try await store.interestProfile(learningEnabled: profile.learningEnabled)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Wiedergabe

    /// Startet einen Hörplan. Der einzige Weg von der Oberfläche zum Ton.
    public func play(_ plan: ValidatedPlaybackPlan, from trigger: PlayTrigger) {
        let grant: PlaybackGrant = switch trigger {
        case .tap: policy.grantForUserTap(on: plan)
        case .chat: policy.grantForConfirmedChatPlayback(on: plan)
        case .intent: policy.grantForUserIntent(on: plan)
        }
        do {
            try player.start(plan: plan, grant: grant, deviceID: deviceID)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public enum PlayTrigger { case tap, chat, intent }

    /// Nimmt Gehörtes in den gemeinsamen Hörzustand auf.
    public func recordHeard(_ range: MediaTimeRange, in mediaVersionID: MediaVersionID, via route: PlaybackRoute) async {
        let event = LedgerEvent(mediaVersionID: mediaVersionID, range: range,
                                kind: .played, via: route, deviceID: deviceID)
        do {
            try await store.record([event])
            ledger.apply(event)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func clearError() { lastError = nil }

    static func currentDeviceID() -> String {
        // Stabil je Installation, ohne Gerätekennung zu erheben.
        let key = "com.podcastai.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }
}

/// Ein für den Nutzer relevanter Abschnitt, wie er auf „Für dich“ erscheint.
public struct RelevantItem: Identifiable, Sendable {
    public let id: EvidenceID
    public let sourceTitle: String
    public let episodeTitle: String
    public let range: MediaTimeRange
    public let excerpt: String
    public let relevance: PersonalRelevance?

    public init(id: EvidenceID, sourceTitle: String, episodeTitle: String,
                range: MediaTimeRange, excerpt: String, relevance: PersonalRelevance?) {
        self.id = id; self.sourceTitle = sourceTitle; self.episodeTitle = episodeTitle
        self.range = range; self.excerpt = excerpt; self.relevance = relevance
    }
}
