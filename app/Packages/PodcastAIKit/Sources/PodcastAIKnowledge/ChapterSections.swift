//
//  ChapterSections.swift
//  PodcastAIKnowledge
//
//  Die Folge nach Kapiteln: Grenzen, Zuordnung von Belegen und Fakten zu
//  einem Kapitel und die Verteilung der Fakten über alle Kapitel.
//
//  Die Zuordnung steht in keinem Feld der Datenbank. Sie ergibt sich zur
//  Laufzeit aus dem Anfang einer Stelle und den Kapitelgrenzen. Liefert der
//  Feed keine Kapitel, bildet der Code eigene Abschnitte von vier bis zehn
//  Minuten. Er schneidet zwischen zwei Belegen, dort, wo sich der Inhalt am
//  stärksten ändert. Grenzen und Zeiten legt nur der Code fest, kein Modell.
//

import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif
import PodcastAICore

/// Ein Kapitel mit Anfang und Ende. Aus dem Feed (`original`) oder vom
/// Code gebildet (`derived`, „Abschnitt 3“).
public struct ChapterSection: Hashable, Sendable, Identifiable {
    /// Position in der Folge, bei 0 beginnend.
    public let index: Int
    public let range: MediaTimeRange
    public let title: String
    public let provenance: Provenance

    public init(index: Int, range: MediaTimeRange, title: String, provenance: Provenance) {
        self.index = index; self.range = range; self.title = title; self.provenance = provenance
    }

    /// Der Anfang in Millisekunden. Zwei Kapitel einer Folge beginnen nie gleich.
    public var id: Int64 { range.start.milliseconds }
    /// Vom Code gebildet, nicht vom Podcast.
    public var isDerived: Bool { provenance == .derived }
    public var chapter: Chapter { Chapter(start: range.start, title: title, provenance: provenance) }
}

public enum ChapterSections {

    /// Kürzester und längster Abschnitt, den der Code selbst bildet.
    public static let minimumDerivedLength = MediaDuration(minutes: 4)
    public static let maximumDerivedLength = MediaDuration(minutes: 10)

    /// Wie stark sich der Inhalt zwischen zwei benachbarten Belegen ändert.
    /// Ein Wert je Grenze, also einer weniger als Belege, oder `nil`, wenn
    /// sich das nicht messen lässt.
    public typealias JumpMeasure = @Sendable ([Evidence]) -> [Double]?

    // MARK: - Kapitel mit Grenzen

    /// Die Kapitel einer Folge mit Anfang und Ende.
    ///
    /// Gibt es Kapitel aus dem Feed, gelten sie. Ein Kapitel reicht bis zum
    /// nächsten, das letzte bis zum Ende der Folge oder, wenn das Transkript
    /// länger ist, bis zum Ende des letzten Belegs. Ohne Kapitel bildet
    /// ``derive(from:duration:jumps:)`` Abschnitte aus den Belegen. Ohne
    /// Kapitel und ohne Belege gibt es nichts.
    public static func sections(
        chapters: [Chapter], duration: MediaDuration?, evidence: [Evidence],
        jumps: JumpMeasure = ChapterSections.embeddingJumps
    ) -> [ChapterSection] {
        var seen: Set<Int64> = []
        // Zwei Marken an derselben Stelle: die erste aus dem Feed gilt.
        let marks = chapters.filter { seen.insert($0.start.milliseconds).inserted }.sorted { $0.start < $1.start }
        guard !marks.isEmpty else { return derive(from: evidence, duration: duration, jumps: jumps) }
        let end = endOfContent(duration: duration, evidence: evidence)
        return marks.enumerated().map { index, chapter in
            let next = index + 1 < marks.count ? marks[index + 1].start : max(end, chapter.start)
            return ChapterSection(index: index, range: MediaTimeRange(start: chapter.start, end: next),
                                  title: chapter.title, provenance: chapter.provenance)
        }
    }

    /// Das Ende der Folge: ihre Länge oder das Ende des letzten Belegs,
    /// was später liegt.
    static func endOfContent(duration: MediaDuration?, evidence: [Evidence]) -> MediaTime {
        let last = evidence.compactMap(\.range?.end).max() ?? .zero
        let declared = MediaTime(milliseconds: duration?.milliseconds ?? 0)
        return max(last, declared)
    }

    // MARK: - Abgeleitete Abschnitte

