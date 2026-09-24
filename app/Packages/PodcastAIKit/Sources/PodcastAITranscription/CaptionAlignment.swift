//
//  CaptionAlignment.swift
//  PodcastAITranscription
//
//  Legt Untertitel eines Videos auf die Zeit einer Audiodatei.
//
//  Dieselbe Folge gibt es oft als MP3 im Feed und als Video auf YouTube.
//  Die Untertitel des Videos wären ein fertiges Transkript, aber ihre Zeiten
//  gelten für das Video: ein längeres Intro, eingefügte Werbung im MP3 oder
//  ein Stück, das nur im Video steht, verschieben alles danach. Zitate und
//  Wiedergabe laufen über die Zeit der Audiodatei, also darf nichts
//  ungeprüft übernommen werden.
//
//  Der Weg:
//
//  1. Ein paar kurze Stücke der Audiodatei transkribiert das Gerät selbst.
//  2. Je Stück sucht `match` die Stelle in den Untertiteln: gleiche
//     Dreiergruppen von Wörtern stimmen über den Versatz ab (Zeit im Ton
//     minus Zeit im Video). Gilt nur, wenn viele Gruppen denselben Versatz
//     tragen, genug Wörter übereinstimmen und kein zweiter Versatz fast so
//     viele Stimmen hat.
//  3. `mapping` prüft die Anker gemeinsam: mindestens zwei, in derselben
//     Reihenfolge in Ton und Video, keiner absurd weit verschoben. Zwischen
//     zwei Ankern mit verschiedenem Versatz wird linear übergeleitet; ist
//     diese Strecke zu lang, gilt die Zuordnung nicht.
//  4. `shift` legt jede Untertitelzeile auf die Zeit des Tons.
//
//  Scheitert ein Schritt, gibt es kein Ergebnis und die App transkribiert
//  den ganzen Ton selbst. Geraten wird nichts.
//
//  Ohne Apple-Frameworks und ohne Netz, also prüfbar.
//

import Foundation
import PodcastAICore

/// Ein Wort mit seiner Zeit in Millisekunden.
public struct AlignmentWord: Hashable, Sendable {
    public let token: String
    public let time: Int64

    public init(token: String, time: Int64) {
        self.token = token
        self.time = time
    }
}

/// Ein Ankerpunkt: an dieser Stelle im Ton liegt der Inhalt um `offset`
/// Millisekunden später als im Video. Negativ heißt früher.
public struct AlignmentAnchor: Hashable, Sendable, Codable {
    public let audioTime: Int64
    public let offset: Int64

    public init(audioTime: Int64, offset: Int64) {
        self.audioTime = audioTime
        self.offset = offset
    }

    /// Dieselbe Stelle in der Zeit des Videos.
    public var captionTime: Int64 { audioTime - offset }
}

/// Die geprüfte Zuordnung von Videozeit zu Tonzeit.
public struct CaptionTimeMapping: Equatable, Sendable {
    /// Aufsteigend, in Ton- und Videozeit gleich geordnet.
    public let anchors: [AlignmentAnchor]

    /// Überall derselbe Versatz?
    public var isConstant: Bool { Set(anchors.map(\.offset)).count <= 1 }

    /// Die Zeit im Ton für eine Zeit im Video. Vor dem ersten und nach dem
    /// letzten Anker gilt deren Versatz, dazwischen wird linear übergeleitet.
    public func audioTime(forCaption caption: Int64) -> Int64 {
        guard let first = anchors.first, let last = anchors.last else { return caption }
        if caption <= first.captionTime { return caption + first.offset }
        if caption >= last.captionTime { return caption + last.offset }
        for (lower, upper) in zip(anchors, anchors.dropFirst()) where caption < upper.captionTime {
            let span = upper.captionTime - lower.captionTime
            guard span > 0 else { return caption + upper.offset }
            let fraction = Double(caption - lower.captionTime) / Double(span)
            let offset = Double(lower.offset) + Double(upper.offset - lower.offset) * fraction
            return caption + Int64(offset.rounded())
        }
        return caption + last.offset
    }
}

public enum CaptionAlignment {

