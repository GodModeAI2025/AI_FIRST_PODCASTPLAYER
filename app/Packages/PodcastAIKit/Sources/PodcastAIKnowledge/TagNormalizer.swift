//
//  TagNormalizer.swift
//  PodcastAIKnowledge
//
//  Macht aus einer Schreibweise den Schlüssel eines Tags. Unter dem
//  Schlüssel fallen Varianten zusammen, damit die Wolke nicht explodiert:
//
//  - Groß und klein, Umlaute und Akzente zählen nicht, „ß“ gilt als „ss“.
//  - Leerzeichen und Satzzeichen zählen nicht: „iOS 27“, „iOS-27“ und
//    „ios27“ sind ein Tag.
//  - Jedes Wort steht in seiner Grundform (Lemma über `NLTagger`), zuerst
//    deutsch, dann englisch: „Batterien“ ist „Batterie“, „Podcasts“ ist
//    „Podcast“. Kennt NaturalLanguage kein Lemma, bleibt das Wort.
//  - Länder werden zu `region:` und ihrer ISO-Kennung. Die Namen kommen aus
//    `Locale` auf Deutsch und Englisch, dazu eine kleine feste Liste für
//    Kürzel wie „USA“ und „UK“ und für die EU, die keine Region im Sinne
//    von `Locale.Region.isoRegions(ofCategory: .territory)` ist.
//
//  Alles Übrige, etwa „KI“ und „künstliche Intelligenz“, verbinden Aliasse
//  (`StoredInterest.keywords`). Das legt der Code nicht selbst fest.
//
//  Der Schlüssel wird einmal berechnet und gespeichert. Hat ein anderes
//  Gerät kein Lemma für eine Sprache, rechnet es den gespeicherten
//  Schlüssel nicht neu aus, sonst wechselte er bei jedem Abgleich.
//

import Foundation
import NaturalLanguage
import PodcastAICore

public enum TagNormalizer {

    /// Vorsilbe der Schlüssel für Länder und Staatenbünde.
    public static let regionPrefix = "region:"

