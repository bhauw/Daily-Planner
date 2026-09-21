import Foundation
import Security

public enum KeychainAccessibility: Equatable, Sendable {
    case whenUnlockedThisDeviceOnly
}

public struct KeychainKey: Equatable, Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

public struct KeychainRecord: Equatable, Sendable {
    public let service: String
    public let account: String
    public let data: Data
    public let accessibility: KeychainAccessibility

    public init(service: String, account: String, data: Data, accessibility: KeychainAccessibility) {
        self.service = service
        self.account = account
        self.data = data
        self.accessibility = accessibility
    }
}

public enum KeychainBackendError: Error, Equatable, Sendable {
    case notFound
    case denied
    case malformedResult
    case unexpectedFailure
}

public protocol KeychainBackend: Sendable {
    func add(_ record: KeychainRecord) -> OSStatus
    func read(_ key: KeychainKey) -> Result<KeychainRecord, KeychainBackendError>
    func delete(_ key: KeychainKey) -> OSStatus
}

public struct SecurityKeychainBackend: KeychainBackend {
    public init() {}

    public func add(_ record: KeychainRecord) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: record.service,
            kSecAttrAccount as String: record.account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: record.data,
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }

    public func read(_ key: KeychainKey) -> Result<KeychainRecord, KeychainBackendError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return .failure(Self.backendError(for: status))
        }
        guard let values = item as? [String: Any],
              let service = values[kSecAttrService as String] as? String,
              let account = values[kSecAttrAccount as String] as? String,
              let data = values[kSecValueData as String] as? Data else {
            return .failure(.malformedResult)
        }
        return .success(
            KeychainRecord(
                service: service,
                account: account,
                data: data,
                accessibility: .whenUnlockedThisDeviceOnly
            )
        )
    }

    public func delete(_ key: KeychainKey) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
        ]
        return SecItemDelete(query as CFDictionary)
    }

    private static func backendError(for status: OSStatus) -> KeychainBackendError {
        switch status {
        case errSecItemNotFound:
            .notFound
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            .denied
        default:
            .unexpectedFailure
        }
    }
}

public enum KeychainRefreshTokenError: Error, Equatable, Sendable {
    case denied
    case notFound
    case accountMismatch
    case invalidToken
    case unexpectedFailure
}

public final class KeychainRefreshToken: @unchecked Sendable {
    public static let service = "com.example.dailyplanner.spike.google-oauth"
    public static let account = "readonly-canary"

    private let backend: any KeychainBackend
    private let key = KeychainKey(service: service, account: account)

    public init(backend: any KeychainBackend = SecurityKeychainBackend()) {
        self.backend = backend
    }

    public func store(_ token: String) throws {
        guard !token.isEmpty else { throw KeychainRefreshTokenError.invalidToken }
        let deleteStatus = backend.delete(key)
        try Self.checkMutationStatus(deleteStatus, allowingNotFound: true)
        let record = KeychainRecord(
            service: key.service,
            account: key.account,
            data: Data(token.utf8),
            accessibility: .whenUnlockedThisDeviceOnly
        )
        try Self.checkMutationStatus(backend.add(record), allowingNotFound: false)
    }

    public func load() throws -> String {
        switch backend.read(key) {
        case let .success(record):
            guard record.service == key.service, record.account == key.account else {
                throw KeychainRefreshTokenError.accountMismatch
            }
            guard let token = String(data: record.data, encoding: .utf8), !token.isEmpty else {
                throw KeychainRefreshTokenError.invalidToken
            }
            return token
        case .failure(.notFound):
            throw KeychainRefreshTokenError.notFound
        case .failure(.denied):
            throw KeychainRefreshTokenError.denied
        case .failure:
            throw KeychainRefreshTokenError.unexpectedFailure
        }
    }

    public func delete() throws {
        try Self.checkMutationStatus(backend.delete(key), allowingNotFound: true)
    }

    private static func checkMutationStatus(_ status: OSStatus, allowingNotFound: Bool) throws {
        if status == errSecSuccess || (allowingNotFound && status == errSecItemNotFound) {
            return
        }
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed || status == errSecUserCanceled {
            throw KeychainRefreshTokenError.denied
        }
        throw KeychainRefreshTokenError.unexpectedFailure
    }
}
