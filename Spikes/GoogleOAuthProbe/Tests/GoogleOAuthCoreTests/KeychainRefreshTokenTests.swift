import Foundation
import Security
import Testing
@testable import GoogleOAuthCore

@Suite("Temporary refresh-token Keychain boundary", .serialized)
struct KeychainRefreshTokenTests {
    @Test("Synthetic token uses the exact service, account, and accessibility")
    func storesAndDeletesOnlyTheExactSyntheticRecord() throws {
        let backend = RecordingKeychainBackend()
        let store = KeychainRefreshToken(backend: backend)

        try store.store("synthetic-refresh-value")
        let loaded = try store.load()
        try store.delete()

        #expect(loaded == "synthetic-refresh-value")
        #expect(backend.addedRecords == [
            KeychainRecord(
                service: "com.example.dailyplanner.spike.google-oauth",
                account: "readonly-canary",
                data: Data("synthetic-refresh-value".utf8),
                accessibility: .whenUnlockedThisDeviceOnly
            ),
        ])
        #expect(backend.readKeys == [
            KeychainKey(
                service: "com.example.dailyplanner.spike.google-oauth",
                account: "readonly-canary"
            ),
        ])
        #expect(backend.deletedKeys.allSatisfy {
            $0.service == "com.example.dailyplanner.spike.google-oauth"
                && $0.account == "readonly-canary"
        })
    }

    @Test("A returned record for another account is rejected")
    func rejectsAccountMismatch() {
        let backend = RecordingKeychainBackend()
        backend.readResult = .success(
            KeychainRecord(
                service: "com.example.dailyplanner.spike.google-oauth",
                account: "another-account",
                data: Data("synthetic-refresh-value".utf8),
                accessibility: .whenUnlockedThisDeviceOnly
            )
        )
        let store = KeychainRefreshToken(backend: backend)

        #expect(throws: KeychainRefreshTokenError.accountMismatch) {
            try store.load()
        }
    }

    @Test("Keychain denial exposes no status or token data")
    func reportsKeychainDenialSafely() {
        let backend = RecordingKeychainBackend()
        backend.addStatus = errSecAuthFailed
        let store = KeychainRefreshToken(backend: backend)

        #expect(throws: KeychainRefreshTokenError.denied) {
            try store.store("synthetic-refresh-value")
        }
        #expect(String(describing: KeychainRefreshTokenError.denied) == "denied")
    }
}

private final class RecordingKeychainBackend: KeychainBackend, @unchecked Sendable {
    var addStatus: OSStatus = errSecSuccess
    var readResult: Result<KeychainRecord, KeychainBackendError>?
    var deleteStatus: OSStatus = errSecSuccess
    var addedRecords: [KeychainRecord] = []
    var readKeys: [KeychainKey] = []
    var deletedKeys: [KeychainKey] = []

    func add(_ record: KeychainRecord) -> OSStatus {
        addedRecords.append(record)
        if addStatus == errSecSuccess {
            readResult = .success(record)
        }
        return addStatus
    }

    func read(_ key: KeychainKey) -> Result<KeychainRecord, KeychainBackendError> {
        readKeys.append(key)
        return readResult ?? .failure(.notFound)
    }

    func delete(_ key: KeychainKey) -> OSStatus {
        deletedKeys.append(key)
        if deleteStatus == errSecSuccess {
            readResult = nil
        }
        return deleteStatus
    }
}
