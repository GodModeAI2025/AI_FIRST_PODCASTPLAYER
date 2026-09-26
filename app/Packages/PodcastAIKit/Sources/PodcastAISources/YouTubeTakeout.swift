//
//  YouTubeTakeout.swift
//  PodcastAISources
//
//  YouTube-Abos mitbringen. Google Takeout exportiert die Abos eines Kontos
//  als CSV-Datei mit drei Spalten: Kennung, Adresse und Name des Kanals.
//  Wer 80 Kanäle abonniert hat, soll nicht jeden einzeln suchen.
//
//  Die Datei ist fremde Eingabe. Gelesen werden nur Kennung, Adresse und
//  Name. Die Spaltennamen übersetzt Google in die Sprache des Kontos, und
//  nach dem Öffnen in einer Tabellenkalkulation steht oft ein Semikolon
//  statt eines Kommas da. Deshalb erkennt der Leser die Spalten zuerst am
//  Namen und sonst am Inhalt: Kanalkennungen beginnen mit `UC` und sind 24
//  Zeichen lang.
//

import Foundation

/// Ein YouTube-Kanal aus der Abo-Liste von Google Takeout.
public struct TakeoutChannel: Sendable, Hashable, Identifiable {
    /// `UC…`, 24 Zeichen.
    public let channelID: String
    /// Name des Kanals, wie Google ihn exportiert hat. Kann leer sein.
    public let title: String
    /// Die Seite des Kanals bei YouTube.
    public let channelURL: URL
    /// Der Atom-Feed des Kanals, über den die App ihn abonniert.
    public let feedURL: URL

    public var id: String { channelID }

    /// Der Name oder, falls Google keinen mitgegeben hat, die Kennung.
    public var displayTitle: String { title.isEmpty ? channelID : title }

    public init?(channelID: String, title: String, channelURL: URL? = nil) {
        guard SourceResolver.isValidChannelID(channelID),
              let feedURL = SourceResolver.channelFeedURL(channelID: channelID),
              let pageURL = channelURL ?? URL(string: "https://www.youtube.com/channel/\(channelID)") else {
            return nil
        }
        self.channelID = channelID
        self.title = title
        self.channelURL = pageURL
        self.feedURL = feedURL
    }
}

public enum TakeoutImportError: Error, LocalizedError, Equatable {
    case notTakeout
    case noChannels
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .notTakeout:
            String(localized: """
                In dieser Datei stehen keine YouTube-Abos. Wähle aus dem Export von Google Takeout \
                die CSV-Datei mit deinen Abos, etwa „subscriptions.csv“.
                """, bundle: .module)
        case .noChannels:
            String(localized: "In dieser Datei steht kein YouTube-Kanal.", bundle: .module)
        case .tooLarge:
            String(localized: "Die Datei ist zu groß für eine Abo-Liste.", bundle: .module)
        }
    }
}

public enum YouTubeTakeout {

    /// Obergrenze für die Datei. Eine Zeile hat etwa 100 Byte, 5 MB reichen
    /// für mehr Kanäle, als YouTube einem Konto erlaubt.
    public static let maximumBytes = 5 * 1024 * 1024
    /// Obergrenze für Kanäle je Datei.
    public static let maximumChannels = 5_000
    /// Obergrenze für den Namen eines Kanals. YouTube erlaubt 100 Zeichen;
    /// was darüber hinausgeht, stammt nicht von Google und soll weder als
    /// Suchbegriff an Apple gehen noch die Liste aufblähen.
    public static let maximumTitleLength = 200

