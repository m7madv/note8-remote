import Foundation
import Security

enum PairingStore {
    static let service = "com.codex.note8remote.pairing"
    static func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "note8"]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw RemoteError.message("تعذّر حفظ رمز الاقتران.") }
    }
    static func load() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "note8", kSecReturnData as String: true]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func clear() { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
}

enum RemoteError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
