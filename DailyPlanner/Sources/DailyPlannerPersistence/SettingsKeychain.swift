import CoreFoundation
import DailyPlannerDomain
import Foundation
import Security

protocol KeychainCalling: Sendable {
    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    func add(
        _ attributes: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

struct SecurityKeychainCaller: KeychainCalling {
    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func add(
        _ attributes: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        SecItemAdd(attributes, result)
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

public struct SettingsKeychain: SettingsKeyMaterialProviding, Sendable {
    private let caller: any KeychainCalling

    public init() {
        caller = SecurityKeychainCaller()
    }

    init(caller: any KeychainCalling) {
        self.caller = caller
    }

    public func existingKeyMaterial() throws -> Data? {
        var result: CFTypeRef?
        let status = caller.copyMatching(Self.readQuery as CFDictionary, result: &result)
        switch status {
        case errSecSuccess:
            return try Self.validatedKeyMaterial(result)
        case errSecItemNotFound, errSecMissingEntitlement:
            return try existingFallbackKeyMaterial()
        default:
            throw SettingsKeychainError.unavailable
        }
    }

    public func keyMaterialForWrite() throws -> Data {
        if let existing = try existingKeyMaterial() {
            return existing
        }

        var keyMaterial = Data(count: 32)
        let randomStatus = keyMaterial.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw SettingsKeychainError.randomGenerationFailed
        }

        try store(keyMaterial, identity: Self.baseIdentity, mayFallBack: true)
        return keyMaterial
    }

    func deleteKeyMaterial() throws {
        let preferredStatus = caller.delete(Self.baseIdentity as CFDictionary)
        let fallbackStatus = caller.delete(Self.fallbackIdentity as CFDictionary)

        let preferredSucceeded = preferredStatus == errSecSuccess
            || preferredStatus == errSecItemNotFound
            || preferredStatus == errSecMissingEntitlement
        let fallbackSucceeded = fallbackStatus == errSecSuccess
            || fallbackStatus == errSecItemNotFound
        guard preferredSucceeded && fallbackSucceeded else {
            throw SettingsKeychainError.unavailable
        }
    }

    private func existingFallbackKeyMaterial() throws -> Data? {
        var result: CFTypeRef?
        let status = caller.copyMatching(Self.fallbackReadQuery as CFDictionary, result: &result)
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            return try Self.validatedKeyMaterial(result)
        default:
            throw SettingsKeychainError.unavailable
        }
    }

    private func store(
        _ keyMaterial: Data,
        identity: [String: Any],
        mayFallBack: Bool
    ) throws {
        var attributes = identity
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = keyMaterial
        let addStatus = caller.add(attributes as CFDictionary, result: nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateAttributes: [String: Any] = [kSecValueData as String: keyMaterial]
            let updateStatus = caller.update(
                identity as CFDictionary,
                attributes: updateAttributes as CFDictionary
            )
            if updateStatus == errSecSuccess {
                return
            }
            if mayFallBack, updateStatus == errSecMissingEntitlement {
                try store(keyMaterial, identity: Self.fallbackIdentity, mayFallBack: false)
                return
            }
            throw SettingsKeychainError.unavailable
        case errSecMissingEntitlement where mayFallBack:
            try store(keyMaterial, identity: Self.fallbackIdentity, mayFallBack: false)
        default:
            throw SettingsKeychainError.unavailable
        }
    }

    private static func validatedKeyMaterial(_ result: CFTypeRef?) throws -> Data {
        guard let keyMaterial = result as? Data else {
            throw SettingsKeychainError.unavailable
        }
        guard keyMaterial.count == 32 else {
            throw SettingsKeychainError.invalidLength
        }
        return keyMaterial
    }

    private static var fallbackIdentity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "DailyPlanner.PrivateSettings.v1",
            kSecAttrAccount as String: "envelope-key",
            kSecAttrSynchronizable as String: false,
        ]
    }

    private static var fallbackReadQuery: [String: Any] {
        var query = fallbackIdentity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    private static var baseIdentity: [String: Any] {
        var identity = fallbackIdentity
        identity[kSecUseDataProtectionKeychain as String] = true
        return identity
    }

    private static var readQuery: [String: Any] {
        var query = baseIdentity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }
}
