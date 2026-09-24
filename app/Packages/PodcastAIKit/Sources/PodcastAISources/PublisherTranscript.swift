//
//  PublisherTranscript.swift
//  PodcastAISources
//
//  Transkripte, die der Podcast selbst liefert (`podcast:transcript`), in
//  den Formaten WebVTT, SRT und JSON nach Podcasting 2.0. Mit ihnen braucht
//  die Folge keine eigene Spracherkennung.
//
//  Der Inhalt ist fremder Text. Gelesen werden nur Zeitmarken, Sprecher und
//  Wortlaut, und die Zeiten prüft der Code: aufsteigend, nicht negativ,
//  mit Ende nach dem Anfang.
//

import Foundation
import PodcastAICore

public enum PublisherTranscript {

    /// Ein Stück Text mit Zeitbereich, noch ohne Bezug auf eine Fassung.
    public struct Cue: Hashable, Sendable {
        public let range: MediaTimeRange
        public let text: String
        public let speaker: String?

        public init(range: MediaTimeRange, text: String, speaker: String? = nil) {
            self.range = range; self.text = text; self.speaker = speaker
        }
    }

    public enum Format: Sendable, Equatable {
        case webVTT, srt, json
    }

    public enum ParseError: Error, Equatable {
        case unknownFormat
        case noCues
    }

    /// Höchstens so viele Stücke aus einer Datei.
    public static let maximumCues = 50_000

    /// Erkennt das Format am Inhalt, nicht an der Angabe im Feed. Viele
    /// Anbieter liefern `text/plain` für eine VTT-Datei.
    public static func format(of text: String) -> Format? {
        let head = text.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        if head.hasPrefix("WEBVTT") { return .webVTT }
        if head.hasPrefix("{") || head.hasPrefix("[") { return .json }
        if text.contains("-->") { return .srt }
        return nil
    }

    /// Liest eine Transkriptdatei. Kurze Stücke eines Sprechers werden zu
    /// Sätzen zusammengefasst, damit ein Beleg einen Gedanken trägt.
    public static func parse(_ data: Data) throws -> [Cue] {
        let text = String(decoding: data, as: UTF8.self)
        let cues: [Cue]
        switch format(of: text) {
        case .webVTT: cues = parseTimedText(text, isVTT: true)
        case .srt: cues = parseTimedText(text, isVTT: false)
        case .json: cues = try parseJSON(data)
        case nil: throw ParseError.unknownFormat
        }
        let merged = mergeIntoSentences(cues)
        guard !merged.isEmpty else { throw ParseError.noCues }
        return merged
    }

    // MARK: VTT und SRT

    /// VTT und SRT unterscheiden sich kaum: Blöcke durch Leerzeilen getrennt,
    /// eine Zeile mit `-->`, darunter der Text. SRT trennt Millisekunden mit
    /// Komma, VTT mit Punkt. VTT kennt zusätzlich NOTE-, STYLE- und
    /// REGION-Blöcke sowie Stimmen-Tags `<v Name>`.
    static func parseTimedText(_ text: String, isVTT: Bool) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            if isVTT, let first = lines.first,
               first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION") { continue }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = timestamp(timing[0]),
                  let end = timestamp(timing[1].split(separator: " ", omittingEmptySubsequences: true)
                    .first.map(String.init) ?? "") else { continue }
            var speaker: String?
            var parts: [String] = []
            for line in lines[(timingIndex + 1)...] {
                if isVTT, speaker == nil, let voice = voiceName(in: line) { speaker = voice }
                let clean = stripTags(line)
                if !clean.isEmpty { parts.append(clean) }
            }
            let body = parts.joined(separator: " ")
            guard !body.isEmpty, end > start else { continue }
            cues.append(Cue(range: MediaTimeRange(start: start, end: end), text: body, speaker: speaker))
            if cues.count >= maximumCues { break }
        }
        return cues.sorted { $0.range < $1.range }
    }

    /// `00:01:02.345`, `01:02.345` (VTT) oder `00:01:02,345` (SRT).
    static func timestamp(_ raw: String) -> MediaTime? {
        let value = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var seconds = 0.0
        for (index, part) in parts.enumerated() {
            guard let number = Double(part), number >= 0 else { return nil }
            if index > 0, number >= 60 { return nil }
            seconds = seconds * 60 + number
        }
        return MediaTime(milliseconds: Int64((seconds * 1000).rounded()))
    }

    /// Der Name aus `<v Name>` oder `<v.klasse Name>`.
    static func voiceName(in line: String) -> String? {
        guard let open = line.range(of: "<v"), let close = line[open.upperBound...].firstIndex(of: ">") else {
            return nil
        }
        let inner = line[open.upperBound..<close]
        guard let space = inner.firstIndex(of: " ") else { return nil }
        let name = inner[space...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : String(name.prefix(80))
    }

    static func stripTags(_ line: String) -> String {
        var result = line.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: JSON

    /// `{"version": "1.0.0", "segments": [{"speaker", "startTime", "endTime", "body"}]}`
    static func parseJSON(_ data: Data) throws -> [Cue] {
        let file = try JSONDecoder().decode(JSONFile.self, from: data)
        return file.segments.prefix(maximumCues).compactMap { entry -> Cue? in
            let body = (entry.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, entry.startTime >= 0, entry.endTime > entry.startTime else { return nil }
            let speaker = entry.speaker?.trimmingCharacters(in: .whitespaces)
            return Cue(
                range: MediaTimeRange(
                    start: MediaTime(milliseconds: Int64((entry.startTime * 1000).rounded())),
                    end: MediaTime(milliseconds: Int64((entry.endTime * 1000).rounded()))),
                text: body,
                speaker: speaker?.isEmpty == false ? String(speaker!.prefix(80)) : nil)
        }
        .sorted { $0.range < $1.range }
    }

    private struct JSONFile: Decodable {
        let segments: [Entry]
        struct Entry: Decodable {
            let speaker: String?
            let startTime: Double
            let endTime: Double
            let body: String?
        }
    }

    // MARK: Zusammenfassen

    /// Viele Dateien liefern Stücke von zwei, drei Wörtern. Aufeinander
    /// folgende Stücke desselben Sprechers werden verbunden, bis ein Satz
    /// endet oder 20 Sekunden erreicht sind.
    static func mergeIntoSentences(_ cues: [Cue], maximumLength: Int64 = 20_000) -> [Cue] {
        var result: [Cue] = []
        var current: Cue?
        for cue in cues {
            guard let open = current else { current = cue; continue }
            let sameSpeaker = open.speaker == cue.speaker
            let endsSentence = open.text.last.map { ".!?…".contains($0) } ?? false
            let length = cue.range.end.milliseconds - open.range.start.milliseconds
            if sameSpeaker, !endsSentence, length <= maximumLength, cue.range.start >= open.range.start {
                current = Cue(range: MediaTimeRange(start: open.range.start, end: max(open.range.end, cue.range.end)),
                              text: open.text + " " + cue.text, speaker: open.speaker)
            } else {
                result.append(open)
                current = cue
            }
        }
        if let current { result.append(current) }
        return result
    }
}
