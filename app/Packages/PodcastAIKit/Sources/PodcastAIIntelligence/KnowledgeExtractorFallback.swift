//
//  KnowledgeExtractorFallback.swift
//  PodcastAIIntelligence
//
//  `KnowledgeExtractor` steht hinter `#if canImport(FoundationModels)`.
//  Ohne diesen Ersatz gäbe es den Typ auf einer Plattform ohne das
//  Framework schlicht nicht — und jeder Aufrufer müsste sich selbst mit
//  `#if` gegen seine Abwesenheit wappnen. Das ist die Art von Bedingung,
//  die sich über ein Projekt verteilt und irgendwo vergessen wird.
//
//  Stattdessen gibt es den Typ immer, und ohne Framework wirft er den
//  Grund. Das ist auch das ehrlichere Verhalten: „kein Modell verfügbar“
//  ist eine Antwort, die bis in die Oberfläche durchgereicht werden kann.
//
//  `ExtractorConfiguration` und `ComposedAnswer` stehen in
//  EvidenceSelection.swift und gelten für beide Fassungen.
//

#if !canImport(FoundationModels)
import Foundation
import PodcastAICore

public enum ExtractorError: Error, LocalizedError {
    case modelUnavailable(ModelUnavailability)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason): reason.message
        case .generationFailed(let detail): "Die Auswertung ist fehlgeschlagen: \(detail)"
        }
    }
}

public struct KnowledgeExtractor: Sendable {

    private static let reason = ModelUnavailability.unknown(
        "Auf dieser Plattform gibt es kein Apple-Sprachmodell.")

    public init(configuration: ExtractorConfiguration = ExtractorConfiguration()) {}

    public func selectRelevant(
        from evidence: [Evidence], profile: InterestProfile, availability: ModelStatus
    ) async throws -> ValidatedSelection {
        throw ExtractorError.modelUnavailable(Self.reason)
    }

    public func extractClaims(
        from evidence: [Evidence], availability: ModelStatus
    ) async throws -> [Claim] {
        throw ExtractorError.modelUnavailable(Self.reason)
    }

    public func classify(
        _ evidence: [Evidence], against thesis: String,
        labels: [String], availability: ModelStatus
    ) async throws -> [EvidenceID: String] {
        throw ExtractorError.modelUnavailable(Self.reason)
    }

    public func answer(
        question: String, from evidence: [Evidence], libraryContext: String = "",
        availability: ModelStatus
    ) async throws -> ComposedAnswer {
        throw ExtractorError.modelUnavailable(Self.reason)
    }

    public static func currentStatus(allowPrivateCloud: Bool) -> ModelStatus {
        ModelStatus(onDevice: .unavailable(reason), privateCloudCompute: .unavailable(reason))
    }
}
#endif
