//
//  RelevanceScorer.swift
//  PodcastAIKnowledge
//
//  Die Vorauswahl, bevor ein Modell überhaupt gefragt wird.
//
//  Warum es diese Stufe gibt: ein Apple-Modell auf dem Gerät hat ein
//  begrenztes Kontextfenster und kostet Zeit und Akku. Tausend Belege
//  einzeln vorzulegen ist weder möglich noch nötig. Diese Stufe verengt
//  deterministisch auf eine Kandidatenliste; erst darüber entscheidet das
//  Modell inhaltlich.
//
//  Gleichzeitig ist sie der Rückfall, wenn Apple Intelligence nicht zur
//  Verfügung steht. Dann ist die App schwächer, aber nicht kaputt — und sie
//  sagt es (siehe ``RelevanceMatch.isModelConfirmed``).
//
//  Bewusst ohne Apple-Frameworks und damit prüfbar.
//

import Foundation
import PodcastAICore

/// Warum ein Beleg als Kandidat gilt.
public struct RelevanceMatch: Sendable, Hashable {
    public let evidenceID: EvidenceID
    public let interestID: InterestID
    public let interestLabel: String
    public let kind: InterestKind
    /// Zwischen 0 und 1. Nur eine Rangfolge für die Vorauswahl — **keine**
    /// Aussage über Wichtigkeit, die man dem Nutzer zeigen sollte.
    public let score: Double
    /// Die Begriffe, die tatsächlich getroffen haben, in der Schreibweise
    /// des Nutzers. Machen die Auswahl nachvollziehbar, statt eine Zahl zu
    /// behaupten.
    public let matchedTerms: [String]
    /// Hat ein Modell die Relevanz bestätigt, oder ist das bloß ein Treffer
    /// auf Stichwortebene?
    public let isModelConfirmed: Bool

    public init(
        evidenceID: EvidenceID, interestID: InterestID, interestLabel: String,
        kind: InterestKind, score: Double, matchedTerms: [String],
        isModelConfirmed: Bool = false
    ) {
        self.evidenceID = evidenceID; self.interestID = interestID
        self.interestLabel = interestLabel; self.kind = kind; self.score = score
        self.matchedTerms = matchedTerms; self.isModelConfirmed = isModelConfirmed
    }

    /// Der Satz, der unter „Warum für dich relevant?“ steht.
    public func explanation() -> String {
        let terms = matchedTerms.prefix(3).joined(separator: ", ")
        let base: String = switch kind {
        case .topic: String(localized: "Passt zu deinem Thema „\(interestLabel)“", bundle: .module)
        case .activeProject: String(localized: "Passt zu deinem Vorhaben „\(interestLabel)“", bundle: .module)
        case .openQuestion: String(localized: "Könnte deine Frage „\(interestLabel)“ berühren", bundle: .module)
        }
        let suffix = terms.isEmpty ? "" : " · " + String(localized: "erwähnt: \(terms)", bundle: .module)
        // Ohne Modellbestätigung wird das ausdrücklich gesagt.
        let qualifier = isModelConfirmed ? "" : " · " + String(localized: "Wort kommt vor", bundle: .module)
        return base + suffix + qualifier
    }

    public func personalRelevance() -> PersonalRelevance {
        // `switch` ist als Ausdruck nur in Zuweisung, `return` oder
        // Variableninitialisierung erlaubt — nicht als Argument.
        let reason: PersonalRelevance.Reason = switch kind {
        case .topic: .confirmedInterest
        case .activeProject: .activeProject
        case .openQuestion: .openQuestion
        }
        return PersonalRelevance(
            reason: reason,
            interestID: interestID,
            interestLabel: interestLabel,
            explanation: explanation()
        )
    }
}

public struct RelevanceScorer: Sendable {

    /// Ab welchem Wert ein Beleg überhaupt Kandidat wird.
    public let threshold: Double
    /// Wie viele Kandidaten je Interesse höchstens weitergereicht werden.
    public let maximumPerInterest: Int

    public init(threshold: Double = 0.18, maximumPerInterest: Int = 25) {
        self.threshold = threshold
        self.maximumPerInterest = maximumPerInterest
    }

