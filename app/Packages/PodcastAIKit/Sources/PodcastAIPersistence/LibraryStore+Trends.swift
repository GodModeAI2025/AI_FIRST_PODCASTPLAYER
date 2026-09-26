//
//  LibraryStore+Trends.swift
//  PodcastAIPersistence
//
//  Eine Abfrage für „Angesagt“ seit 0.12, nur lesend. Die Zählung je Tag
//  und Quelle steht in `chapterTagCounts(publishedFrom:to:)`; hier kommt
//  dazu, wie weit die Bibliothek zurückreicht. Ohne diese Angabe hielte
//  `TrendDetector` in den ersten Wochen jedes Tag für angesagt.
//

#if canImport(SwiftData)
import Foundation
import SwiftData

extension LibraryStore {

    /// Das früheste Erscheinungsdatum unter allen Kapitel-Tags. Ohne
    /// Erscheinungsdatum zählt, wann das Kapitel-Tag entstand, wie in
    /// `chapterTags(publishedFrom:to:)`. `nil`: noch kein Kapitel-Tag.
    ///
    /// Liest höchstens zwei Zeilen.
    public func earliestChapterTagDate() throws -> Date? {
        var dated = FetchDescriptor<StoredChapterTag>(
            predicate: #Predicate { $0.publishedAt != nil },
            sortBy: [SortDescriptor(\.publishedAt)])
        dated.fetchLimit = 1
        dated.propertiesToFetch = [\.publishedAt]
        var undated = FetchDescriptor<StoredChapterTag>(
            predicate: #Predicate { $0.publishedAt == nil },
            sortBy: [SortDescriptor(\.createdAt)])
        undated.fetchLimit = 1
        undated.propertiesToFetch = [\.createdAt]
        let candidates = [
            try modelContext.fetch(dated).first?.publishedAt,
            try modelContext.fetch(undated).first?.createdAt,
        ]
        return candidates.compactMap { $0 }.min()
    }
}
#endif