    /// Abschnitte aus den Belegen, für Folgen ohne Kapitel.
    ///
    /// Der erste Abschnitt beginnt bei 0. Geschnitten wird nur an einer
    /// Grenze zwischen zwei Belegen, und zwar dort, wo der Inhalt am
    /// stärksten springt, sofern der Abschnitt dann zwischen vier und zehn
    /// Minuten lang ist und danach noch mindestens vier Minuten bleiben.
    /// Ist der Rest höchstens zehn Minuten lang, wird er der letzte
    /// Abschnitt. Lässt sich der Sprung nicht messen, schneidet der Code
    /// möglichst nahe an sieben Minuten. Liegt zwischen zwei Belegen eine
    /// große Lücke, kann ein Abschnitt länger werden, denn mitten in einem
    /// Beleg wird nie geschnitten.
    public static func derive(
        from evidence: [Evidence], duration: MediaDuration?,
        jumps: JumpMeasure = ChapterSections.embeddingJumps
    ) -> [ChapterSection] {
        let timed = timeline(evidence)
        guard !timed.isEmpty else { return [] }
        let end = endOfContent(duration: duration, evidence: timed).milliseconds
        let boundaries = timed.dropFirst().map { $0.range!.start.milliseconds }
        var scores = jumps(timed)
        if scores?.count != boundaries.count { scores = nil }

        let minimum = minimumDerivedLength.milliseconds
        let maximum = maximumDerivedLength.milliseconds
        let target = (minimum + maximum) / 2
        var cuts: [Int64] = [0]
        var start: Int64 = 0
        while end - start > maximum {
            let open = boundaries.indices.filter { boundaries[$0] > start }
            var window = open.filter {
                let length = boundaries[$0] - start
                return length >= minimum && length <= maximum && end - boundaries[$0] >= minimum
            }
            // Keine Grenze passt ins Fenster, etwa wegen einer großen Lücke:
            // die erste nach der Mindestlänge, sonst endet es hier.
            if window.isEmpty, let first = open.first(where: { boundaries[$0] - start >= minimum }) {
                window = [first]
            }
            guard !window.isEmpty else { break }
            let chosen = window.max { lhs, rhs in
                let left = scores?[lhs] ?? 0, right = scores?[rhs] ?? 0
                if left != right { return left < right }
                // Gleich stark oder nicht gemessen: näher an sieben Minuten,
                // bei Gleichstand die frühere Grenze.
                let leftDistance = abs(boundaries[lhs] - start - target)
                let rightDistance = abs(boundaries[rhs] - start - target)
                if leftDistance != rightDistance { return leftDistance > rightDistance }
                return lhs > rhs
            }!
            start = boundaries[chosen]
            cuts.append(start)
        }
        return cuts.enumerated().map { index, cut in
            let next = index + 1 < cuts.count ? cuts[index + 1] : max(end, cut)
            return ChapterSection(
                index: index,
                range: MediaTimeRange(start: MediaTime(milliseconds: cut), end: MediaTime(milliseconds: next)),
                title: derivedTitle(index + 1), provenance: .derived)
        }
    }

    /// „Abschnitt 3“, in der Sprache der App.
    public static func derivedTitle(_ number: Int) -> String {
        String(localized: "Abschnitt \(number)", bundle: .module)
    }

    /// Belege mit Zeitmarke, nach Anfang sortiert, jeder einmal.
    static func timeline(_ evidence: [Evidence]) -> [Evidence] {
        var seen: Set<EvidenceID> = []
        return evidence
            .filter { $0.range != nil && seen.insert($0.id).inserted }
            .sorted { $0.range!.start < $1.range!.start }
    }

    /// Wie weit zwei benachbarte Belege inhaltlich auseinanderliegen, über
    /// Apples Satzvektoren (`NLEmbedding`): 1 minus Kosinus. Die Sprache
    /// wird einmal für die ganze Folge bestimmt, wie beim Ranking für den
    /// Chat. Ohne Satzvektor für die Sprache `nil`.
    public static let embeddingJumps: JumpMeasure = { evidence in
        #if canImport(NaturalLanguage)
        guard evidence.count > 1 else { return [] }
        let sample = evidence.prefix(40).map(\.quotedText).joined(separator: " ")
        guard let embedding = PassageRanker.embedding(for: String(sample.prefix(4_000))) else { return nil }
        let vectors = evidence.map { embedding.vector(for: String($0.quotedText.prefix(600))) }
        guard vectors.contains(where: { $0 != nil }) else { return nil }
        return (0..<(vectors.count - 1)).map { index in
            guard let left = vectors[index], let right = vectors[index + 1] else { return 0 }
            return 1 - PassageRanker.cosine(left, right)
        }
        #else
        return nil
        #endif
    }

    // MARK: - Zuordnung

    /// Das Kapitel, in dem eine Stelle beginnt. Was vor dem ersten Kapitel
    /// liegt, gehört zum ersten, was nach dem letzten liegt, zum letzten.
    /// Beginnt eine Stelle genau auf einer Grenze, gehört sie zum Kapitel,
    /// das dort anfängt.
    public static func sectionIndex(of time: MediaTime, in sections: [ChapterSection]) -> Int? {
        guard !sections.isEmpty else { return nil }
        return sections.lastIndex { $0.range.start <= time } ?? 0
    }

