import Foundation
import Security

/// Stores every safebox secret value in a single generic-password Keychain item
/// whose payload is a JSON `[String: String]` (name to value).
///
/// This uses the legacy (file) keychain on purpose: the data protection keychain
/// needs an access-group entitlement that ad-hoc signed builds do not have.
struct SafeboxKeychainValueStore: Sendable {
    private let service: String
    private let account: String

    init(service: String, account: String = "values") {
        self.service = service
        self.account = account
    }

    /// Returns the stored values, or an empty dictionary when the item does not exist.
    func loadValues() throws -> [String: String] {
        var query = identity
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else {
            throw SafeboxError.keychainUnavailable(status: status)
        }
        guard let data = result as? Data else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            // errSecDecode: the stored payload is not the expected JSON.
            throw SafeboxError.keychainUnavailable(status: errSecDecode)
        }
    }

    /// Replaces the stored values, creating the item on first use.
    func saveValues(_ values: [String: String]) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(values)
        } catch {
            throw SafeboxError.keychainUnavailable(status: errSecParam)
        }
        let updateStatus = SecItemUpdate(identity as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SafeboxError.keychainUnavailable(status: updateStatus)
        }
        var insertion = identity
        insertion[kSecValueData] = data
        insertion[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(identity as CFDictionary, [kSecValueData: data] as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw SafeboxError.keychainUnavailable(status: retryStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw SafeboxError.keychainUnavailable(status: addStatus)
        }
    }

    private var identity: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
    }
}
