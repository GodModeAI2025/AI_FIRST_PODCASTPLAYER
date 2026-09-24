//
//  MPEGAudioLayout.swift
//  PodcastAIMedia
//
//  Wo in einer MP3-Datei welche Sekunde liegt, ohne die Datei zu laden.
//
//  Für den Abgleich mit Untertiteln braucht die App ein paar kurze Stücke
//  des Tons, geholt mit Range-Anfragen. Die Zeit eines Stücks muss dabei
//  genau stimmen, sonst stimmt der Versatz nicht. Das geht nur bei MP3 mit
//  fester Bitrate (CBR): dort ist jede Sekunde gleich viele Byte lang.
//
//  * Vor dem Ton steht oft ein ID3-Block mit Cover, gern ein paar hundert
//    Kilobyte. Seine Länge steht in den ersten zehn Byte.
//  * Der erste Rahmen danach nennt Bitrate und Abtastrate. Trägt er eine
//    Kennung „Xing“ oder „VBRI“, ist die Bitrate variabel: dann nicht.
//    „Info“ heißt feste Bitrate; dieser Rahmen selbst ist kein Ton.
//  * Jedes geholte Stück wird Rahmen für Rahmen geprüft. Weicht eine
//    Bitrate ab, war die Datei doch nicht fest, und das Stück gilt nicht.
//
//  AAC in MP4 (M4A) geht so nicht, dort steht das Inhaltsverzeichnis an
//  einer Stelle, die ein Stück aus der Mitte nicht hat. Dann transkribiert
//  die App den ganzen Ton wie bisher.
//
//  Reine Logik ohne Netz, also prüfbar.
//

import Foundation
import PodcastAICore

public enum MPEGAudio {

    /// Der Kopf eines MPEG-Audio-Rahmens (nur Layer III).
    public struct FrameHeader: Equatable, Sendable {
        public enum Version: Equatable, Sendable { case mpeg1, mpeg2, mpeg25 }
        public let version: Version
        public let bitrateKbps: Int
        public let sampleRate: Int
        public let padding: Bool
        public let mono: Bool

        /// Länge des Rahmens in Byte, Kopf eingeschlossen.
        public var length: Int {
            let factor = version == .mpeg1 ? 144 : 72
            return factor * bitrateKbps * 1000 / sampleRate + (padding ? 1 : 0)
        }

        /// Wo im Rahmen eine Kennung „Xing“ oder „Info“ stünde.
        var xingOffset: Int {
            switch (version, mono) {
            case (.mpeg1, false): 4 + 32
            case (.mpeg1, true): 4 + 17
            case (_, false): 4 + 17
            case (_, true): 4 + 9
            }
        }

        /// Gehört dieser Rahmen zum selben Strom wie `other`?
        func sameStream(as other: FrameHeader) -> Bool {
            version == other.version && sampleRate == other.sampleRate
        }
    }

    private static let bitratesV1: [Int] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    private static let bitratesV2: [Int] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

