//
//  ModelRoutingTests.swift
//
//  „PCC Cloud für alles“ (Entscheidung des Product Owners vom 27. September
//  2026): Jede Aufgabe läuft zuerst auf Private Cloud Compute, das Gerät
//  springt nur ein, wenn PCC fehlt, und fehlen beide, läuft nichts. Ohne
//  Netz wartet die Arbeit, statt zu scheitern.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIIntelligence
#if canImport(FoundationModels)
import FoundationModels
#endif

@Suite("Stufenwahl: Private Cloud Compute für alles")
struct ModelRoutingTests {

    /// Jeder Grund, aus dem PCC fehlen kann.
    static let cloudReasons: [ModelUnavailability] = [
        .offline, .quotaExhausted(resetDate: nil), .entitlementMissing, .userConsentMissing,
        .deviceNotEligible, .modelNotReady, .unknown("Freigabe steht aus"),
    ]

    @Test("Sind beide Stufen da, rechnet für jede Aufgabe Private Cloud Compute",
          arguments: TaskProfile.allCases)
    func cloudPreferred(_ profile: TaskProfile) {
        #expect(profile.preferredTier == .privateCloudCompute)
        let both = ModelStatus(onDevice: .available, privateCloudCompute: .available)
        #expect(both.resolve(profile) == .success(.privateCloudCompute))
        let cloudOnly = ModelStatus(onDevice: .unavailable(.appleIntelligenceDisabled), privateCloudCompute: .available)
        #expect(cloudOnly.resolve(profile) == .success(.privateCloudCompute))
    }

    @Test("Fehlt Private Cloud Compute, rechnet für jede Aufgabe das Gerät",
          arguments: TaskProfile.allCases)
    func deviceFallback(_ profile: TaskProfile) {
        for reason in Self.cloudReasons {
            let status = ModelStatus(onDevice: .available, privateCloudCompute: .unavailable(reason))
            #expect(status.resolve(profile) == .success(.onDevice), "PCC fehlt: \(reason)")
        }
    }

    @Test("Fehlen beide, läuft keine Aufgabe", arguments: TaskProfile.allCases)
    func neither(_ profile: TaskProfile) {
        for reason in Self.cloudReasons {
            let status = ModelStatus(
                onDevice: .unavailable(.appleIntelligenceDisabled), privateCloudCompute: .unavailable(reason))
            guard case .failure = status.resolve(profile) else {
                Issue.record("\(profile) lief ohne Modell, PCC fehlt: \(reason)")
                continue
            }
        }
    }

    @Test("Fehlen beide, nennt die Stufenwahl den Grund, der weiterhilft")
    func failureReason() {
        // PCC fehlt nur vorübergehend: dieser Grund, die Arbeit wartet darauf.
        let offline = ModelStatus(onDevice: .unavailable(.deviceNotEligible), privateCloudCompute: .unavailable(.offline))
        #expect(offline.resolve(.extract) == .failure(.offline))
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = ModelStatus(onDevice: .unavailable(.deviceNotEligible),
                                privateCloudCompute: .unavailable(.quotaExhausted(resetDate: reset)))
        #expect(quota.resolve(.tag) == .failure(.quotaExhausted(resetDate: reset)))
        // PCC ist aus: der Grund des Geräts. Lädt das Gerätemodell noch, wird
        // weiter eingereiht, statt still aufzugeben.
        let loading = ModelStatus(onDevice: .unavailable(.modelNotReady),
                                  privateCloudCompute: .unavailable(.userConsentMissing))
        #expect(loading.resolve(.extract) == .failure(.modelNotReady))
        let disabled = ModelStatus(onDevice: .unavailable(.appleIntelligenceDisabled),
                                   privateCloudCompute: .unavailable(.entitlementMissing))
        #expect(disabled.resolve(.summarize) == .failure(.appleIntelligenceDisabled))
        // Apple Intelligence aus: das sagt die App, auch wenn PCC nur „noch
        // nicht bereit“ meldet. Sonst warteten Fakten ewig auf ein Modell.
        for reason in [ModelUnavailability.modelNotReady, .offline, .quotaExhausted(resetDate: nil)] {
            let off = ModelStatus(onDevice: .unavailable(.appleIntelligenceDisabled),
                                  privateCloudCompute: .unavailable(reason))
            #expect(off.resolve(.extract) == .failure(.appleIntelligenceDisabled), "PCC: \(reason)")
        }
    }

    @Test("Vorübergehend ist nur, was von selbst vergeht")
    func temporaryReasons() {
        #expect(ModelUnavailability.offline.isTemporary)
        #expect(ModelUnavailability.quotaExhausted(resetDate: nil).isTemporary)
        #expect(ModelUnavailability.modelNotReady.isTemporary)
        #expect(!ModelUnavailability.appleIntelligenceDisabled.isTemporary)
        #expect(!ModelUnavailability.deviceNotEligible.isTemporary)
        #expect(!ModelUnavailability.userConsentMissing.isTemporary)
        #expect(!ModelUnavailability.entitlementMissing.isTemporary)
    }
}

