//
//  PlayableAsset.swift
//  PodcastAIMedia
//
//  Geladene Folgen liegen unter ihrer Fassungskennung, ohne Dateiendung.
//  AVFoundation erkennt das Format einer lokalen Datei aber an der Endung
//  und meldet ohne sie „Cannot Open“. Die Wiedergabe blieb dann stumm,
//  während die Anzeige lief. Hier wird das Format am Dateianfang erkannt
//  und dem Asset ausdrücklich mitgegeben.
//

import Foundation
import AVFoundation

public enum PlayableAsset {

    /// Ein Asset, das auch eine lokale Datei ohne Endung abspielt.
    public static func make(url: URL) -> AVURLAsset {
        guard url.isFileURL, url.pathExtension.isEmpty,
              let mime = sniffMIMEType(at: url) else {
            return AVURLAsset(url: url)
        }
        return AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: mime])
    }

    public static func sniffMIMEType(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16) else { return nil }
        return mimeType(forHeader: head)
    }

    /// Erkennt die üblichen Podcast-Formate an ihren ersten Bytes.
    public static func mimeType(forHeader head: Data) -> String? {
        let bytes = [UInt8](head)
        guard bytes.count >= 4 else { return nil }
        func ascii(_ range: Range<Int>) -> String? {
            guard range.upperBound <= bytes.count else { return nil }
            return String(bytes: bytes[range], encoding: .ascii)
        }
        if ascii(0..<3) == "ID3" { return "audio/mpeg" }
        if ascii(4..<8) == "ftyp" { return "audio/mp4" }
        if ascii(0..<4) == "RIFF" { return "audio/wav" }
        if ascii(0..<4) == "OggS" { return "audio/ogg" }
        if ascii(0..<4) == "fLaC" { return "audio/flac" }
        // ADTS-AAC: Sync-Wort 0xFFF, Layer 00.
        if bytes[0] == 0xFF, bytes[1] & 0xF6 == 0xF0 { return "audio/aac" }
        // MPEG-Audio-Frame ohne ID3-Kopf: Sync-Wort 0xFFE.
        if bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 { return "audio/mpeg" }
        return nil
    }
}
