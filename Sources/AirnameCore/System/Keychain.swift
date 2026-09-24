import Foundation
import Security

/// The Anthropic API key stored by `airname auth claude`, as a generic password in the login
/// keychain. The key is never written anywhere else.
public enum Keychain {
    public static let service = "dev.airname.anthropic"
    public static let account = "api-key"

    public static func readAPIKey() -> String? {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    public static func hasAPIKey() -> Bool {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    public static func storeAPIKey(_ key: String) throws {
        deleteAPIKey()
        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecAttrLabel: "airname: Anthropic API key", kSecValueData: Data(key.utf8),
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "keychain error \(status)"])
        }
    }

    @discardableResult
    public static func deleteAPIKey() -> Bool {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        return SecItemDelete(q as CFDictionary) == errSecSuccess
    }
}