@Suite("Ohne Netz: die Arbeit wartet")
struct OfflinePauseTests {

    private func passage(_ index: Int) -> Evidence {
        Evidence(
            id: EvidenceID(stable: "offline-\(index)"), mediaVersionID: MediaVersionID(stable: "fassung"),
            episodeID: EpisodeID(stable: "folge"), sourceID: SourceID(stable: "quelle"),
            transcriptID: TranscriptID(stable: "t"), transcriptRevision: Revision(0),
            range: MediaTimeRange(start: MediaTime(milliseconds: Int64(index) * 60_000),
                                  end: MediaTime(milliseconds: Int64(index + 1) * 60_000)),
            quotedText: "Datenschutz in Messengern ist ein Thema dieser Folge, Nummer \(index).")
    }

    @Test("Ohne Netz fehlt Private Cloud Compute, das Gerät springt ein")
    func offlineUsesDevice() {
        let online = ModelStatus(onDevice: .available, privateCloudCompute: .available)
        #expect(online.assumingOffline(false) == online)
        let offline = online.assumingOffline(true)
        #expect(offline.privateCloudCompute == .unavailable(.offline))
        #expect(offline.onDevice == .available)
        for profile in TaskProfile.allCases {
            #expect(offline.resolve(profile) == .success(.onDevice))
        }
    }

    @Test("Ohne Netz und ohne Gerätemodell wartet jede Aufgabe aufs Netz")
    func offlineWithoutDeviceWaits() {
        let status = ModelStatus(onDevice: .unavailable(.deviceNotEligible), privateCloudCompute: .available)
            .assumingOffline(true)
        for profile in TaskProfile.allCases {
            guard case .failure(let reason) = status.resolve(profile) else {
                Issue.record("\(profile) lief ohne Netz und ohne Gerät")
                continue
            }
            #expect(reason == .offline)
            // Vorübergehend: die Folge bleibt eingereiht, statt als gescheitert zu gelten.
            #expect(reason.isTemporary)
        }
        // Kommt das Netz wieder, läuft alles über PCC weiter.
        let back = ModelStatus(onDevice: .unavailable(.deviceNotEligible), privateCloudCompute: .available)
            .assumingOffline(false)
        #expect(back.resolve(.extract) == .success(.privateCloudCompute))
    }

    @Test("Ohne Netz bleibt ein schon genannter Grund stehen")
    func offlineKeepsKnownReason() {
        let consent = ModelStatus(onDevice: .available, privateCloudCompute: .unavailable(.userConsentMissing))
        #expect(consent.assumingOffline(true) == consent)
        let quota = ModelStatus(onDevice: .available, privateCloudCompute: .unavailable(.quotaExhausted(resetDate: nil)))
        #expect(quota.assumingOffline(true).privateCloudLimit == .quotaExhausted(resetDate: nil))
    }

    @Test("Fakten ohne Netz und ohne Gerät: nicht verfügbar, nicht gescheitert")
    func factsPauseOffline() async {
        let status = ModelStatus(onDevice: .unavailable(.deviceNotEligible), privateCloudCompute: .available)
            .assumingOffline(true)
        do {
            _ = try await KnowledgeExtractor().extractClaims(from: [passage(0)], availability: status)
            Issue.record("Fakten liefen ohne Modell")
        } catch ExtractorError.modelUnavailable(let reason) {
            #expect(reason == .offline)
        } catch {
            Issue.record("Falscher Fehler: \(error)")
        }
    }

    @Test("Tags ohne Netz und ohne Gerät: nicht verfügbar, nicht gescheitert")
    func tagsPauseOffline() async {
        let status = ModelStatus(onDevice: .unavailable(.deviceNotEligible), privateCloudCompute: .available)
            .assumingOffline(true)
        do {
            _ = try await TagSelector().select(
                from: [TagChoice(id: "k1", label: "Datenschutz")], passages: [passage(0)],
                title: nil, availability: status)
            Issue.record("Tags liefen ohne Modell")
        } catch ExtractorError.modelUnavailable(let reason) {
            #expect(reason == .offline)
        } catch {
            Issue.record("Falscher Fehler: \(error)")
        }
    }

    #if canImport(FoundationModels)
    @Test("Scheitert PCC an Netz oder Kontingent, wartet die Arbeit; ein Dienstausfall wird wiederholt")
    func cloudErrorsBecomePause() {
        typealias PCCError = PrivateCloudComputeLanguageModel.Error
        let network = PCCError.networkFailure(.init(debugDescription: "kein Netz"))
        #expect(KnowledgeExtractor.privateCloudPause(network) == .offline)
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = PCCError.quotaLimitReached(.init(resetDate: reset, debugDescription: "Kontingent"))
        #expect(KnowledgeExtractor.privateCloudPause(quota) == .quotaExhausted(resetDate: reset))
        let service = PCCError.serviceUnavailable(.init(debugDescription: "Dienst"))
        #expect(KnowledgeExtractor.privateCloudPause(service) == nil)
        #expect(KnowledgeExtractor.privateCloudPause(CancellationError()) == nil)
    }
    #endif
}