    /// Verteilt Stellen auf die Kapitel, eine Liste je Kapitel. Was keine
    /// Zeitmarke hat, fällt heraus.
    public static func group<T>(
        _ items: [T], into sections: [ChapterSection], at time: (T) -> MediaTime?
    ) -> [[T]] {
        var groups = Array(repeating: [T](), count: sections.count)
        for item in items {
            guard let start = time(item), let index = sectionIndex(of: start, in: sections) else { continue }
            groups[index].append(item)
        }
        return groups
    }

    // MARK: - Fakten je Kapitel

    /// Wie die Fakten einer Folge entstehen: welche Belege in welchem
    /// Aufruf ans Modell gehen und wie viele Fakten je Kapitel bleiben.
    public struct FactPlan: Sendable, Equatable {
        /// Die Belege je Modellaufruf, in der Reihenfolge der Folge.
        public let slices: [[Evidence]]
        /// So viele Fakten behält ein Kapitel höchstens.
        public let quota: Int
        /// So viele Fakten behält die Folge höchstens.
        public let limit: Int
    }

    /// Grenzen für ``factPlan(evidence:sections:chunk:budget:)``.
    public struct FactBudget: Sendable, Equatable {
        /// So viele Aufrufe bekommt jede Folge, auch mit wenigen Kapiteln.
        public var baseCalls: Int
        /// Mehr Aufrufe gibt es auch bei vielen Kapiteln nicht.
        public var maximumCalls: Int
        /// So viele Fakten darf jede Folge mindestens behalten.
        public var baseLimit: Int
        /// Mehr Fakten behält keine Folge.
        public var maximumLimit: Int
        /// Mit so vielen Fakten je Kapitel wächst die Grenze.
        public var perSection: Int
        /// So viele Fakten darf jedes Kapitel mindestens behalten.
        public var minimumQuota: Int

        public init(baseCalls: Int = 6, maximumCalls: Int = 16, baseLimit: Int = 40,
                    maximumLimit: Int = 120, perSection: Int = 4, minimumQuota: Int = 3) {
            self.baseCalls = baseCalls; self.maximumCalls = maximumCalls
            self.baseLimit = baseLimit; self.maximumLimit = maximumLimit
            self.perSection = perSection; self.minimumQuota = minimumQuota
        }
    }

    /// Plant die Fakten so, dass jedes Kapitel mit Belegen drankommt.
    ///
    /// Vorher gingen gleichmäßig verteilte Belege der ganzen Folge ans
    /// Modell, höchstens sechs Aufrufe. Bei vielen kurzen Kapiteln fielen
    /// dabei ganze Kapitel heraus. Jetzt bekommt jedes Kapitel seinen Anteil
    /// an den Belegen: Kurze Kapitel gehen ganz hinein, lange werden
    /// gleichmäßig ausgedünnt, bis alle zusammen in die Aufrufe passen. Die
    /// Zahl der Aufrufe wächst mit der Zahl der Kapitel, von
    /// ``FactBudget/baseCalls`` bis ``FactBudget/maximumCalls``, denn jeder
    /// Aufruf kostet auf dem Gerät Sekunden. Kurze Kapitel teilen sich einen
    /// Aufruf. Ein Kapitel fällt nur dann auf zwei Aufrufe, wenn es allein
    /// mehr Belege hat, als in einen passen, oder wenn ganze Kapitel mehr
    /// Aufrufe bräuchten als erlaubt.
    ///
    /// Die Grenze der Fakten wächst mit, ``FactBudget/perSection`` je
    /// Kapitel, und jedes Kapitel darf davon gleich viele behalten.
    public static func factPlan(
        evidence: [Evidence], sections: [ChapterSection], chunk: Int, budget: FactBudget = FactBudget()
    ) -> FactPlan {
        let chunk = max(1, chunk)
        let timed = timeline(evidence)
        let groups = sections.isEmpty
            ? (timed.isEmpty ? [] : [timed])
            : group(timed, into: sections, at: { $0.range?.start }).filter { !$0.isEmpty }
        let count = groups.count
        guard count > 0 else { return FactPlan(slices: [], quota: budget.minimumQuota, limit: budget.baseLimit) }

        let calls = min(budget.maximumCalls, max(budget.baseCalls, count))
        let allowances = shares(of: groups.map(\.count), total: chunk * calls)
        let samples = zip(groups, allowances).map { evenlySpaced($0, count: $1) }

        var slices: [[Evidence]] = []
        var current: [Evidence] = []
        for sample in samples where !sample.isEmpty {
            if sample.count > chunk {
                if !current.isEmpty { slices.append(current); current = [] }
                slices += stride(from: 0, to: sample.count, by: chunk).map {
                    Array(sample[$0..<min($0 + chunk, sample.count)])
                }
            } else if current.count + sample.count > chunk {
                slices.append(current)
                current = sample
            } else {
                current += sample
            }
        }
        if !current.isEmpty { slices.append(current) }
        // Ganze Kapitel füllen die Aufrufe nicht immer aus. Bräuchte es so
        // mehr Aufrufe als erlaubt, laufen die Belege der Reihe nach durch,
        // und ein Kapitel darf auf zwei Aufrufe fallen.
        if slices.count > calls {
            let all = samples.flatMap { $0 }
            slices = stride(from: 0, to: all.count, by: chunk).map { Array(all[$0..<min($0 + chunk, all.count)]) }
        }

        let limit = min(budget.maximumLimit, max(budget.baseLimit, count * budget.perSection))
        let quota = max(budget.minimumQuota, Int((Double(limit) / Double(count)).rounded(.up)))
        return FactPlan(slices: slices, quota: quota, limit: limit)
    }

