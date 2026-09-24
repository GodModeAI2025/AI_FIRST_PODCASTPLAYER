//
//  Interest.swift
//  PodcastAICore
//
//  „Vom Nutzer bestätigt“ und „von PodcastAI vermutet“ sind verschiedene
//  Dinge und bleiben es. Im Bestandscode von BrainSpeak war das eine einzige
//  Textdatei (`identity.md`); FR-038 verlangt vier getrennte Kategorien.
//

import Foundation

/// Wie ein Interesse in das Profil gekommen ist.
public enum InterestOrigin: String, Codable, Sendable {
    /// Vom Nutzer selbst eingetragen oder ausdrücklich bestätigt.
    case confirmedByUser
    /// Von PodcastAI aus Verhalten oder Inhalten vorgeschlagen, noch nicht bestätigt.
    case suggestedBySystem
    /// Als Tag aus dem Inhalt eines Kapitels erkannt, seit 0.10. Ein solches
    /// Tag steht neutral in der Wolke, bis jemand Plus wählt.
    case detected

    public var isConfirmed: Bool { self == .confirmedByUser }

    public var label: String {
        switch self {
        case .confirmedByUser: String(localized: "von dir bestätigt", bundle: .module)
        case .suggestedBySystem: String(localized: "von PodcastAI vorgeschlagen", bundle: .module)
        case .detected: String(localized: "aus dem Inhalt erkannt", bundle: .module)
        }
    }
}

/// Welche Rolle ein Eintrag im Profil spielt.
public enum InterestKind: String, Codable, Sendable {
    /// Dauerhaftes Themeninteresse: „iOS / Mobile“, „Datenschutz“.
    case topic
    /// Zeitlich begrenztes Vorhaben: „Aktuell beschäftige ich mich mit lokalen KI-Modellen.“
    case activeProject
    /// Eine konkrete offene Frage: „Welche Möglichkeiten bietet iOS 27 für agentische Apps?“
    case openQuestion
}

public struct Interest: Hashable, Codable, Sendable, Identifiable {

    public let id: InterestID
    public var label: String
    public var kind: InterestKind
    public var origin: InterestOrigin
    /// Zusätzliche Stichworte, die der Nutzer selbst pflegt.
    public var keywords: [String]
    /// Bei `.activeProject` optional: ab wann es nicht mehr aktuell ist.
    public var expiresAt: Date?
    public var createdAt: Date
    /// Seit 0.10 ist jedes Interesse ein Tag. Plus heißt folgen, Minus
    /// heißt nicht mehr folgen. Das Tag bleibt dann sichtbar und neutral.
    public var stance: TagStance
    /// Der Schlüssel, unter dem Schreibweisen desselben Tags zusammenfallen,
    /// siehe `TagNormalizer`. Leer, solange er nicht berechnet ist.
    public var normalizedKey: String
    /// Wann das Tag zum ersten Mal in einem Kapitel erkannt wurde.
    public var firstSeenAt: Date?

    public init(
        id: InterestID = InterestID(), label: String, kind: InterestKind = .topic,
        origin: InterestOrigin = .confirmedByUser, keywords: [String] = [],
        expiresAt: Date? = nil, createdAt: Date = Date(),
        stance: TagStance = .follow, normalizedKey: String = "", firstSeenAt: Date? = nil
    ) {
        self.id = id; self.label = label; self.kind = kind; self.origin = origin
        self.keywords = keywords; self.expiresAt = expiresAt; self.createdAt = createdAt
        self.stance = stance; self.normalizedKey = normalizedKey; self.firstSeenAt = firstSeenAt
    }

    public func isActive(at date: Date = Date()) -> Bool {
        guard let expiresAt else { return true }
        return date < expiresAt
    }

    /// Folgt jemand diesem Tag? Ein bloßer Vorschlag zählt nicht, ein
    /// erkanntes Tag erst nach Plus, ein bestätigtes nicht mehr nach Minus.
    public var isFollowed: Bool {
        stance == .follow && origin != .suggestedBySystem
    }

    /// Darf dieses Interesse allein eine persönliche Ausgabe auslösen?
    /// Ein bloß vermutetes Interesse reicht dafür nicht, ein Tag ohne Plus
    /// auch nicht.
    public func canDrivePublication(at date: Date = Date()) -> Bool {
        isFollowed && isActive(at: date)
    }

    /// Dasselbe Interesse als Tag.
    public var tag: Tag { Tag(self) }
}

extension Interest {
    private enum CodingKeys: String, CodingKey {
        case id, label, kind, origin, keywords, expiresAt, createdAt
        case stance, normalizedKey, firstSeenAt
    }

    /// Liest auch Werte aus der Zeit vor den Tags: Haltung, Schlüssel und
    /// erstes Auftreten fehlen dort.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(InterestID.self, forKey: .id),
            label: try container.decode(String.self, forKey: .label),
            kind: try container.decode(InterestKind.self, forKey: .kind),
            origin: try container.decode(InterestOrigin.self, forKey: .origin),
            keywords: try container.decodeIfPresent([String].self, forKey: .keywords) ?? [],
            expiresAt: try container.decodeIfPresent(Date.self, forKey: .expiresAt),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            stance: try container.decodeIfPresent(TagStance.self, forKey: .stance) ?? .follow,
            normalizedKey: try container.decodeIfPresent(String.self, forKey: .normalizedKey) ?? "",
            firstSeenAt: try container.decodeIfPresent(Date.self, forKey: .firstSeenAt))
    }
}