    /// Der Schlüssel zu einer Schreibweise. Leer, wenn nichts übrig bleibt.
    ///
    /// - Parameter language: Sprache, deren Lemma zuerst gilt. Ohne Angabe
    ///   zuerst Deutsch, dann Englisch.
    public static func key(for label: String, language: NLLanguage? = nil) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Länder vor dem Lemma: aus „Vereinigte Staaten“ machte es sonst
        // „vereinigt staat“.
        if let region = regionKeys[fold(trimmed)] { return region }
        let key = lemmatizedWords(trimmed, preferred: language).map(fold).joined()
        // Gebeugte Ländernamen („den Vereinigten Staaten“ ohne Artikel)
        // treffen die Grundform der Namen.
        if let region = regionKeys[key] { return region }
        return key
    }

    /// Passt eine Schreibweise zu einem Tag, über seinen Schlüssel oder
    /// einen seiner Aliasse?
    public static func matches(_ label: String, tag: Tag) -> Bool {
        let key = key(for: label)
        guard !key.isEmpty else { return false }
        return key == tag.normalizedKey || tag.aliases.contains { self.key(for: $0) == key }
    }

    /// Das Tag zu einer Schreibweise. Der Schlüssel geht vor, danach die
    /// Aliasse. Ohne Treffer `nil`.
    public static func resolve(_ label: String, in tags: [Tag]) -> Tag? {
        let key = key(for: label)
        guard !key.isEmpty else { return nil }
        if let exact = tags.first(where: { $0.normalizedKey == key }) { return exact }
        return tags.first { tag in tag.aliases.contains { self.key(for: $0) == key } }
    }

    /// Darf aus dieser Schreibweise ein neues, erkanntes Tag entstehen?
    ///
    /// Nein bei Parteien, Wahlen, Religion und anderem, wozu die App keine
    /// Interessen ableitet (``SensitiveTopicPolicy``), bei Sätzen statt
    /// Begriffen und bei Schlüsseln unter zwei Zeichen. Was jemand selbst
    /// einträgt, prüft diese Regel nicht.
    public static func admitsDetectedTag(_ label: String) -> Bool {
        guard TopicTagger.isTagShaped(label),
              SensitiveTopicPolicy.allowsInterestDerivation(from: label) else { return false }
        return key(for: label).count >= 2
    }

    /// Ein neues Tag aus dem Inhalt, neutral, mit Kennung aus dem Schlüssel.
    /// `nil`, wenn ``admitsDetectedTag(_:)`` es nicht erlaubt.
    public static func makeDetectedTag(label: String, seenAt: Date = Date()) -> Tag? {
        guard admitsDetectedTag(label) else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key(for: trimmed)
        return Tag(id: Tag.stableID(forKey: key), label: trimmed, normalizedKey: key,
                   stance: .neutral, origin: .detected, aliases: [], firstSeenAt: seenAt)
    }

    // MARK: - Falten

    /// Kleinbuchstaben ohne Akzente, „ß“ als „ss“, nur Buchstaben und Ziffern.
    static func fold(_ text: String) -> String {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "ß", with: "ss")
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }))
    }

    // MARK: - Lemma

    /// Wörter, deren Lemma ein anderes Thema wäre. „Daten“ hat im Deutschen
    /// das Lemma „Datum“.
    static let keptAsWritten: Set<String> = ["daten"]

    /// Sprachen, für die dieses Gerät Lemmata kennt, in der Reihenfolge,
    /// in der sie gefragt werden.
    public static let lemmaLanguages: [NLLanguage] = [.german, .english].filter {
        NLTagger.availableTagSchemes(for: .word, language: $0).contains(.lemma)
    }

    /// Kennt dieses Gerät Lemmata für Deutsch oder Englisch?
    public static var lemmaAvailable: Bool { !lemmaLanguages.isEmpty }

    /// Die Wörter einer Schreibweise, jedes in seiner Grundform, soweit
    /// bekannt. Wörter mit Ziffern bleiben, wie sie sind.
    static func lemmatizedWords(_ text: String, preferred: NLLanguage?) -> [String] {
        lemmatizedWords(ofLines: [text], preferred: preferred).first ?? []
    }

    /// Wie ``lemmatizedWords(_:preferred:)`` für viele Zeilen auf einmal.
    /// Ein Tagger je Sprache für alle Zeilen: Für die Ländernamen wären es
    /// sonst über tausend, und das dauerte Sekunden.
    static func lemmatizedWords(ofLines lines: [String], preferred: NLLanguage?) -> [[String]] {
        var languages = lemmaLanguages
        if let preferred, let index = languages.firstIndex(of: preferred) {
            languages.remove(at: index)
            languages.insert(preferred, at: 0)
        }
        let cleaned = lines.map { $0.replacingOccurrences(of: "\n", with: " ") }
        let text = cleaned.joined(separator: "\n")
        let whole = text.startIndex..<text.endIndex
        // Je Sprache ein eigener Tagger. Einer für alle ginge nicht: die
        // Sprache gilt für den ganzen Text.
        let taggers: [NLTagger] = languages.map { language in
            let tagger = NLTagger(tagSchemes: [.lemma])
            tagger.string = text
            tagger.setLanguage(language, range: whole)
            return tagger
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text

        var result: [[String]] = []
        var lineStart = text.startIndex
        for line in cleaned {
            let lineEnd = text.index(lineStart, offsetBy: line.count)
            var words: [String] = []
            tokenizer.enumerateTokens(in: lineStart..<lineEnd) { range, _ in
                let word = String(text[range])
                words.append(lemma(of: word, at: range, taggers: taggers) ?? word)
                return true
            }
            result.append(words)
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
        }
        return result
    }

    private static func lemma(of word: String, at range: Range<String.Index>, taggers: [NLTagger]) -> String? {
        guard word.allSatisfy(\.isLetter), !keptAsWritten.contains(fold(word)) else { return nil }
        let length = fold(word).count
        for tagger in taggers {
            let (tag, tagRange) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma)
            // Eine Grundform ist nie länger als das Wort. Klein geschrieben
            // hält das Deutsche ein Wort oft für ein Verb: „email“ wird dann
            // zu „emailen“. Solche Lemmata bleiben außen vor.
            if tagRange == range, let lemma = tag?.rawValue, !lemma.isEmpty, fold(lemma).count <= length {
                return lemma
            }
        }
        return nil
    }

    // MARK: - Länder

    /// Kürzel und Namen, die `Locale` nicht liefert oder anders schreibt.
    static let fixedRegionAliases: [String: String] = [
        "usa": "US", "vereinigtestaatenvonamerika": "US",
        "unitedstatesofamerica": "US", "us": "US",
        "uk": "GB", "grossbritannien": "GB", "greatbritain": "GB", "britain": "GB",
        "vereinigteskonigreich": "GB", "unitedkingdom": "GB",
        "eu": "EU", "europaischeunion": "EU", "europeanunion": "EU",
        "brd": "DE", "bundesrepublikdeutschland": "DE",
    ]

    /// Ländernamen, die in der anderen Sprache ein gewöhnliches Wort sind.
    /// „Island“ heißt auf Deutsch das Land, auf Englisch eine Insel.
    static let ambiguousRegionNames: Set<String> = ["island"]

    /// Gefaltete Namen aller Länder auf Deutsch und Englisch, auch in der
    /// Grundform ihrer Wörter, dazu die feste Liste.
    static let regionKeys: [String: String] = {
        var names: [(name: String, code: String)] = []
        let locales = [Locale(identifier: "de"), Locale(identifier: "en")]
        for region in Locale.Region.isoRegions(ofCategory: .territory) {
            for locale in locales {
                guard let name = locale.localizedString(forRegionCode: region.identifier) else { continue }
                names.append((name, region.identifier))
            }
        }
        let lemmatized = lemmatizedWords(ofLines: names.map(\.name), preferred: nil)
        var table: [String: String] = [:]
        for (index, entry) in names.enumerated() {
            for form in [fold(entry.name), lemmatized[index].map(fold).joined()]
            where !form.isEmpty && !ambiguousRegionNames.contains(form) && table[form] == nil {
                table[form] = regionPrefix + entry.code
            }
        }
        for (alias, code) in fixedRegionAliases { table[alias] = regionPrefix + code }
        return table
    }()
}
