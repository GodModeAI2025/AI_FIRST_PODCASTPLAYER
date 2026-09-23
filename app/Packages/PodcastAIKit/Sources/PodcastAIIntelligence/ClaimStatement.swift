//
//  ClaimStatement.swift
//  PodcastAIIntelligence
//
//  Wann ein Satz des Modells als Aussage stehen darf.
//
//  Bis Version 0.7 bat die App das Modell um Zeilen im Format
//  „<Nummer> | <Aussage>“. Das Gerätemodell schrieb sie manchmal in eine
//  Zeile, und aus „1 | A. 2 | B. 3 | C.“ wurde ein einziger Fakt mit den
//  Nummern mitten im Text. Solche Fakten liegen noch in manchen
//  Bibliotheken. Jetzt liefert das Modell Nummer und Aussage in getrennten
//  Feldern und sieht die Schreibweise mit Strich nicht mehr. Die Prüfung
//  hier bleibt trotzdem: Was nach Liste aussieht, ist keine Aussage.
//
//  Ohne FoundationModels, damit die App auch alte Fakten prüfen kann und
//  die Regeln auf jeder Plattform testbar sind.
//

import Foundation
import NaturalLanguage
import PodcastAICore

public enum ClaimStatement {

    /// So lang darf eine Aussage höchstens sein, in Zeichen.
    public static let characterLimit = 400

    /// Striche, die ein Modell als Trenner einer nummerierten Liste
    /// schreibt. Neben dem gewöhnlichen auch die, die gleich aussehen.
    static let separators: Set<Character> = ["|", "\u{FF5C}", "\u{00A6}", "\u{2502}", "\u{2503}", "\u{2223}", "\u{01C0}", "\u{FE31}"]

    /// Trägt der Text Reste einer nummerierten Liste aus dem Prompt?
    ///
    /// Ja bei einem Trennstrich wie in „2 | Ich habe …“ und bei einer
    /// Verweisklammer wie „[3]“ oder „[3, 5]“. Eine Aussage verweist auf
    /// nichts, das macht der Beleg, an dem sie hängt.
    public static func hasListMarkers(_ text: String) -> Bool {
        text.contains { separators.contains($0) }
            || text.contains(/\[\s*\d{1,3}(\s*[,;\-\u{2013}]\s*\d{1,3})*\s*\]/)
    }

    /// Eine Aussage, wie sie als Fakt stehen darf, oder `nil`.
    ///
    /// Eine Nummer, die das Modell der Aussage voranstellt („3 | …“, „[3] …“),
    /// und Verweise am Ende („… [3].“) fallen weg. Steht danach noch eine
    /// Listenmarke im Text, hängen mehrere Aussagen aneinander: verworfen,
    /// nicht zerteilt, denn die Teile gehörten zu anderen Belegen.
    ///
    /// Sonst ist eine Aussage ein Satz, höchstens zwei, mit mindestens drei
    /// Wörtern und höchstens ``characterLimit`` Zeichen. Was länger ist, wird
    /// verworfen statt abgeschnitten. Endet sie mit Auslassungspunkten, hat
    /// das Modell einen gekürzten Abschnitt abgeschrieben, und auch das ist
    /// keine Aussage.
    public static func validated(_ raw: String) -> String? {
        var cleaned = EvidenceSelectionValidator.sanitize(raw, limit: Int.max)
        cleaned = strippingLeadingNumber(cleaned)
        cleaned = strippingTrailingCitations(cleaned)
        guard !cleaned.isEmpty, cleaned.count <= characterLimit, !hasListMarkers(cleaned) else { return nil }
        guard !cleaned.hasSuffix("…"), !cleaned.hasSuffix("...") else { return nil }
        let words = cleaned.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3, words.contains(where: { $0.contains(where: \.isLetter) }) else { return nil }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = cleaned
        guard tokenizer.tokens(for: cleaned.startIndex..<cleaned.endIndex).count <= 2 else { return nil }
        return cleaned
    }

    /// „3 | Aussage“ oder „[3] Aussage“ → „Aussage“. Nur am Anfang.
    static func strippingLeadingNumber(_ text: String) -> String {
        guard let match = text.prefixMatch(of: /\s*(?:\[\s*\d{1,3}\s*\]|\d{1,3}[ \t]*[|\u{FF5C}\u{00A6}\u{2502}\u{2223}])[ \t]*/)
        else { return text }
        return String(text[match.range.upperBound...])
    }

    /// „Aussage [3].“ oder „Aussage [3, 5]“ → „Aussage.“ Nur am Ende.
    static func strippingTrailingCitations(_ text: String) -> String {
        var result = text
        let citation = /[ \t]*\[\s*\d{1,3}(?:\s*[,;\-\u{2013}]\s*\d{1,3})*\s*\](?<end>[.!?]?)[ \t]*$/
        while let match = result.firstMatch(of: citation) {
            let end = String(match.output.end)
            result = String(result[..<match.range.lowerBound]) + end
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

public extension EpisodeFact {

    /// Ein Fakt aus einem Lauf vor Version 0.7, in dem mehrere Aussagen samt
    /// Nummern aneinanderhängen, etwa „… beschäftigen. 2 | Ich habe …“. Die
    /// App zeigt ihn nicht, und die Folge bekommt neue Fakten.
    var hasListArtifacts: Bool {
        ClaimStatement.hasListMarkers(statement)
    }
}
