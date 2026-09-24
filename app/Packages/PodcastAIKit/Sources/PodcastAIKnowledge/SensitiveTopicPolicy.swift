//
//  SensitiveTopicPolicy.swift
//  PodcastAIKnowledge
//
//  Themenfelder, zu denen die App keine Haltung des Nutzers ableitet.
//

import Foundation
import PodcastAICore

/// Verhindert, dass aus Hörverhalten ein politisches Überzeugungsprofil wird.
public enum SensitiveTopicPolicy {

    /// Themenfelder, zu denen keine Haltung abgeleitet wird.
    ///
    /// Die App darf dazu Sachaussagen erschließen, vergleichen und
    /// wiedergeben. Sie leitet aber keine Position des Nutzers daraus ab,
    /// schlägt dazu keine Interessen vor und ordnet nichts nach
    /// Überzeugungsnähe.
    public static let restrictedDerivation = Set([
        "partei", "wahl", "regierung", "opposition", "abstimmung",
        "religion", "glaube", "konfession",
        "migration", "asyl",
        "abtreibung", "sterbehilfe",
    ])

    /// Darf aus diesem Inhalt ein Interesse vorgeschlagen werden?
    public static func allowsInterestDerivation(from text: String) -> Bool {
        let normalized = RelevanceScorer.normalize(text)
        return !restrictedDerivation.contains { normalized.contains($0) }
    }
}
