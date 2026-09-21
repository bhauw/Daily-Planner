import Foundation
import Security

public enum KeychainProbeError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

public struct KeychainProbe: Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func store(_ value: Data) throws {
        try delete()
        var query = baseQuery
        query[kSecValueData as String] = value
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainProbeError.unexpectedStatus(status)
        }
    }

    public func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainProbeError.unexpectedStatus(status)
        }
        return data
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainProbeError.unexpectedStatus(status)
        }
    }

    public func roundTrip(value: Data) throws -> Bool {
        try delete()
        do {
            try store(value)
            let matches = try read() == value
            try delete()
            let wasDeleted = try read() == nil
            return matches && wasDeleted
        } catch {
            try? delete()
            throw error
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