    /// Alle Kanäle der Datei in ihrer Reihenfolge, jede Kennung nur einmal.
    /// Leere Zeilen und Zeilen ohne gültige Kennung fallen weg.
    public static func channels(in data: Data) throws -> [TakeoutChannel] {
        guard data.count <= maximumBytes else { throw TakeoutImportError.tooLarge }
        guard let text = decode(data) else { throw TakeoutImportError.notTakeout }
        let records = Self.records(in: text)
        guard let first = records.first else { throw TakeoutImportError.noChannels }

        let header = Columns(header: first)
        // Ohne erkannte Spaltennamen kann die erste Zeile schon ein Kanal sein.
        let firstIsData = header == nil && first.contains { Self.channelID(in: $0) != nil }
        let rows = firstIsData ? records : Array(records.dropFirst())
        guard var columns = header ?? Columns(content: rows, width: first.count) else {
            throw TakeoutImportError.notTakeout
        }
        columns.completeByContent(rows)
        guard columns.id != nil || columns.url != nil else { throw TakeoutImportError.notTakeout }

        var seen = Set<String>()
        var channels: [TakeoutChannel] = []
        for row in rows {
            guard let channel = columns.channel(in: row), seen.insert(channel.channelID).inserted else { continue }
            channels.append(channel)
            if channels.count == maximumChannels { break }
        }
        guard !channels.isEmpty else {
            // Spalten erkannt, aber keine Zeile mit Kanal: eine leere Liste.
            // Stand nur eine Kopfzeile ohne passende Namen da, ist es keine.
            throw header == nil && rows.isEmpty ? TakeoutImportError.notTakeout : TakeoutImportError.noChannels
        }
        return channels
    }

    // MARK: - Text

