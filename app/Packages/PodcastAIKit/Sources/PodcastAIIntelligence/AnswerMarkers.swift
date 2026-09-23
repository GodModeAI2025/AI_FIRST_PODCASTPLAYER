//
//  AnswerMarkers.swift
//  PodcastAIIntelligence
//
//  Verweise und Sätze in einem Antworttext.
//
//  Der Extraktor liest aus dem Text, auf welche Belege er verweist. Die
//  Oberfläche macht aus denselben Klammern Links und gliedert die Antwort
//  in Sätze. Beide lesen die Klammern mit denselben Regeln. Las die
//  Anzeige „[2 - 4]“ als 2 und 4, stand Beleg 3 in der Liste, aber kein
//  Verweis im Text zeigte auf ihn.
//
//  Ohne FoundationModels, damit die App die Regeln auf jeder Plattform
//  nutzt und sie testbar sind.
//

import Foundation
import NaturalLanguage

public enum AnswerMarkers {

    /// Größter Bereich, der ausgeschrieben wird. Alles darüber ist eher ein
    /// Tippfehler als ein Verweis; dann zählen nur die beiden Enden.
    static let maximumCitationRange = 10

    private enum Token { case number(Int), dash }

    /// Die Nummern in einer Verweisklammer, ohne die Klammern selbst.
    ///
    /// „3“, „3, 5“, „3 5“, „2-4“ und „2 – 4“ sind Verweise. Komma, Semikolon
    /// und Leerraum trennen, ein Bindestrich steht für einen Bereich, auch
    /// mit Leerzeichen daneben. Steht etwas anderes darin, etwa „Musik“ oder
    /// „00:12“, ist die Klammer kein Verweis und das Ergebnis leer.
    public static func numbers(inBrackets content: some StringProtocol) -> [Int] {
        var tokens: [Token] = []
        var digits = ""
        func flush() {
            if !digits.isEmpty, let number = Int(digits) { tokens.append(.number(number)) }
            digits = ""
        }
        for character in content {
            if character.isASCII, character.isWholeNumber {
                digits.append(character)
            } else if character == "-" || character == "\u{2013}" {
                flush()
                tokens.append(.dash)
            } else if character == "," || character == ";" || character.isWhitespace {
                flush()
            } else {
                return []
            }
        }
        flush()

        var numbers: [Int] = []
        var position = 0
        while position < tokens.count {
            guard case .number(let first) = tokens[position] else { position += 1; continue }
            if position + 2 < tokens.count,
               case .dash = tokens[position + 1],
               case .number(let last) = tokens[position + 2] {
                if first < last, last - first <= maximumCitationRange {
                    numbers += Array(first...last)
                } else {
                    numbers += [first, last]
                }
                position += 3
            } else {
                numbers.append(first)
                position += 1
            }
        }
        return numbers
    }

    /// Die Sätze eines Antworttextes, in der Sprache des Textes getrennt.
    ///
    /// Ein Verweis hinter dem Punkt gehört zum Satz davor, und „am 12. Sept.“
    /// beendet keinen Satz. Ebenso wenig ein Titel vor einem Namen: aus
    /// „Laut Prof. Weber …“ wurde sonst „Laut Prof.“ als eigener Satz, und
    /// der Name rutschte in den nächsten.
    public static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }
            if !result.isEmpty {
                let (markers, remainder) = leadingMarkers(sentence)
                if !markers.isEmpty {
                    result[result.count - 1] += " " + markers
                    sentence = remainder
                    if sentence.isEmpty { return true }
                }
            }
            if let last = result.last, isFragment(sentence, after: last) {
                result[result.count - 1] = last + " " + sentence
            } else {
                result.append(sentence)
            }
            return true
        }
        return result.isEmpty ? [text] : result
    }

    /// Anreden und Titel vor einem Namen. Die Satzerkennung kennt nicht
    /// alle. Gezählt werden sie nur großgeschrieben: „20 ms.“ am Satzende
    /// ist eine Einheit, „Ms. Lee“ eine Anrede.
    static let titles: Set<String> = [
        "prof", "dr", "dipl", "ing", "mag", "hr", "hrn", "fr", "st", "mr", "mrs", "ms",
    ]

    private static func isFragment(_ sentence: String, after previous: String) -> Bool {
        guard let first = sentence.first else { return true }
        if first.isLowercase || first.isNumber { return true }
        if previous.hasSuffix("."), let digit = previous.dropLast().last, digit.isNumber { return true }
        if previous.hasSuffix("."), let word = previous.split(whereSeparator: \.isWhitespace).last {
            let title = word.dropLast().drop { !$0.isLetter }
            if title.first?.isUppercase == true, titles.contains(title.lowercased()) { return true }
        }
        return sentence.count < 6
    }

    private static func leadingMarkers(_ sentence: String) -> (markers: String, rest: String) {
        var rest = Substring(sentence)
        var markers: [String] = []
        while rest.hasPrefix("["), let close = rest.firstIndex(of: "]"),
              !numbers(inBrackets: rest[rest.index(after: rest.startIndex)..<close]).isEmpty {
            markers.append(String(rest[...close]))
            rest = rest[rest.index(after: close)...].drop(while: \.isWhitespace)
        }
        return (markers.joined(separator: " "), String(rest))
    }
}