    public struct Parameters: Sendable {
        /// Länge der Wortgruppen, die abstimmen.
        public var ngram = 3
        /// Stimmen innerhalb dieser Breite zählen als derselbe Versatz.
        public var clusterWidth: Int64 = 1_500
        /// Gruppen, die öfter in den Untertiteln stehen, sagen nichts über die Stelle.
        public var maxNgramOccurrences = 20
        /// Weniger erkannte Wörter in einem Stück: Musik, Stille oder Werbung.
        public var minWindowWords = 20
        /// So viele Gruppen müssen denselben Versatz tragen.
        public var minSupportingNgrams = 8
        /// Und dieser Anteil aller Gruppen des Stücks.
        public var minNgramShare = 0.25
        /// Anteil der Wörter des Stücks, die an der gefundenen Stelle der
        /// Untertitel stehen. Beides ist Spracherkennung, ganz gleich wird es nie.
        public var minWordOverlap = 0.5
        /// Der beste Versatz braucht mindestens so viele Stimmen mal den zweitbesten.
        public var minClusterDominance = 2.0
        /// Die stützenden Gruppen müssen so viel des Stücks abdecken, nicht
        /// nur einen wiederholten Satz.
        public var minSupportSpread = 0.4
        /// Anker, deren Versatz höchstens so weit auseinanderliegt, gelten als gleich.
        public var sameOffsetTolerance: Int64 = 2_000
        /// Mehr Versatz hat dieselbe Folge nicht.
        public var maxOffset: Int64 = 20 * 60_000
        /// Höchstens so viele Wechsel des Versatzes, etwa Werbeblöcke.
        public var maxSteps = 3
        /// Zwischen zwei Ankern mit verschiedenem Versatz wird linear
        /// übergeleitet. Weiter als so auseinander gilt das nicht mehr: dort
        /// lägen Zitate um bis zu die Hälfte des Wechsels daneben.
        public var maxStepSpan: Int64 = 4 * 60_000
        /// Bis zu dieser Strecke lohnt kein weiteres Stück zum Eingrenzen.
        public var refineUntil: Int64 = 3 * 60_000
        /// Höchstens dieser Anteil der Zeilen darf außerhalb des Tons landen.
        public var maxOutsideShare = 0.1

        public init() {}
    }

    // MARK: Wörter