    /// UTF-8, auch mit BOM. UTF-16 nur mit BOM, so speichern manche
    /// Tabellenprogramme unter Windows. Das BOM gehört nicht zur ersten Spalte.
    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(3))
        var text: String?
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            // Tabellenprogramme unter Windows speichern oft in Windows-1252.
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
        }
        guard var text else { return nil }
        while text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        return text
    }

    /// Zerlegt CSV nach RFC 4180, nachsichtig: Felder in Anführungszeichen
    /// dürfen Trennzeichen, Zeilenumbrüche und verdoppelte Anführungszeichen
    /// enthalten, ein Anführungszeichen mitten im Feld bleibt stehen. Zeilen
    /// enden mit LF, CRLF oder CR. Leere Zeilen fallen weg.
    ///
    /// Gelesen wird Unicode-Skalar für Skalar. Als `Character` wäre CRLF ein
    /// einziges Zeichen und keinem der beiden gleich.
    static func records(in text: String) -> [[String]] {
        let scalars = Array(text.unicodeScalars)
        let delimiter = self.delimiter(in: scalars)
        let quote: Unicode.Scalar = "\""
        var records: [[String]] = []
        var record: [String] = []
        var field = String.UnicodeScalarView()
        var fieldStarted = false
        var inQuotes = false

        func endField() {
            record.append(String(field))
            field = String.UnicodeScalarView()
            fieldStarted = false
        }
        func endRecord() {
            endField()
            if record.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                records.append(record)
            }
            record = []
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if inQuotes {
                if scalar == quote {
                    if index < scalars.count, scalars[index] == quote {
                        field.append(quote)
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(scalar)
                }
                continue
            }
            switch scalar {
            case quote where !fieldStarted:
                inQuotes = true
                fieldStarted = true
            case delimiter:
                endField()
            case "\r":
                if index < scalars.count, scalars[index] == "\n" { index += 1 }
                endRecord()
            case "\n":
                endRecord()
            default:
                field.append(scalar)
                fieldStarted = true
            }
        }
        if fieldStarted || !record.isEmpty { endRecord() }
        return records
    }

    /// Komma, außer die erste Zeile trennt erkennbar mit Semikolon oder
    /// Tabulator. Gezählt wird außerhalb von Anführungszeichen.
    static func delimiter(in scalars: [Unicode.Scalar]) -> Unicode.Scalar {
        var counts: [Unicode.Scalar: Int] = [",": 0, ";": 0, "\t": 0]
        var inQuotes = false
        for scalar in scalars {
            if scalar == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if scalar == "\n" || scalar == "\r" { break }
            if counts[scalar] != nil { counts[scalar, default: 0] += 1 }
        }
        // Bei Gleichstand gewinnt das Komma, dann das Semikolon.
        var best: Unicode.Scalar = ","
        var bestCount = 0
        for candidate: Unicode.Scalar in [",", ";", "\t"] where counts[candidate, default: 0] > bestCount {
            best = candidate
            bestCount = counts[candidate, default: 0]
        }
        return best
    }

    // MARK: - Kanäle erkennen

    /// Die Kennung in einem Feld: die Kennung selbst oder eine Kanaladresse.
    static func channelID(in field: String) -> String? {
        let value = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if SourceResolver.isValidChannelID(value) { return value }
        return channelID(inURL: value)
    }

    /// `http://www.youtube.com/channel/UC…` → `UC…`. Andere Adressen zählen nicht.
    static func channelID(inURL value: String) -> String? {
        guard value.contains("/channel/"),
              case .youTubeChannel(let id, _)? = try? SourceResolver().resolve(value) else { return nil }
        return id
    }

    /// Eine Kanalseite bei YouTube aus fremden Daten, auf https gehoben.
    static func channelPageURL(_ value: String, channelID: String) -> URL? {
        guard Self.channelID(inURL: value) == channelID,
              var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        components.scheme = "https"
        return components.url
    }

    /// Ein Name in einer Zeile, ohne doppelte Leerzeichen und Umbrüche,
    /// höchstens `maximumTitleLength` Zeichen lang.
    static func cleanTitle(_ value: String) -> String {
        let words = value.prefix(maximumTitleLength * 4)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return String(words.joined(separator: " ").prefix(maximumTitleLength))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Welche Spalte was enthält.
    struct Columns: Equatable {
        var id: Int?
        var url: Int?
        var title: Int?

        static let idNames: Set<String> = ["channelid", "kanalid", "idkanal", "idofchannel"]
        static let urlNames: Set<String> = ["channelurl", "kanalurl", "urlkanal", "channellink", "kanallink"]
        static let titleNames: Set<String> = [
            "channeltitle", "channelname", "kanaltitel", "kanalname", "titel", "title", "name",
        ]

        /// Aus der Kopfzeile. `nil`, wenn weder Kennung noch Adresse am
        /// Namen erkennbar sind.
        init?(header: [String]) {
            for (index, name) in header.enumerated() {
                let key = Self.normalized(name)
                if id == nil, Self.idNames.contains(key) { id = index }
                else if url == nil, Self.urlNames.contains(key) { url = index }
                else if title == nil, Self.titleNames.contains(key) { title = index }
            }
            guard id != nil || url != nil else { return nil }
        }

        /// Allein aus dem Inhalt, etwa bei Spaltennamen in einer anderen Sprache.
        init?(content rows: [[String]], width: Int) {
            self.init()
            completeByContent(rows)
            guard id != nil || url != nil else { return nil }
            if title == nil {
                title = (0..<width).first { $0 != id && $0 != url }
            }
        }

        private init() {}

        /// Ergänzt, was die Kopfzeile nicht genannt hat.
        mutating func completeByContent(_ rows: [[String]]) {
            let sample = rows.prefix(50)
            let width = sample.map(\.count).max() ?? 0
            func share(_ column: Int, _ test: (String) -> Bool) -> Int {
                sample.filter { column < $0.count && test($0[column]) }.count
            }
            if id == nil {
                id = (0..<width).filter { $0 != url }
                    .map { ($0, share($0) { SourceResolver.isValidChannelID($0.trimmingCharacters(in: .whitespaces)) }) }
                    .filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
            }
            if url == nil {
                url = (0..<width).filter { $0 != id }
                    .map { ($0, share($0) { YouTubeTakeout.channelID(inURL: $0) != nil }) }
                    .filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
            }
            if title == nil {
                title = (0..<width).first { $0 != id && $0 != url }
            }
        }

        func channel(in row: [String]) -> TakeoutChannel? {
            func field(_ column: Int?) -> String? {
                guard let column, column < row.count else { return nil }
                return row[column]
            }
            let urlField = field(url)
            let fromID = field(id).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { SourceResolver.isValidChannelID($0) ? $0 : nil }
            guard let channelID = fromID ?? urlField.flatMap(YouTubeTakeout.channelID(inURL:)) else { return nil }
            let page = urlField.flatMap { YouTubeTakeout.channelPageURL($0, channelID: channelID) }
            return TakeoutChannel(channelID: channelID,
                                  title: YouTubeTakeout.cleanTitle(field(title) ?? ""),
                                  channelURL: page)
        }

        /// „Channel Id“, „Kanal-ID“, „channel_id“ → „channelid“, „kanalid“.
        static func normalized(_ name: String) -> String {
            name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
                .map(String.init).joined()
        }
    }
}
