import CoreFoundation
import DailyPlannerDomain
import Foundation
import Security

public struct GoogleOAuthKeychain: GoogleOAuthCredentialStoring, Sendable {
    private struct ClientConfigurationPayload: Codable {
        let version: Int
        let clientIdentifier: String
        let clientSecret: String
    }

    public static let service = "DailyPlanner.GoogleOAuth.v1"
    public static let clientAccount = "client-identifier"
    public static let refreshAccount = "refresh-token"

    private let caller: any KeychainCalling

    public init() {
        caller = SecurityKeychainCaller()
    }

    init(caller: any KeychainCalling) {
        self.caller = caller
    }

    public func storeClientConfiguration(_ value: GoogleOAuthClientConfiguration) throws {
        let payload = ClientConfigurationPayload(
            version: 1,
            clientIdentifier: value.clientIdentifier,
            clientSecret: value.clientSecret
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            throw GoogleOAuthCredentialStoreError.invalidValue
        }
        try replace(data, account: Self.clientAccount)
    }

    public func loadClientConfiguration() throws -> GoogleOAuthClientConfiguration? {
        guard let data = try loadData(account: Self.clientAccount) else { return nil }
        guard let payload = try? JSONDecoder().decode(ClientConfigurationPayload.self, from: data),
              payload.version == 1,
              let configuration = try? GoogleOAuthClientConfiguration(
                clientIdentifier: payload.clientIdentifier,
                clientSecret: payload.clientSecret
              ) else {
            throw GoogleOAuthCredentialStoreError.malformed
        }
        return configuration
    }

    public func storeRefreshToken(_ value: String) throws {
        guard Self.isValid(value) else {
            throw GoogleOAuthCredentialStoreError.invalidValue
        }
        try replace(Data(value.utf8), account: Self.refreshAccount)
    }

    public func loadRefreshToken() throws -> String? {
        try load(account: Self.refreshAccount)
    }

    public func deleteAll() throws {
        let clientStatus = caller.delete(Self.baseIdentity(account: Self.clientAccount) as CFDictionary)
        let refreshStatus = caller.delete(Self.baseIdentity(account: Self.refreshAccount) as CFDictionary)
        guard Self.isSuccessfulDeletion(clientStatus), Self.isSuccessfulDeletion(refreshStatus) else {
            throw GoogleOAuthCredentialStoreError.unavailable
        }
    }

    public func deleteGrant() throws {
        let status = caller.delete(Self.baseIdentity(account: Self.refreshAccount) as CFDictionary)
        guard Self.isSuccessfulDeletion(status) else {
            throw GoogleOAuthCredentialStoreError.unavailable
        }
    }

    public func presence() throws -> GoogleCredentialPresence {
        let client = try loadClientConfiguration()
        let refresh = try loadRefreshToken()
        return switch (client != nil, refresh != nil) {
        case (false, false): .none
        case (true, false): .clientOnly
        case (true, true): .complete
        case (false, true): .inconsistent
        }
    }

    private func replace(_ value: Data, account: String) throws {
        var attributes = Self.baseIdentity(account: account)
        attributes[kSecValueData as String] = value
        switch caller.add(attributes as CFDictionary, result: nil) {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateAttributes: [String: Any] = [kSecValueData as String: value]
            guard caller.update(
                Self.baseIdentity(account: account) as CFDictionary,
                attributes: updateAttributes as CFDictionary
            ) == errSecSuccess else {
                throw GoogleOAuthCredentialStoreError.unavailable
            }
        default:
            throw GoogleOAuthCredentialStoreError.unavailable
        }
    }

    private func load(account: String) throws -> String? {
        guard let data = try loadData(account: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8), Self.isValid(value) else {
            throw GoogleOAuthCredentialStoreError.malformed
        }
        return value
    }

    private func loadData(account: String) throws -> Data? {
        var result: CFTypeRef?
        switch caller.copyMatching(Self.readQuery(account: account) as CFDictionary, result: &result) {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = result as? Data else {
                throw GoogleOAuthCredentialStoreError.malformed
            }
            return data
        default:
            throw GoogleOAuthCredentialStoreError.unavailable
        }
    }

    private static func isSuccessfulDeletion(_ status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound
    }

    private static func isValid(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func baseIdentity(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readQuery(account: String) -> [String: Any] {
        var query = baseIdentity(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }
}