    /// Wörter zum Vergleichen: klein, ohne Akzente und Satzzeichen, ohne
    /// Einzelzeichen. Dieselbe Regel für Ton und Untertitel.
    public static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
    }

    /// Die Wörter eines Textstücks mit Zeiten, gleichmäßig über seinen
    /// Zeitbereich verteilt. Genauer liefern weder Untertitel noch Ergebnisse
    /// der Erkennung ihre Zeiten; die Abstimmung vieler Gruppen gleicht es aus.
    public static func words(text: String, start: Int64, end: Int64) -> [AlignmentWord] {
        let list = tokens(text)
        guard !list.isEmpty else { return [] }
        let span = max(0, end - start)
        return list.enumerated().map { index, token in
            AlignmentWord(token: token, time: start + span * Int64(index) / Int64(list.count))
        }
    }

    /// Die Wörter der Untertitel, gereinigt wie für das Transkript.
    public static func words(cues: [CaptionCue]) -> [AlignmentWord] {
        cues.sorted { $0.start < $1.start }.flatMap { cue in
            words(text: CaptionText.clean(cue.text), start: cue.start.milliseconds,
                  end: cue.start.milliseconds + cue.duration.milliseconds)
        }
    }

    // MARK: Ein Stück

    /// Wo ein Stück des Tons in den Untertiteln steht.
    public struct WindowMatch: Equatable, Sendable {
        public let windowStart: Int64
        public let windowEnd: Int64
        /// Zeit im Ton minus Zeit im Video.
        public let offset: Int64
        public let supportingNgrams: Int
        public let ngramShare: Double
        public let wordOverlap: Double

        public var anchor: AlignmentAnchor {
            AlignmentAnchor(audioTime: (windowStart + windowEnd) / 2, offset: offset)
        }
    }

    /// Sucht die Stelle eines Stücks in den Untertiteln. `nil`, wenn sie
    /// sich nicht eindeutig und mit genug Übereinstimmung finden lässt.
    public static func match(
        window: [AlignmentWord], captions: [AlignmentWord], parameters: Parameters = Parameters()
    ) -> WindowMatch? {
        let size = parameters.ngram
        guard window.count >= max(parameters.minWindowWords, size), captions.count >= size else { return nil }

        var index: [String: [Int]] = [:]
        for position in 0...(captions.count - size) {
            index[key(captions, at: position, size: size), default: []].append(position)
        }

        // Jede Gruppe des Stücks stimmt für jeden Versatz, an dem sie in den
        // Untertiteln steht.
        var votes: [(offset: Int64, group: Int)] = []
        let groups = window.count - size + 1
        for group in 0..<groups {
            guard let positions = index[key(window, at: group, size: size)],
                  positions.count <= parameters.maxNgramOccurrences else { continue }
            for position in positions {
                votes.append((window[group].time - captions[position].time, group))
            }
        }
        guard !votes.isEmpty else { return nil }
        votes.sort { $0.offset < $1.offset }

        guard let best = densestCluster(votes, width: parameters.clusterWidth, excluding: nil) else { return nil }
        let bestVotes = votes[best]
        let supporters = Set(bestVotes.map(\.group))
        let sortedOffsets = bestVotes.map(\.offset).sorted()
        let offset = sortedOffsets[sortedOffsets.count / 2]

        // Ein zweiter Versatz mit fast so vielen Stimmen: die Stelle ist nicht eindeutig.
        let excluded = (offset - 3 * parameters.clusterWidth)...(offset + 3 * parameters.clusterWidth)
        let secondCount = densestCluster(votes, width: parameters.clusterWidth, excluding: excluded)
            .map { Set(votes[$0].map(\.group)).count } ?? 0
        guard Double(supporters.count) >= parameters.minClusterDominance * Double(secondCount) else { return nil }

        let windowStart = window.first!.time
        let windowEnd = window.last!.time
        let share = Double(supporters.count) / Double(groups)
        guard supporters.count >= parameters.minSupportingNgrams, share >= parameters.minNgramShare,
              abs(offset) <= parameters.maxOffset else { return nil }

        // Die Stützen müssen sich über das Stück verteilen.
        let supportTimes = supporters.map { window[$0].time }
        let spread = (supportTimes.max() ?? 0) - (supportTimes.min() ?? 0)
        guard Double(spread) >= parameters.minSupportSpread * Double(max(1, windowEnd - windowStart)) else {
            return nil
        }

        // Wortweise: wie viele Wörter des Stücks stehen an der Stelle?
        let margin: Int64 = 2_000
        let lower = windowStart - offset - margin
        let upper = windowEnd - offset + margin
        var available: [String: Int] = [:]
        for word in captions where word.time >= lower && word.time <= upper {
            available[word.token, default: 0] += 1
        }
        var found = 0
        for word in window {
            if let count = available[word.token], count > 0 {
                available[word.token] = count - 1
                found += 1
            }
        }
        let overlap = Double(found) / Double(window.count)
        guard overlap >= parameters.minWordOverlap else { return nil }

        return WindowMatch(windowStart: windowStart, windowEnd: windowEnd, offset: offset,
                           supportingNgrams: supporters.count, ngramShare: share, wordOverlap: overlap)
    }

    private static func key(_ words: [AlignmentWord], at start: Int, size: Int) -> String {
        words[start..<(start + size)].map(\.token).joined(separator: " ")
    }

    /// Der Bereich sortierter Stimmen mit den meisten verschiedenen Gruppen
    /// innerhalb von `width`.
    private static func densestCluster(
        _ votes: [(offset: Int64, group: Int)], width: Int64, excluding: ClosedRange<Int64>?
    ) -> Range<Int>? {
        var best: (range: Range<Int>, count: Int)?
        var lower = 0
        for upper in votes.indices {
            if let excluding, excluding.contains(votes[upper].offset) { continue }
            while votes[upper].offset - votes[lower].offset > width
                    || (excluding?.contains(votes[lower].offset) ?? false) {
                lower += 1
            }
            let range = lower..<(upper + 1)
            // Meist eine Stimme je Gruppe; gezählt wird trotzdem je Gruppe.
            let count = Set(votes[range].map(\.group)).count
            if best == nil || count > best!.count { best = (range, count) }
        }
        return best?.range
    }

    // MARK: Alle Stücke zusammen

    public enum Rejection: Error, Equatable, Sendable {
        /// Weniger als zwei Stücke ließen sich zuordnen.
        case tooFewAnchors
        /// Die Stücke stehen im Video in anderer Reihenfolge als im Ton.
        case notMonotonic
        /// Ein Versatz größer als `maxOffset`.
        case offsetTooLarge
        /// Zu viele Wechsel des Versatzes.
        case tooManySteps
        /// Ein Wechsel des Versatzes lässt sich nicht genau genug eingrenzen.
        case stepTooWide
        /// Zu viele Zeilen landeten außerhalb des Tons.
        case outsideAudio
    }

    /// Prüft die Anker gemeinsam und macht daraus die Zuordnung.
    ///
    /// Liegen alle Versätze innerhalb der Toleranz, gilt überall ihr Median.
    /// Sonst bleiben die Anker, und zwischen zwei verschiedenen wird linear
    /// übergeleitet, höchstens über `maxStepSpan`.
    public static func mapping(
        from anchors: [AlignmentAnchor], parameters: Parameters = Parameters()
    ) -> Result<CaptionTimeMapping, Rejection> {
        let sorted = anchors.sorted { $0.audioTime < $1.audioTime }
        guard sorted.count >= 2 else { return .failure(.tooFewAnchors) }
        guard sorted.allSatisfy({ abs($0.offset) <= parameters.maxOffset }) else { return .failure(.offsetTooLarge) }
        for (lower, upper) in zip(sorted, sorted.dropFirst())
        where upper.audioTime <= lower.audioTime || upper.captionTime <= lower.captionTime {
            return .failure(.notMonotonic)
        }

        let offsets = sorted.map(\.offset).sorted()
        if offsets.last! - offsets.first! <= parameters.sameOffsetTolerance {
            let median = offsets[offsets.count / 2]
            return .success(CaptionTimeMapping(anchors: [
                AlignmentAnchor(audioTime: sorted.first!.audioTime, offset: median),
                AlignmentAnchor(audioTime: sorted.last!.audioTime, offset: median),
            ]))
        }

        var steps = 0
        for (lower, upper) in zip(sorted, sorted.dropFirst())
        where abs(upper.offset - lower.offset) > parameters.sameOffsetTolerance {
            steps += 1
            if upper.audioTime - lower.audioTime > parameters.maxStepSpan { return .failure(.stepTooWide) }
        }
        guard steps <= parameters.maxSteps else { return .failure(.tooManySteps) }
        return .success(CaptionTimeMapping(anchors: sorted))
    }

    /// Wo ein weiteres Stück den Wechsel des Versatzes am besten eingrenzt:
    /// in der Mitte zwischen zwei Ankern mit verschiedenem Versatz, die
    /// weiter als `refineUntil` auseinanderliegen. Fiel die Mitte schon in
    /// Werbung oder Musik, ein Viertel davor oder dahinter. `nil`, wenn
    /// nichts mehr einzugrenzen ist.
    public static func nextProbe(
        anchors: [AlignmentAnchor], failedProbes: [Int64], parameters: Parameters = Parameters()
    ) -> Int64? {
        let sorted = anchors.sorted { $0.audioTime < $1.audioTime }
        for (lower, upper) in zip(sorted, sorted.dropFirst()) {
            let span = upper.audioTime - lower.audioTime
            guard abs(upper.offset - lower.offset) > parameters.sameOffsetTolerance,
                  span > parameters.refineUntil else { continue }
            let candidates = [span / 2, span / 4, 3 * span / 4].map { lower.audioTime + $0 }
            if let free = candidates.first(where: { candidate in
                !failedProbes.contains { abs($0 - candidate) < span / 8 }
            }) {
                return free
            }
        }
        return nil
    }

    // MARK: Verschieben

    /// Legt die Zeilen auf die Zeit des Tons. Zeilen, die davor oder hinter
    /// dem Ende landen, fallen weg; sind es mehr als `maxOutsideShare`, passt
    /// die Zuordnung nicht zu dieser Datei.
    public static func shift(
        cues: [CaptionCue], by mapping: CaptionTimeMapping, audioDuration: MediaDuration?,
        parameters: Parameters = Parameters()
    ) -> Result<[CaptionCue], Rejection> {
        let spoken = cues.filter { !CaptionText.clean($0.text).isEmpty }
        guard !spoken.isEmpty else { return .success([]) }
        let tolerance: Int64 = 5_000
        let limit = audioDuration.map(\.milliseconds)
        var result: [CaptionCue] = []
        var outside = 0
        for cue in spoken {
            let start = mapping.audioTime(forCaption: cue.start.milliseconds)
            var end = mapping.audioTime(forCaption: cue.start.milliseconds + cue.duration.milliseconds)
            if start < 0 || (limit.map { start > $0 + tolerance } ?? false) {
                outside += 1
                continue
            }
            if let limit, end > limit { end = max(start, limit) }
            result.append(CaptionCue(text: cue.text, start: MediaTime(milliseconds: start),
                                     duration: MediaDuration(milliseconds: max(0, end - start))))
        }
        guard Double(outside) <= parameters.maxOutsideShare * Double(spoken.count) else {
            return .failure(.outsideAudio)
        }
        return .success(result)
    }
}
