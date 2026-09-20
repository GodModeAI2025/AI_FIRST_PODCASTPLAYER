//
//  CoreInvariantTests.swift
//  PodcastAIKitTests
//
//  Die Invarianten, die in dieser Umgebung über Python-Referenzmodelle
//  belegt wurden, hier noch einmal in Swift — damit sie auf einem Mac
//  tatsächlich gegen den echten Code laufen und nicht nur gegen eine
//  Portierung davon.
//
//  Jeder Test entspricht einer Zusage aus dem Produktkonzept. Wenn einer
//  fällt, ist nicht ein Detail kaputt, sondern ein Versprechen.
//

import Testing
import Foundation
@testable import PodcastAIKit

// MARK: - Intervall-Algebra

@Suite("Hörzustand")
struct ListeningLedgerTests {

    private let media = MediaVersionID(rawValue: "m1")

    private func range(_ start: Int64, _ end: Int64) -> MediaTimeRange {
        MediaTimeRange(start: MediaTime(milliseconds: start), end: MediaTime(milliseconds: end))
    }

    @Test("Im persönlichen Update Gehörtes gilt auch in der Originalfolge")
    func heardInEditionCountsInOriginal() {
        var ledger = ListeningLedger()
        ledger.apply(LedgerEvent(
            mediaVersionID: media, range: range(600_000, 900_000),
            kind: .played, via: .smartFeedEpisode, deviceID: "test"
        ))

        let unheard = ledger.unheardPortion(of: range(0, 3_600_000), in: media)
        #expect(unheard.ranges == [range(0, 600_000), range(900_000, 3_600_000)])
    }

    @Test("In der Originalfolge Gehörtes taucht nicht im Update auf")
    func heardInOriginalSuppressesCandidate() {
        var ledger = ListeningLedger()
        ledger.apply(LedgerEvent(
            mediaVersionID: media, range: range(0, 1_200_000),
            kind: .played, via: .originalEpisode, deviceID: "test"
        ))

        let candidate = range(600_000, 900_000)
        #expect(ledger.unheardPortion(of: candidate, in: media).isEmpty)
    }

    @Test("Überspringen macht Gehörtes nicht rückgängig")
    func skipDoesNotUndoHeard() {
        var state = MediaListeningState(mediaVersionID: media)
        state.apply(LedgerEvent(mediaVersionID: media, range: range(0, 60_000),
                                kind: .played, via: .originalEpisode, deviceID: "t"))
        state.apply(LedgerEvent(mediaVersionID: media, range: range(0, 60_000),
                                kind: .skipped, via: .originalEpisode, deviceID: "t"))

        #expect(state.heard.ranges == [range(0, 60_000)])
        #expect(state.skipped.isEmpty)
    }

    @Test("Zu kurze Restfragmente lösen keine Ausgabe aus")
    func shortFragmentsDropped() {
        var ledger = ListeningLedger()
        ledger.apply(LedgerEvent(mediaVersionID: media, range: range(0, 295_000),
                                 kind: .played, via: .originalEpisode, deviceID: "t"))

        // 5 Sekunden Rest bei 20 Sekunden Mindestlänge.
        #expect(ledger.unheardPortion(of: range(0, 300_000), in: media).isEmpty)
        // Ein echter Rest bleibt erhalten.
        ledger = ListeningLedger()
        ledger.apply(LedgerEvent(mediaVersionID: media, range: range(0, 240_000),
                                 kind: .played, via: .originalEpisode, deviceID: "t"))
        #expect(ledger.unheardPortion(of: range(0, 300_000), in: media).ranges
                == [range(240_000, 300_000)])
    }

    @Test("Zusammenführen zweier Geräte ist kommutativ und verliert nichts")
    func mergeIsCommutative() {
        var a = ListeningLedger()
        a.apply(LedgerEvent(mediaVersionID: media, range: range(0, 100_000),
                            kind: .played, via: .originalEpisode, deviceID: "a"))
        var b = ListeningLedger()
        b.apply(LedgerEvent(mediaVersionID: media, range: range(80_000, 200_000),
                            kind: .played, via: .smartFeedEpisode, deviceID: "b"))

        #expect(a.merged(with: b).heard(in: media).ranges
                == b.merged(with: a).heard(in: media).ranges)
        #expect(a.merged(with: b).heard(in: media).ranges == [range(0, 200_000)])
    }
}

// MARK: - Intervallmenge

@Suite("Intervallmenge")
struct IntervalSetTests {

    private func range(_ s: Int64, _ e: Int64) -> MediaTimeRange {
        MediaTimeRange(start: MediaTime(milliseconds: s), end: MediaTime(milliseconds: e))
    }

    @Test("Angrenzende Intervalle verschmelzen, überlappende auch")
    func normalizes() {
        let set = IntervalSet([range(0, 10), range(10, 20), range(15, 30), range(50, 60)])
        #expect(set.ranges == [range(0, 30), range(50, 60)])
    }

    @Test("Vereinigung ist idempotent")
    func unionIdempotent() {
        let set = IntervalSet([range(0, 100), range(200, 300)])
        #expect(set.union(set).ranges == set.ranges)
    }

    @Test("Abdeckung rechnet anteilig")
    func coverage() {
        let set = IntervalSet(range(0, 50))
        #expect(set.coverage(of: range(0, 200)) == 0.25)
        #expect(set.coverage(of: range(0, 50)) == 1.0)
    }

    @Test("Leeres und invertiertes Intervall sind kein Fehler")
    func degenerate() {
        #expect(range(100, 50).isEmpty)
        #expect(IntervalSet([range(100, 50)]).isEmpty)
    }
}

