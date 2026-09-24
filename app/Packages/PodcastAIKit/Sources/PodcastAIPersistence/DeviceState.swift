//
//  DeviceState.swift
//  PodcastAIPersistence
//
//  Was sich dieses Gerät merkt und was wachsen kann, als Dateien unter
//  Application Support/PodcastAI/DeviceState, nicht in den Benutzereinstellungen.
//
//  Die Benutzereinstellungen halten kleine Schalter. Listen mit Hunderten
//  oder Tausenden Einträgen (aus der Warteschlange genommene Folgen,
//  Fehlversuche bei YouTube, Zwillinge, Lücken der Fakten) schrieb die App
//  dort bei jeder Änderung als Ganzes neu, auf dem Hauptthread. Hier liegt
//  jede Liste in ihrer eigenen Datei. Gelesen wird einmal je Start, danach
//  aus dem Speicher. Geschrieben wird im Hintergrund, und viele Änderungen
//  kurz hintereinander schreiben einmal.
//
//  Beim ersten Lesen nach dem Update zieht ein Wert aus den
//  Benutzereinstellungen in seine Datei um, unter demselben Namen.
//

import Foundation
import Synchronization

public final class DeviceState: Sendable {

    public static let shared = DeviceState(directory: URL.applicationSupportDirectory
        .appending(path: "PodcastAI/DeviceState", directoryHint: .isDirectory))

    public let directory: URL

    private struct Contents: ~Copyable {
        /// Gelesene oder gesetzte Werte.
        var values: [String: any Sendable] = [:]
        /// Ohne Datei und ohne alten Wert: nicht noch einmal nachsehen.
        var absent: Set<String> = []
        /// Was noch auf die Platte muss. `nil` im Ergebnis heißt: Datei löschen.
        var pending: [String: @Sendable () -> Data?] = [:]
    }

    private let contents = Mutex(Contents())
    private let queue = DispatchQueue(label: "com.godmodeai.podcastai.devicestate", qos: .utility)

    public init(directory: URL) {
        self.directory = directory
    }

    /// Der gemerkte Wert. `legacy` liest ihn beim ersten Mal aus den
    /// Benutzereinstellungen, falls es noch keine Datei gibt. Danach steht
    /// er in der Datei, und der alte Eintrag ist weg.
    public func value<T: Codable & Sendable>(_ type: T.Type, for key: String, legacy: () -> T? = { nil }) -> T? {
        let known: (hit: Bool, value: T?) = contents.withLock { contents in
            if let value = contents.values[key] as? T { return (true, value) }
            return (contents.absent.contains(key), nil)
        }
        if known.hit || known.value != nil { return known.value }

        if let data = try? Data(contentsOf: fileURL(for: key)),
           let decoded = try? JSONDecoder().decode(T.self, from: data) {
            contents.withLock { $0.values[key] = decoded }
            return decoded
        }
        if let old = legacy() {
            set(old, for: key)
            // Erst wenn die Datei liegt, fällt der alte Eintrag weg. Sonst
            // wäre der Wert nach einem Absturz genau hier verloren.
            flush()
            UserDefaults.standard.removeObject(forKey: key)
            return old
        }
        contents.withLock { _ = $0.absent.insert(key) }
        return nil
    }

    /// Setzt oder löscht einen Wert. Die Datei schreibt eine Queue im
    /// Hintergrund, mit dem jeweils letzten Stand.
    public func set<T: Codable & Sendable>(_ value: T?, for key: String) {
        let encode: @Sendable () -> Data? = { value.flatMap { try? JSONEncoder().encode($0) } }
        let scheduled = contents.withLock { contents -> Bool in
            if let value {
                contents.values[key] = value
                contents.absent.remove(key)
            } else {
                contents.values[key] = nil
                contents.absent.insert(key)
            }
            let already = contents.pending[key] != nil
            contents.pending[key] = encode
            return already
        }
        guard !scheduled else { return }
        queue.async { [self] in write(key) }
    }

    /// Wartet, bis alles Geschriebene auf der Platte liegt.
    public func flush() {
        queue.sync {}
    }

    /// Löscht alles, für einen frischen UI-Test. Läuft vor dem Modell.
    public func removeAll() {
        queue.sync {
            contents.withLock { $0 = Contents() }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func write(_ key: String) {
        guard let encode = contents.withLock({ $0.pending.removeValue(forKey: key) }) else { return }
        let url = fileURL(for: key)
        guard let data = encode() else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    private func fileURL(for key: String) -> URL {
        // Schlüssel sind feste Namen wie „tagsSettled-27.0“, ohne Schrägstrich.
        directory.appending(path: key.replacingOccurrences(of: "/", with: "_") + ".json")
    }
}
