//
//  AudioWindows.swift
//  PodcastAIKit
//
//  Kurze Stücke einer Folge für den Abgleich mit Untertiteln.
//
//  Liegt die Datei schon auf dem Gerät, schneidet `LocalAudioWindows` das
//  Stück genau auf die Probe heraus. Sonst holt `RemoteMP3Windows` es mit
//  einer Range-Anfrage, nur bei MP3 mit fester Bitrate, weil nur dort die
//  Zeit aus der Byte-Position folgt (`CBRAudioLayout`). Beide legen das
//  Stück als Datei ab, die die Spracherkennung liest, und nennen seine
//  genaue Anfangszeit in der Folge.
//
//  Die Regeln fürs Netz gelten wie überall: jede Anfrage über `SafeHTTP`,
//  mit Obergrenze. Ein Server, der Range ignoriert, liefert die ganze
//  Datei; die Obergrenze bricht das ab, und die App transkribiert wie bisher.
//

#if canImport(AVFoundation)
import Foundation
import AVFoundation
import PodcastAICore
import PodcastAIMedia
import PodcastAISources

/// Ein Stück der Folge als Datei.
struct AudioWindow: Sendable {
    let fileURL: URL
    /// Anfang des Stücks in der Zeit der Folge.
    let start: Int64
}

enum AudioWindowError: Error, Equatable {
    /// Diese Datei lässt sich nicht stückweise lesen, etwa M4A oder variable Bitrate.
    case unsupported
    /// Das Stück ließ sich nicht holen.
    case unavailable
}

protocol AudioWindowSource: Sendable {
    /// Länge der Folge, so wie die Stücke sie sehen.
    var duration: MediaDuration { get }
    func window(at start: Int64, length: Int64, into directory: URL) async throws -> AudioWindow
}

/// Aus einer Datei auf dem Gerät, auf das Sample genau.
struct LocalAudioWindows: AudioWindowSource {
    let fileURL: URL
    let duration: MediaDuration

    init?(fileURL: URL) {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        self.fileURL = fileURL
        self.duration = MediaDuration(seconds: Double(file.length) / rate)
    }

    func window(at start: Int64, length: Int64, into directory: URL) async throws -> AudioWindow {
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let first = AVAudioFramePosition(Double(max(0, start)) / 1000 * format.sampleRate)
        guard first < file.length else { throw AudioWindowError.unavailable }
        let count = AVAudioFrameCount(min(Double(length) / 1000 * format.sampleRate, Double(file.length - first)))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            throw AudioWindowError.unavailable
        }
        file.framePosition = first
        try file.read(into: buffer, frameCount: count)
        let destination = directory.appending(path: UUID().uuidString + ".caf")
        let output = try AVAudioFile(forWriting: destination, settings: format.settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try output.write(from: buffer)
        output.close()
        // Die tatsächliche Anfangszeit, auf das Sample gerundet.
        return AudioWindow(fileURL: destination, start: Int64((Double(first) / format.sampleRate * 1000).rounded()))
    }
}

/// Aus dem Netz, stückweise mit Range-Anfragen. Nur MP3 mit fester Bitrate.
struct RemoteMP3Windows: AudioWindowSource {

    typealias Fetch = @Sendable (_ url: URL, _ range: ClosedRange<Int64>, _ limit: Int64) async throws
        -> (status: Int, contentRange: String?, etag: String?, data: Data)

    let url: URL
    let layout: CBRAudioLayout
    let etag: String?
    let fetch: Fetch

    var duration: MediaDuration { layout.duration }

    /// Kopf für den Anfang: ID3-Kopf und der erste Rahmen passen meist hinein.
    static let headBytes: Int64 = 16 * 1024

    /// Über `SafeHTTP`, mit derselben Session für alle Stücke einer Folge.
    static func liveFetch() -> Fetch {
        let session = SafeHTTP.makeSession { configuration in
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
        }
        return { url, range, limit in
            let (data, response) = try await SafeHTTP.loadResponse(
                url, using: session, limit: limit,
                headers: ["Range": "bytes=\(range.lowerBound)-\(range.upperBound)"])
            return (response.statusCode, response.value(forHTTPHeaderField: "Content-Range"),
                    response.value(forHTTPHeaderField: "ETag"), data)
        }
    }