// MARK: - Belegbindung

@Suite("Belege")
struct EvidenceTests {

    @Test("Eine Aussage ohne Beleg ist kein gültiger Datensatz")
    func claimNeedsEvidence() {
        let withoutEvidence = Claim(id: ClaimID(), statement: "Etwas", evidenceIDs: [])
        #expect(!withoutEvidence.isWellFormed)

        let withEvidence = Claim(id: ClaimID(), statement: "Etwas",
                                 evidenceIDs: [EvidenceID(rawValue: "e1")])
        #expect(withEvidence.isWellFormed)
    }

    @Test("Ohne Zeitbezug ist eine Fundstelle nicht abspielbar")
    func untimedEvidenceNotPlayable() {
        let evidence = Evidence(
            id: EvidenceID(), mediaVersionID: MediaVersionID(), episodeID: EpisodeID(),
            sourceID: SourceID(), transcriptID: TranscriptID(), transcriptRevision: .initial,
            range: nil, quotedText: "Text ohne Zeit"
        )
        #expect(!evidence.isPlayable)
    }

    @Test("Dieselbe Stelle ergibt zweimal dieselbe Kennung")
    func stableIdentity() {
        let media = MediaVersionID(rawValue: "m1")
        let range = MediaTimeRange(start: MediaTime(seconds: 10), end: MediaTime(seconds: 20))
        #expect(Evidence.stableID(mediaVersionID: media, transcriptRevision: .initial, range: range)
                == Evidence.stableID(mediaVersionID: media, transcriptRevision: .initial, range: range))
    }
}

// MARK: - Wiedergabefreigabe

@Suite("Wiedergabefreigabe")
struct PlaybackGrantTests {

    private func makePlan() -> ValidatedPlaybackPlan {
        ValidatedPlaybackPlan(
            segments: [PlanSegment(
                evidenceID: EvidenceID(rawValue: "e1"),
                mediaVersionID: MediaVersionID(rawValue: "m1"),
                episodeID: EpisodeID(rawValue: "ep1"),
                sourceID: SourceID(rawValue: "s1"),
                range: MediaTimeRange(start: MediaTime(seconds: 10), end: MediaTime(seconds: 40)),
                sourceTitle: "Quelle", episodeTitle: "Folge"
            )],
            requestSummary: "Test", route: .chatFocus
        )
    }

    @Test("Eine Freigabe gilt nur für genau diesen Plan")
    func grantBoundToPlan() {
        let plan = makePlan()
        let grant = PlaybackGrant(planID: plan.id, planHash: plan.planHash,
                                  deviceID: "device", trigger: .userTappedPlay)
        #expect(grant.isValid(for: plan, on: "device"))

        // Anderer Plan, gleiche Kennung: der Hash rettet die Prüfung.
        let other = ValidatedPlaybackPlan(id: plan.id, segments: [], requestSummary: "x",
                                          route: .chatFocus)
        #expect(!grant.isValid(for: other, on: "device"))
    }

    @Test("Eine Freigabe gilt nur auf dem ausstellenden Gerät")
    func grantBoundToDevice() {
        let plan = makePlan()
        let grant = PlaybackGrant(planID: plan.id, planHash: plan.planHash,
                                  deviceID: "device-a", trigger: .userTappedPlay)
        #expect(!grant.isValid(for: plan, on: "device-b"))
    }

    @Test("Eine abgelaufene Freigabe startet nichts")
    func grantExpires() {
        let plan = makePlan()
        let issued = Date().addingTimeInterval(-300)
        let grant = PlaybackGrant(planID: plan.id, planHash: plan.planHash,
                                  deviceID: "device", trigger: .userTappedPlay,
                                  issuedAt: issued, validFor: 120)
        #expect(!grant.isValid(for: plan, on: "device"))
    }
}

// MARK: - Interessen

@Suite("Interessenprofil")
struct InterestProfileTests {

    @Test("Ein Vorschlag wird nur durch eine Nutzeraktion zum Interesse")
    func suggestionNeedsConfirmation() {
        var profile = InterestProfile(learningEnabled: true)
        let suggested = Interest(label: "Lokale KI", origin: .suggestedBySystem)
        profile.add(suggested)

        #expect(profile.confirmed.isEmpty)
        #expect(profile.publicationDrivers().isEmpty)

        profile.confirm(suggested.id)
        #expect(profile.confirmed.count == 1)
        #expect(profile.publicationDrivers().count == 1)
    }

    @Test("Ohne Lernfreigabe wird kein Vorschlag aufgenommen")
    func learningDisabledBlocksSuggestions() {
        var profile = InterestProfile(learningEnabled: false)
        profile.add(Interest(label: "Lokale KI", origin: .suggestedBySystem))
        #expect(profile.interests.isEmpty)
    }

    @Test("Zurücksetzen lässt bestätigte Interessen unberührt")
    func resetKeepsConfirmed() {
        var profile = InterestProfile(learningEnabled: true)
        profile.add(Interest(label: "Datenschutz", origin: .confirmedByUser))
        profile.add(Interest(label: "Vermutet", origin: .suggestedBySystem))

        profile.resetLearning()
        #expect(profile.confirmed.count == 1)
        #expect(profile.suggested.isEmpty)
        #expect(profile.epoch == 1)
    }

    @Test("Ein abgelaufenes Vorhaben treibt keine Veröffentlichung mehr")
    func expiredProjectStops() {
        let expired = Interest(label: "Altes Vorhaben", kind: .activeProject,
                               expiresAt: Date().addingTimeInterval(-60))
        #expect(!expired.canDrivePublication())
    }
}