/// Wie der Nutzer auf einen Vorschlag reagiert hat.
///
/// Vier getrennte Wirkungen statt eines Daumens: „kenne ich schon“ ist keine
/// Aussage über Wichtigkeit, und „nicht aus dieser Quelle“ ist keine Aussage
/// über das Thema.
public enum InterestFeedback: String, Codable, Sendable {
    case moreOfThis
    case alreadyKnown
    case notRelevant
    case notFromThisSource

    public var label: String {
        switch self {
        case .moreOfThis: String(localized: "Mehr davon", bundle: .module)
        case .alreadyKnown: String(localized: "Bereits bekannt", bundle: .module)
        case .notRelevant: String(localized: "Nicht relevant", bundle: .module)
        case .notFromThisSource: String(localized: "Nicht aus dieser Quelle", bundle: .module)
        }
    }
}

public struct FeedbackEvent: Hashable, Codable, Sendable {
    public let feedback: InterestFeedback
    public let evidenceID: EvidenceID
    public let interestID: InterestID?
    public let sourceID: SourceID
    public let at: Date
    /// Zählt zur aktuellen Lernepoche. Ein Zurücksetzen erhöht die Epoche,
    /// statt Ereignisse zu löschen — append-only.
    public let epoch: Int

    public init(
        feedback: InterestFeedback, evidenceID: EvidenceID, interestID: InterestID? = nil,
        sourceID: SourceID, at: Date = Date(), epoch: Int
    ) {
        self.feedback = feedback; self.evidenceID = evidenceID; self.interestID = interestID
        self.sourceID = sourceID; self.at = at; self.epoch = epoch
    }
}

/// Das vollständige, jederzeit einsehbare und korrigierbare Interessenprofil.
public struct InterestProfile: Codable, Sendable {

    public private(set) var interests: [Interest]
    /// Ob PodcastAI überhaupt neue Interessen vorschlagen darf. Opt-in.
    public var learningEnabled: Bool
    /// Erhöht sich beim Zurücksetzen. Ältere Lernsignale bleiben erhalten,
    /// wirken aber nicht mehr.
    public private(set) var epoch: Int
    public private(set) var revision: Revision

    public init(
        interests: [Interest] = [], learningEnabled: Bool = false,
        epoch: Int = 0, revision: Revision = .initial
    ) {
        self.interests = interests; self.learningEnabled = learningEnabled
        self.epoch = epoch; self.revision = revision
    }

    public var confirmed: [Interest] { interests.filter { $0.origin.isConfirmed } }
    /// Nur Vorschläge. Aus dem Inhalt erkannte Tags gehören nicht dazu, sie
    /// stehen in der Tag-Wolke.
    public var suggested: [Interest] { interests.filter { $0.origin == .suggestedBySystem } }
    /// Tags, denen jemand folgt. Nur sie zählen für Relevanz und Themen-Updates.
    public var topics: [Interest] { interests.filter { $0.isFollowed && $0.kind == .topic } }
    /// Alle Tags, auch neutrale und erkannte, ohne Vorschläge.
    public var tags: [Tag] { interests.filter { $0.origin != .suggestedBySystem }.map(\.tag) }
    public var activeProjects: [Interest] { confirmed.filter { $0.kind == .activeProject && $0.isActive() } }
    public var openQuestions: [Interest] { confirmed.filter { $0.kind == .openQuestion } }

    public mutating func add(_ interest: Interest) {
        guard !interests.contains(where: { $0.id == interest.id }) else { return }
        // Ein Vorschlag darf nur aufgenommen werden, wenn Lernen erlaubt ist.
        // Erkannte Tags stammen aus dem Inhalt, nicht aus dem Verhalten.
        guard interest.origin != .suggestedBySystem || learningEnabled else { return }
        interests.append(interest)
        revision = revision.next()
    }

    /// Hebt einen Vorschlag zu einem bestätigten Interesse. Die einzige Stelle,
    /// an der aus „vermutet“ „bestätigt“ wird — und sie braucht eine Nutzeraktion.
    public mutating func confirm(_ id: InterestID) {
        guard let index = interests.firstIndex(where: { $0.id == id }) else { return }
        interests[index].origin = .confirmedByUser
        revision = revision.next()
    }

    public mutating func remove(_ id: InterestID) {
        interests.removeAll { $0.id == id }
        revision = revision.next()
    }

    /// Setzt das Gelernte zurück, ohne bestätigte Interessen anzutasten.
    public mutating func resetLearning() {
        interests.removeAll { $0.origin == .suggestedBySystem }
        epoch += 1
        revision = revision.next()
    }

    /// Alle Interessen, die eine Veröffentlichung rechtfertigen können.
    public func publicationDrivers(at date: Date = Date()) -> [Interest] {
        interests.filter { $0.canDrivePublication(at: date) }
    }
}