    /// Liest den Kopf eines Rahmens an `offset`, falls dort einer beginnt.
    public static func header(in data: Data, at offset: Int) -> FrameHeader? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let base = data.startIndex + offset
        let b0 = data[base], b1 = data[base + 1], b2 = data[base + 2], b3 = data[base + 3]
        guard b0 == 0xFF, b1 & 0xE0 == 0xE0 else { return nil }
        let version: FrameHeader.Version
        switch (b1 >> 3) & 0x03 {
        case 0: version = .mpeg25
        case 2: version = .mpeg2
        case 3: version = .mpeg1
        default: return nil
        }
        // Nur Layer III, so gut wie jeder MP3-Podcast.
        guard (b1 >> 1) & 0x03 == 1 else { return nil }
        let bitrateIndex = Int(b2 >> 4)
        let rateIndex = Int((b2 >> 2) & 0x03)
        guard (1...14).contains(bitrateIndex), rateIndex < 3 else { return nil }
        let bitrate = (version == .mpeg1 ? bitratesV1 : bitratesV2)[bitrateIndex]
        let rates: [Int] = switch version {
        case .mpeg1: [44_100, 48_000, 32_000]
        case .mpeg2: [22_050, 24_000, 16_000]
        case .mpeg25: [11_025, 12_000, 8_000]
        }
        return FrameHeader(version: version, bitrateKbps: bitrate, sampleRate: rates[rateIndex],
                           padding: (b2 >> 1) & 0x01 == 1, mono: (b3 >> 6) & 0x03 == 3)
    }

    /// Der erste Rahmen ab `start`, dem noch `following` Rahmen desselben
    /// Stroms folgen. Ein einzelnes 0xFF mitten im Ton ist kein Rahmen.
    public static func firstFrame(in data: Data, from start: Int = 0, following: Int = 2) -> Int? {
        var offset = max(0, start)
        while offset + 4 <= data.count {
            if let head = header(in: data, at: offset), chainHolds(in: data, from: offset, head: head, count: following) {
                return offset
            }
            offset += 1
        }
        return nil
    }

    private static func chainHolds(in data: Data, from offset: Int, head: FrameHeader, count: Int) -> Bool {
        var position = offset + head.length
        for _ in 0..<count {
            guard let next = header(in: data, at: position), next.sameStream(as: head) else { return false }
            position += next.length
        }
        return true
    }

    /// Länge eines ID3v2-Blocks am Anfang, Kopf und Fußzeile eingeschlossen.
    /// 0, wenn die Daten nicht mit „ID3“ beginnen.
    public static func id3Length(_ data: Data) -> Int? {
        guard data.count >= 10 else { return nil }
        let bytes = [UInt8](data.prefix(10))
        guard bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return 0 }
        let size = bytes[6...9].reduce(0) { result, byte -> Int? in
            guard let result, byte & 0x80 == 0 else { return nil }
            return (result << 7) | Int(byte)
        }
        guard let size else { return nil }
        let footer = bytes[5] & 0x10 != 0 ? 10 : 0
        return 10 + size + footer
    }

    public enum BitrateTag: Equatable, Sendable {
        /// Keine Kennung: vermutlich feste Bitrate, jedes Stück prüft es.
        case none
        /// „Info“: feste Bitrate, der Rahmen selbst trägt keinen Ton.
        case info
        /// „Xing“ oder „VBRI“: variable Bitrate.
        case variable
    }

    /// Welche Kennung der Rahmen an `offset` trägt.
    public static func bitrateTag(in data: Data, frameAt offset: Int, header head: FrameHeader) -> BitrateTag {
        func tag(at position: Int) -> String? {
            guard position >= 0, position + 4 <= data.count else { return nil }
            let base = data.startIndex + position
            return String(bytes: data[base..<(base + 4)], encoding: .ascii)
        }
        switch tag(at: offset + head.xingOffset) {
        case "Xing": return .variable
        case "Info": return .info
        default: break
        }
        return tag(at: offset + 36) == "VBRI" ? .variable : .none
    }

    /// Liegen ab `offset` nur Rahmen mit dieser Bitrate? Gibt das Ende des
    /// letzten vollständigen Rahmens zurück, oder `nil` bei einer Abweichung.
    public static func constantBitrateEnd(in data: Data, from offset: Int, bitrateKbps: Int) -> Int? {
        guard let first = header(in: data, at: offset) else { return nil }
        var position = offset
        var frames = 0
        while let head = header(in: data, at: position), head.sameStream(as: first) {
            guard head.bitrateKbps == bitrateKbps else { return nil }
            guard position + head.length <= data.count else { break }
            position += head.length
            frames += 1
        }
        // Mitten im Stück ein Bruch, der kein Datenende ist: kein sauberer Strom.
        if position + 4 <= data.count, frames > 0, data.count - position > 1_500 { return nil }
        return frames > 0 ? position : nil
    }

    /// `bytes 0-16383/7654321` → 7654321.
    public static func totalLength(contentRange: String?) -> Int64? {
        guard let contentRange, let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}

/// Die Lage des Tons in einer MP3-Datei mit fester Bitrate.
public struct CBRAudioLayout: Equatable, Sendable {
    /// Erstes Byte des ersten Rahmens mit Ton.
    public let audioStart: Int64
    /// Gesamtlänge der Datei laut Server.
    public let totalLength: Int64
    public let bitrateKbps: Int
    public let sampleRate: Int

    public init(audioStart: Int64, totalLength: Int64, bitrateKbps: Int, sampleRate: Int) {
        self.audioStart = audioStart
        self.totalLength = totalLength
        self.bitrateKbps = bitrateKbps
        self.sampleRate = sampleRate
    }

    /// Byte je Sekunde.
    public var bytesPerSecond: Int64 { Int64(bitrateKbps) * 125 }

    /// Länge des Tons. Ein ID3v1-Block am Ende (128 Byte) fällt nicht ins Gewicht.
    public var duration: MediaDuration {
        MediaDuration(milliseconds: max(0, totalLength - audioStart) * 8 / Int64(bitrateKbps))
    }

    /// Die Zeit eines Rahmens, der bei `byte` beginnt. Bits geteilt durch
    /// Kilobit je Sekunde ergibt Millisekunden.
    public func milliseconds(atByte byte: Int64) -> Int64 {
        max(0, byte - audioStart) * 8 / Int64(bitrateKbps)
    }

    /// Das Byte zu einer Zeit, auf den Rahmen genau erst nach dem Laden.
    public func byte(atMilliseconds milliseconds: Int64) -> Int64 {
        audioStart + max(0, milliseconds) * Int64(bitrateKbps) / 8
    }

    /// Aus dem Anfang der Datei: Beginn des Tons und Bitrate. `data` beginnt
    /// bei Byte `dataOffset` der Datei. `nil` bei variabler Bitrate oder wenn
    /// sich kein Rahmen findet.
    public static func parse(head data: Data, dataOffset: Int64, searchFrom: Int64, totalLength: Int64) -> CBRAudioLayout? {
        let local = Int(max(0, searchFrom - dataOffset))
        guard let frame = MPEGAudio.firstFrame(in: data, from: local),
              let head = MPEGAudio.header(in: data, at: frame) else { return nil }
        var start = frame
        switch MPEGAudio.bitrateTag(in: data, frameAt: frame, header: head) {
        case .variable: return nil
        case .info: start = frame + head.length
        case .none: break
        }
        return CBRAudioLayout(audioStart: dataOffset + Int64(start), totalLength: totalLength,
                              bitrateKbps: head.bitrateKbps, sampleRate: head.sampleRate)
    }
}
