//
//  ChapterFile.swift
//  PodcastAISources
//
//  Kapitel im JSON-Format von Podcasting 2.0 (`application/json+chapters`).
//

import Foundation
import PodcastAICore

public enum ChapterFile {

    /// Liest eine Kapiteldatei. Kapitel ohne Titel, mit negativer Zeit oder
    /// mit `toc: false` fallen weg, der Rest wird nach Startzeit sortiert.
    /// Bild (`img`) und Link (`url`) bleiben erhalten, wenn sie auf http
    /// oder https zeigen.
    public static func parse(_ data: Data) throws -> [Chapter] {
        let file = try JSONDecoder().decode(File.self, from: data)
        return file.chapters
            .filter { $0.toc != false && !($0.title ?? "").isEmpty && $0.startTime >= 0 }
            .map { Chapter(start: MediaTime(milliseconds: Int64(($0.startTime * 1000).rounded())),
                           title: $0.title ?? "", provenance: .original,
                           imageURL: webURL($0.img), linkURL: webURL($0.url)) }
            .sorted { $0.start < $1.start }
    }

    /// Nur `http` und `https`, wie überall, wo ein Feed eine Adresse liefert.
    private static func webURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private struct File: Decodable {
        let chapters: [Entry]
        struct Entry: Decodable {
            let startTime: Double
            let title: String?
            let toc: Bool?
            let img: String?
            let url: String?
        }
    }
}
