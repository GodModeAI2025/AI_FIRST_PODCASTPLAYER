//
//  AudioWindowsTests.swift
//  PodcastAIKitTests
//
//  Stücke einer Folge aus dem Netz: was der Server über die Länge der Datei
//  behauptet, entscheidet, ob die App überhaupt damit rechnet. Kein Test
//  geht ins Netz, der Server ist eine Closure.
//

#if canImport(AVFoundation)
import Foundation
import Testing
@testable import PodcastAIKit

@Suite("Stücke einer Folge aus dem Netz")
struct RemoteMP3WindowsTests {

    private let url = URL(string: "https://example.invalid/folge.mp3")!

    /// Ein Server, der auf jede Range-Anfrage mit 206 antwortet und als
    /// Gesamtlänge nennt, was der Test vorgibt. Der Inhalt ist MPEG-1
    /// Layer III mit 128 kbit/s und 44,1 kHz: 417 Byte je Rahmen.
    private func server(total: String) -> RemoteMP3Windows.Fetch {
        var frame = Data([0xFF, 0xFB, 0x90, 0x00])
        frame.append(Data(count: 417 - 4))
        let head = Data((0..<40).flatMap { _ in frame })
        return { _, range, _ in
            (206, "bytes \(range.lowerBound)-\(range.upperBound)/\(total)", "\"a\"", head)
        }
    }

    @Test("Eine Länge, die keine Folge hat, öffnet nicht", arguments: [
        "9000000000000000000", "9223372036854775807", String(MediaDownloader.maximumBytes + 1),
    ])
    func rejectsImpossibleTotal(total: String) async {
        await #expect(throws: AudioWindowError.unsupported) {
            try await RemoteMP3Windows.open(url: url, declaredDuration: nil, fetch: server(total: total))
        }
    }

    @Test("Bis zur Obergrenze der Mediendateien öffnet sie, die Dauer folgt aus der Länge")
    func opensPlausibleTotal() async throws {
        // 16 000 Byte je Sekunde: 1000 Sekunden.
        let usual = try await RemoteMP3Windows.open(url: url, declaredDuration: nil, fetch: server(total: "16000000"))
        #expect(usual.duration == MediaDuration(seconds: 1000))

        let largest = try await RemoteMP3Windows.open(
            url: url, declaredDuration: nil, fetch: server(total: String(MediaDownloader.maximumBytes)))
        #expect(largest.layout.totalLength == MediaDownloader.maximumBytes)
    }
}
#endif
