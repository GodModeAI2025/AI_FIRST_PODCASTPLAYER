//
//  ChapterFile.swift
//  PodcastAISources
//
//  Kapitel im JSON-Format von Podcasting 2.0 (`application/json+chapters`).
//

import Foundation
import PodcastAICore

extension MediaTime {

    /// Sekunden aus fremden Daten (Feed, Kapiteldatei, Transkript). `nil`
    /// bei nicht endlichen, negativen oder absurd großen Werten. `inf` und
    /// `1e300` lassen sich als Zahl lesen und brächten die Umrechnung in
    /// Millisekunden zum Absturz.
    static func fromUntrustedSeconds(_ seconds: Double) -> MediaTime? {
        guard seconds.isFinite, seconds >= 0, seconds <= maximumUntrustedSeconds else { return nil }
        return MediaTime(milliseconds: Int64((seconds * 1000).rounded()))
    }

    /// 1000 Stunden. Keine Folge ist länger.
    static let maximumUntrustedSeconds: Double = 3_600_000
}

public enum ChapterFile {

    /// Liest eine Kapiteldatei. Kapitel ohne Titel, mit negativer Zeit oder
    /// mit `toc: false` fallen weg, der Rest wird nach Startzeit sortiert.
    /// Bild (`img`) und Link (`url`) bleiben erhalten, wenn sie auf http
    /// oder https zeigen.
    public static func parse(_ data: Data) throws -> [Chapter] {
        let file = try JSONDecoder().decode(File.self, from: data)
        return file.chapters
            .filter { $0.toc != false && !($0.title ?? "").isEmpty }
            .compactMap { entry in
                guard let start = MediaTime.fromUntrustedSeconds(entry.startTime) else { return nil }
                return Chapter(start: start, title: entry.title ?? "", provenance: .original,
                               imageURL: webURL(entry.img), linkURL: webURL(entry.url))
            }
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