    /// Bewertet Belege gegen das Profil.
    ///
    /// Nur **bestätigte** Interessen zählen. Ein vermutetes Interesse darf
    /// keine persönliche Ausgabe auslösen — es taucht in den Vorschlägen auf
    /// und wartet dort auf eine Entscheidung.
    public func score(
        evidence: [Evidence],
        profile: InterestProfile,
        now: Date = Date()
    ) -> [RelevanceMatch] {

        let drivers = profile.publicationDrivers(at: now)
        guard !drivers.isEmpty else { return [] }

        var byInterest: [InterestID: [RelevanceMatch]] = [:]
        // Einmal normalisieren, nicht je Interesse aufs Neue.
        let haystacks = evidence.map { Self.normalize($0.quotedText) }

        for interest in drivers {
            let entries = Self.entries(for: interest)
            guard !entries.isEmpty else { continue }

            for (item, haystack) in zip(evidence, haystacks) where !haystack.isEmpty {
                let (value, matched) = Self.match(entries: entries, in: haystack)
                guard value >= threshold else { continue }

                byInterest[interest.id, default: []].append(RelevanceMatch(
                    evidenceID: item.id, interestID: interest.id,
                    interestLabel: interest.label, kind: interest.kind,
                    score: min(1.0, value * Self.weight(for: interest.kind)),
                    matchedTerms: matched
                ))
            }
        }

        // Je Interesse begrenzen, damit ein breit formuliertes Thema nicht
        // alle anderen verdrängt.
        //
        // Über die Schlüssel in sortierter Reihenfolge, nicht über
        // `byInterest.values`: Swifts `Dictionary` ist je Prozessstart
        // anders sortiert. Zwei Starts lieferten sonst verschiedene Listen
        // — und damit bei gleichem Wert eine andere Begründung unter
        // derselben Stelle.
        let limited = byInterest.keys.sorted { $0.rawValue < $1.rawValue }
            .flatMap { key in
                (byInterest[key] ?? []).sorted(by: Self.ranking).prefix(maximumPerInterest)
            }
        return limited.sorted(by: Self.ranking)
    }

    /// Ein aktuelles Vorhaben wiegt schwerer als ein Thema. Die Gewichtung
    /// wirkt erst nach der Schwelle: sie ändert die Reihenfolge, nicht, ob
    /// eine Stelle überhaupt Kandidat wird.
    static func weight(for kind: InterestKind) -> Double {
        kind == .activeProject ? 1.25 : 1.0
    }