    /// Die Aufrufe, die gemerkte Lücken nachholen, je Aufruf nur mit den
    /// Belegen, die in einer Lücke beginnen.
    ///
    /// Eine Lücke ist die Zeitspanne eines früheren Aufrufs, der an Last oder
    /// Zeit gescheitert ist. Die Aufrufe selbst können sich seitdem
    /// verschoben haben, etwa weil die Kapiteldatei inzwischen geladen ist
    /// und aus abgeleiteten Abschnitten Kapitel aus dem Feed wurden. Ein
    /// Vergleich der Aufrufe fände die Lücke dann nicht mehr, und ihr Teil
    /// der Folge bliebe ohne Fakten. Über die Zeit findet er sie. Belege
    /// außerhalb der Lücken bleiben draußen, denn aus ihnen gibt es schon Fakten.
    public static func reopened(_ slices: [[Evidence]], gaps: [MediaTimeRange]) -> [Int: [Evidence]] {
        guard !gaps.isEmpty else { return [:] }
        var result: [Int: [Evidence]] = [:]
        for (index, slice) in slices.enumerated() {
            let part = slice.filter { item in
                guard let start = item.range?.start else { return false }
                return gaps.contains { $0.contains(start) }
            }
            if !part.isEmpty { result[index] = part }
        }
        return result
    }

    /// Teilt `total` Plätze so auf, dass keiner mehr bekommt, als er
    /// braucht, und die übrigen möglichst gleich viel. Jeder mit Bedarf
    /// bekommt mindestens einen Platz, auch wenn es dann mehr als `total`
    /// werden.
    static func shares(of needs: [Int], total: Int) -> [Int] {
        guard needs.reduce(0, +) > total else { return needs }
        // Die größte gemeinsame Obergrenze, bei der alles hineinpasst.
        var cap = 0
        while needs.reduce(0, { $0 + min($1, cap + 1) }) <= total { cap += 1 }
        var result = needs.map { max(min($0, 1), min($0, cap)) }
        // Was übrig bleibt, geht der Reihe nach an die, die mehr brauchen.
        var left = total - result.reduce(0, +)
        for index in needs.indices where left > 0 && result[index] < needs[index] {
            result[index] += 1
            left -= 1
        }
        return result
    }

    /// Behält je Kapitel höchstens `quota` Stellen, gleichmäßig über das
    /// Kapitel verteilt, und insgesamt höchstens `limit`. Reicht das nicht,
    /// sinkt die Zahl je Kapitel, bis alles passt, so bleibt jedes Kapitel
    /// vertreten. Das Ergebnis ist nach Zeit sortiert.
    public static func balanced<T>(
        _ items: [T], across sections: [ChapterSection], quota: Int, limit: Int,
        at time: (T) -> MediaTime
    ) -> [T] {
        let sorted = items.sorted { time($0) < time($1) }
        guard !sections.isEmpty else { return evenlySpaced(sorted, count: limit) }
        let groups = group(sorted, into: sections, at: { time($0) })
        var cap = max(1, quota)
        while cap > 1, groups.reduce(0, { $0 + min($1.count, cap) }) > limit { cap -= 1 }
        let kept = groups.flatMap { evenlySpaced($0, count: cap) }
        return evenlySpaced(kept, count: limit)
    }

    /// Gleichmäßig verteilte Auswahl, Reihenfolge bleibt.
    static func evenlySpaced<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count, count > 0 else { return count <= 0 ? [] : items }
        let step = Double(items.count) / Double(count)
        return (0..<count).map { items[Int(Double($0) * step)] }
    }
}