    /// Liest Anfang und Bitrate. `unsupported`, wenn die Datei kein MP3 mit
    /// fester Bitrate ist, der Server keine Stücke liefert oder die Länge
    /// nicht zur angegebenen Dauer passt.
    static func open(url: URL, declaredDuration: MediaDuration?, fetch: @escaping Fetch = liveFetch()) async throws -> RemoteMP3Windows {
        guard AudioTwinPlanner.audioAllowsAlignment(audioURL: url, onDevice: false, declaredDuration: nil) else {
            throw AudioWindowError.unsupported
        }
        let head = try await fetch(url, 0...(headBytes - 1), headBytes + 1024)
        guard head.status == 206, let total = MPEGAudio.totalLength(contentRange: head.contentRange),
              total > headBytes else { throw AudioWindowError.unsupported }
        guard let id3 = MPEGAudio.id3Length(head.data) else { throw AudioWindowError.unsupported }

        var data = head.data
        var dataOffset: Int64 = 0
        if Int64(id3) + 8_192 > Int64(data.count) {
            // Ein großes Cover im ID3-Block: der Ton beginnt weiter hinten.
            let start = Int64(id3)
            guard start < total else { throw AudioWindowError.unsupported }
            let part = try await fetch(url, start...min(total - 1, start + headBytes - 1), headBytes + 1024)
            guard part.status == 206, MPEGAudio.totalLength(contentRange: part.contentRange) == total,
                  part.etag == head.etag else { throw AudioWindowError.unsupported }
            data = part.data
            dataOffset = start
        }
        guard let layout = CBRAudioLayout.parse(head: data, dataOffset: dataOffset, searchFrom: Int64(id3),
                                                totalLength: total) else {
            throw AudioWindowError.unsupported
        }
        // Passt die errechnete Länge nicht zur angegebenen, stimmt die
        // Annahme fester Bitrate nicht, oder der Server liefert eine andere Datei.
        if let declaredDuration, declaredDuration.milliseconds > 0 {
            let difference = abs(layout.duration.milliseconds - declaredDuration.milliseconds)
            guard Double(difference) <= 0.10 * Double(declaredDuration.milliseconds) else {
                throw AudioWindowError.unsupported
            }
        }
        return RemoteMP3Windows(url: url, layout: layout, etag: head.etag, fetch: fetch)
    }

    func window(at start: Int64, length: Int64, into directory: URL) async throws -> AudioWindow {
        let first = layout.byte(atMilliseconds: start)
        // Vier Rahmen Luft, damit der erste ganze Rahmen sicher dabei ist.
        let slack = Int64(4 * 1_441)
        let last = min(layout.totalLength - 1, layout.byte(atMilliseconds: start + length) + slack)
        guard first < last else { throw AudioWindowError.unavailable }
        let response: (status: Int, contentRange: String?, etag: String?, data: Data)
        do {
            response = try await fetch(url, first...last, last - first + 1 + 1024)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AudioWindowError.unavailable
        }
        // Dieselbe Datei wie beim Kopf, sonst stimmen die Zeiten nicht.
        guard response.status == 206, MPEGAudio.totalLength(contentRange: response.contentRange) == layout.totalLength,
              response.etag == etag else { throw AudioWindowError.unsupported }
        guard let frame = MPEGAudio.firstFrame(in: response.data),
              let end = MPEGAudio.constantBitrateEnd(in: response.data, from: frame, bitrateKbps: layout.bitrateKbps)
        else { throw AudioWindowError.unsupported }
        let base = response.data.startIndex
        let destination = directory.appending(path: UUID().uuidString + ".mp3")
        try response.data[(base + frame)..<(base + end)].write(to: destination, options: .atomic)
        return AudioWindow(fileURL: destination, start: layout.milliseconds(atByte: first + Int64(frame)))
    }
}
#endif