    /// Die eine Rangfolge, an drei Stellen benutzt.
    ///
    /// Drei Stufen, nicht zwei: bei gleichem Wert **und** gleichem Beleg
    /// entscheidet das Interesse. Ohne diese dritte Stufe hängt die
    /// Reihenfolge zweier gleichwertiger Treffer an der Laufzeit, weil
    /// `sorted` in Swift nicht stabil ist.
    static func ranking(_ lhs: RelevanceMatch, _ rhs: RelevanceMatch) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.evidenceID.rawValue != rhs.evidenceID.rawValue {
            return lhs.evidenceID.rawValue < rhs.evidenceID.rawValue
        }
        return lhs.interestID.rawValue < rhs.interestID.rawValue
    }

    // MARK: - Begriffe

    /// Alle Suchbegriffe eines Interesses: Beschriftung, Stichworte und die
    /// Einzelwörter daraus.
    static func terms(for interest: Interest) -> [String] {
        var result = Set<String>()
        for entry in entries(for: interest) {
            result.insert(entry.phrase)
            result.formUnion(entry.words)
        }
        return Array(result).sorted()
    }

    /// Ein Eintrag eines Interesses, also die Bezeichnung oder ein
    /// Stichwort, zerlegt für den Vergleich.
    struct Entry: Sendable, Hashable {
        /// Der ganze Ausdruck, normalisiert.
        let phrase: String
        /// Die tragenden Wörter eines Ausdrucks aus mehreren Wörtern. Leer,
        /// wenn der Eintrag nur ein Wort ist.
        let words: [String]
        /// Normalisierte Form und Schreibweise des Nutzers, für die
        /// Begründung auf der Karte.
        let display: [String: String]

        init(phrase: String, words: [String] = [], display: [String: String] = [:]) {
            self.phrase = phrase; self.words = words; self.display = display
        }
    }

    /// Bezeichnung und Stichworte eines Interesses als Einträge.
    ///
    /// Tragende Wörter sind solche ab vier Buchstaben, die kein Füllwort
    /// sind („für“ träfe sonst überall), und kurze Abkürzungen, die der
    /// Nutzer groß geschrieben hat: KI, AI, ML, EU.
    static func entries(for interest: Interest) -> [Entry] {
        var result: [Entry] = []
        for raw in [interest.label] + interest.keywords {
            let phrase = normalize(raw)
            guard !phrase.isEmpty else { continue }
            let spelled = raw.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            var display = [phrase: raw.trimmingCharacters(in: .whitespacesAndNewlines)]
            var words: [String] = []
            if spelled.count > 1 {
                for word in spelled {
                    let normalized = word.lowercased()
                    guard !stopWords.contains(normalized), !words.contains(normalized) else { continue }
                    guard normalized.count >= 4 || isAcronym(word) else { continue }
                    words.append(normalized)
                    display[normalized] = word
                }
            }
            result.append(Entry(phrase: phrase, words: words, display: display))
        }
        return result
    }

    /// „KI“, „AI“, „EU“: zwei oder drei Zeichen, alle Buchstaben groß.
    static func isAcronym(_ word: String) -> Bool {
        (2...3).contains(word.count)
            && word.contains(where: \.isLetter)
            && word.allSatisfy { $0.isNumber || $0.isUppercase }
    }

    /// Bewertet, wie gut einzelne Begriffe im Text vorkommen. Jeder Begriff
    /// zählt für sich, auch einer aus mehreren Wörtern.
    static func match(terms: [String], in haystack: String) -> (Double, [String]) {
        match(entries: terms.map { Entry(phrase: $0) }, in: haystack)
    }

    /// Bewertet, wie gut die Einträge eines Interesses im Text vorkommen.
    ///
    /// Ein Eintrag aus mehreren Wörtern trifft mit dem ganzen Ausdruck oder
    /// mit mindestens zwei seiner tragenden Wörter. Eines allein reicht
    /// nicht: bei „Lokale KI-Modelle“ ist nicht jede Stelle über Modelle
    /// gemeint. Hat der Ausdruck nur ein tragendes Wort („Die Bahn“), zählt
    /// dieses allein.
    ///
    /// Ein Mehrworttreffer zählt mehr als ein Einzelwort, und mehrere
    /// verschiedene Treffer zählen mehr als derselbe Begriff zehnmal —
    /// sonst gewinnt ein Text, der ein Wort ständig wiederholt.
    static func match(entries: [Entry], in haystack: String) -> (Double, [String]) {
        var matched: [String] = []
        var display: [String: String] = [:]
        var value = 0.0

        func count(_ term: String, _ weight: Double, from entry: Entry) {
            guard !matched.contains(term) else { return }
            matched.append(term)
            display[term] = entry.display[term] ?? term
            value += weight
        }

        let padded = " " + haystack + " "
        for entry in entries {
            let phraseHit = occurs(entry.phrase, in: padded)
            guard !entry.words.isEmpty else {
                // Mehrwortbegriffe sind spezifischer und wiegen schwerer.
                if phraseHit { count(entry.phrase, entry.phrase.contains(" ") ? 0.5 : 0.2, from: entry) }
                continue
            }
            if phraseHit { count(entry.phrase, 0.5, from: entry) }
            let wordHits = entry.words.filter { occurs($0, in: padded) }
            guard phraseHit || wordHits.count >= 2 || entry.words.count == 1 else { continue }
            for word in wordHits { count(word, 0.2, from: entry) }
        }
        guard !matched.isEmpty else { return (0, []) }

        // Sättigung: der zehnte Treffer macht einen Abschnitt nicht zehnmal
        // relevanter. Längere Begriffe zuerst, bei gleicher Länge
        // alphabetisch, damit die Begründung von Lauf zu Lauf gleich bleibt.
        let ordered = matched.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        return (min(1.0, value), ordered.map { display[$0] ?? $0 })
    }

    /// Kommt der Begriff an einer Wortgrenze vor?
    ///
    /// Kurze Begriffe (KI, AI, ML) nur als ganzes Wort, sonst trifft „ki“ in
    /// „Kinder“ und „Skigebiet“. Längere am Wortanfang, damit „datenschutz“
    /// auch „Datenschutzbeauftragte“ findet, aber „führung“ nicht
    /// „Einführung“. `padded` ist der normalisierte Text mit Leerzeichen an
    /// beiden Enden.
    static func occurs(_ term: String, in padded: String) -> Bool {
        if term.count <= 3 { return padded.contains(" \(term) ") }
        return padded.contains(" \(term)")
    }

    /// Kleinschreibung; alles, was kein Buchstabe und keine Ziffer ist, wird
    /// zu einem Leerzeichen.
    ///
    /// Das ist kein Detail: wer „KI Modelle“ einträgt, erwartet einen Treffer
    /// auf „KI-Modelle“, und ein Punkt am Satzende darf ein Wort nicht
    /// unauffindbar machen. Umlaute bleiben erhalten — „ä“ auf „a“ zu falten
    /// würde im Deutschen mehr falsche Treffer erzeugen als richtige.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        var result = ""
        result.reserveCapacity(lowered.count)
        var lastWasSpace = true
        for character in lowered {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static let stopWords: Set<String> = [
        "und", "oder", "aber", "denn", "dass", "diese", "dieser", "dieses",
        "eine", "einen", "einem", "einer", "eines", "nicht", "auch", "noch",
        "beim", "durch", "gegen", "ohne", "über", "unter", "zwischen",
        "mein", "meine", "meinen", "mit", "von", "vom", "zum", "zur",
        "the", "and", "for", "with", "from", "that", "this",
        // Fragewörter und Allerweltsverben aus offenen Fragen und Vorhaben.
        // Sonst trifft „Welche Möglichkeiten bietet …“ jeden zweiten Satz.
        "welche", "welcher", "welches", "warum", "wieso", "weshalb", "wann", "womit", "woher",
        "bietet", "bieten", "gibt", "geben", "kann", "können", "könnte", "soll", "sollte", "sollen",
        "muss", "müssen", "wird", "werden", "wurde", "sind", "haben", "hat", "machen", "macht",
        "gerade", "heute", "mehr", "sehr", "viele", "vielen", "etwas", "alles", "immer", "wirklich",
        "aktuell", "beschäftige", "beschäftigen", "möglichkeiten", "frage", "fragen", "thema", "themen",
        "what", "which", "when", "does", "about", "have", "will", "would", "should", "could",
    ]
}
