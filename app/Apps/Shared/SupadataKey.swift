//
//  SupadataKey.swift
//  PodcastAI
//
//  Der eigene Supadata-Schlüssel des Nutzers, im Schlüsselbund.
//
//  Die App bringt keinen Schlüssel mit. Wer bei Supadata ein Konto hat,
//  trägt seinen Schlüssel in den Einstellungen ein. Er liegt dann nur hier:
//  im Schlüsselbund mit Datenschutzklasse, nur auf diesem Gerät, nicht
//  synchronisiert, nicht im Backup auf ein anderes Gerät. Nie in den
//  Benutzereinstellungen, nie in iCloud, nie im Protokoll und nie in einem
//  Export.
//

import Foundation
import Security

enum SupadataKeychain {

    private static let service = "com.godmodeai.podcastai.supadata"
    private static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// Der gespeicherte Schlüssel, oder `nil`.
    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    static var hasKey: Bool { read() != nil }

    /// Speichert oder ersetzt den Schlüssel. `false`, wenn der Schlüsselbund
    /// ihn nicht annimmt.
    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let data = Data(trimmed.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = baseQuery
        add[kSecValueData as String] = data
        // Auch im Hintergrund lesbar, sobald das Gerät einmal entsperrt war:
        // die Warteschlange arbeitet dort weiter.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// Was „Prüfen“ in den Einstellungen ergeben hat.
enum SupadataKeyCheck: Equatable {
    case idle
    case checking
    /// Angenommen. `credits`: verbraucht und verfügbar in diesem Zeitraum, falls bekannt.
    case valid(used: Int?, max: Int?)
    /// Angenommen, aber das Kontingent ist aufgebraucht.
    case exhausted
    case rejected
    /// Keine Antwort, etwa ohne Netz. Über den Schlüssel sagt das nichts.
    case unreachable
}
