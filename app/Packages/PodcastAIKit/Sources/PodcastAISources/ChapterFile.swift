//
//  ChapterFile.swift
//  PodcastAISources
//
//  Kapitel im JSON-Format von Podcasting 2.0 (`application/json+chapters`).
//

import Foundation
import PodcastAICore

public enum ChapterFile {

    /// Liest eine Kapiteldatei. Kapitel ohne Titel oder mit
    /// `toc: false` fallen weg, der Rest wird nach Startzeit sortiert.
    public static func parse(_ data: Data) throws -> [Chapter] {
        let file = try JSONDecoder().decode(File.self, from: data)
        return file.chapters
            .filter { $0.toc != false && !($0.title ?? "").isEmpty }
            .map { Chapter(start: MediaTime(milliseconds: Int64(($0.startTime * 1000).rounded())),
                           title: $0.title ?? "", provenance: .original) }
            .sorted { $0.start < $1.start }
    }

    private struct File: Decodable {
        let chapters: [Entry]
        struct Entry: Decodable {
            let startTime: Double
            let title: String?
            let toc: Bool?
        }
    }
}
