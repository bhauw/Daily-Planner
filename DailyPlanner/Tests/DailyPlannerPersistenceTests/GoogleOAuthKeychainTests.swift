import CoreFoundation
import Foundation
import Security
import XCTest
@testable import DailyPlannerDomain
@testable import DailyPlannerPersistence

final class GoogleOAuthKeychainTests: XCTestCase {
    private func assertClientConfigurationRoundTripsAsOneVersionedKeychainItem() throws {
        let configuration = try GoogleOAuthClientConfiguration(
            clientIdentifier: "synthetic-client.apps.example.test",
            clientSecret: "synthetic-secret-canary"
        )
        let caller = ScriptedGoogleKeychainCaller()
        let store = GoogleOAuthKeychain(caller: caller)

        try store.storeClientConfiguration(configuration)

        let add = try XCTUnwrap(caller.addedData(account: "client-identifier"))
        let decoderCaller = ScriptedGoogleKeychainCaller(values: ["client-identifier": add])
        XCTAssertEqual(
            try GoogleOAuthKeychain(caller: decoderCaller).loadClientConfiguration(),
            configuration
        )
        XCTAssertEqual(caller.recordedCalls().count, 1)
    }

    func testClientIdentifierAndRefreshTokenUseOnlyExactDeviceLocalRecords() throws {
        try assertClientConfigurationRoundTripsAsOneVersionedKeychainItem()
        let caller = ScriptedGoogleKeychainCaller()
        let store = GoogleOAuthKeychain(caller: caller)

        try store.storeClientConfiguration(syntheticClientConfiguration())
        try store.storeRefreshToken("synthetic-refresh-canary")

        XCTAssertEqual(caller.recordedCalls(), [
            .add(googleAddSnapshot(account: "client-identifier", dataLength: 110)),
            .add(googleAddSnapshot(account: "refresh-token", dataLength: 24)),
        ])
    }

    func testDuplicateAddUpdatesOnlyExactIdentityAndValueData() throws {
        let caller = ScriptedGoogleKeychainCaller(mutationStatuses: [errSecDuplicateItem, errSecSuccess])

        try GoogleOAuthKeychain(caller: caller).storeClientConfiguration(syntheticClientConfiguration())

        XCTAssertEqual(caller.recordedCalls(), [
            .add(googleAddSnapshot(account: "client-identifier", dataLength: 110)),
            .update(
                match: googleBaseSnapshot(account: "client-identifier"),
                attributes: GoogleKeychainSnapshot(values: [kSecValueData as String: .dataLength(110)])
            ),
        ])
    }

    func testLoadsUseOnlyExactReadQueries() throws {
        let caller = ScriptedGoogleKeychainCaller(
            values: [
                "client-identifier": syntheticClientPayload(),
                "refresh-token": Data("synthetic-refresh-canary".utf8),
            ]
        )
        let store = GoogleOAuthKeychain(caller: caller)

        XCTAssertNotNil(try store.loadClientConfiguration())
        XCTAssertNotNil(try store.loadRefreshToken())

        XCTAssertEqual(caller.recordedCalls(), [
            .copy(googleReadSnapshot(account: "client-identifier")),
            .copy(googleReadSnapshot(account: "refresh-token")),
        ])
    }

    func testMissingReadsReturnNil() throws {
        let caller = ScriptedGoogleKeychainCaller()
        let store = GoogleOAuthKeychain(caller: caller)

        XCTAssertNil(try store.loadClientConfiguration())
        XCTAssertNil(try store.loadRefreshToken())
    }

    func testPresenceDistinguishesNoneClientOnlyCompleteAndInconsistent() throws {
        XCTAssertEqual(try makeStore(client: nil, refresh: nil).presence(), .none)
        XCTAssertEqual(try makeStore(client: "client", refresh: nil).presence(), .clientOnly)
        XCTAssertEqual(try makeStore(client: "client", refresh: "refresh").presence(), .complete)
        XCTAssertEqual(try makeStore(client: nil, refresh: "refresh").presence(), .inconsistent)
    }

    func testPresenceUsesExactlyTwoReads() throws {
        let caller = ScriptedGoogleKeychainCaller()

        XCTAssertEqual(try GoogleOAuthKeychain(caller: caller).presence(), .none)

        XCTAssertEqual(caller.recordedCalls(), [
            .copy(googleReadSnapshot(account: "client-identifier")),
            .copy(googleReadSnapshot(account: "refresh-token")),
        ])
    }

    func testRejectsEmptyAndControlContainingValues() {
        for value in ["", "contains\ncontrol"] {
            XCTAssertThrowsError(try GoogleOAuthClientConfiguration(
                clientIdentifier: value,
                clientSecret: "valid-secret"
            )) { error in
                XCTAssertEqual(error as? GoogleOAuthCredentialStoreError, .invalidValue)
            }
            XCTAssertThrowsError(try GoogleOAuthKeychain(caller: ScriptedGoogleKeychainCaller()).storeRefreshToken(value)) { error in
                XCTAssertEqual(error as? GoogleOAuthCredentialStoreError, .invalidValue)
            }
        }
    }

    func testDeniedAndUnexpectedStatusesMapToUnavailable() {
        let deniedRead = ScriptedGoogleKeychainCaller(copyStatuses: ["client-identifier": errSecAuthFailed])
        assertUnavailable { try GoogleOAuthKeychain(caller: deniedRead).loadClientConfiguration() }

        let deniedAdd = ScriptedGoogleKeychainCaller(mutationStatuses: [errSecAuthFailed])
        assertUnavailable {
            try GoogleOAuthKeychain(caller: deniedAdd)
                .storeClientConfiguration(syntheticClientConfiguration())
        }

        let deniedUpdate = ScriptedGoogleKeychainCaller(mutationStatuses: [errSecDuplicateItem, errSecAuthFailed])
        assertUnavailable {
            try GoogleOAuthKeychain(caller: deniedUpdate)
                .storeClientConfiguration(syntheticClientConfiguration())
        }

        let deniedDelete = ScriptedGoogleKeychainCaller(mutationStatuses: [errSecAuthFailed, errSecSuccess])
        assertUnavailable { try GoogleOAuthKeychain(caller: deniedDelete).deleteAll() }
    }

    func testMalformedSuccessfulDataMapsToMalformed() {
        let malformedValues: [Data?] = [nil, Data(), Data([0xFF]), Data("contains\u{7F}control".utf8)]
        for value in malformedValues {
            let caller = ScriptedGoogleKeychainCaller(
                values: ["client-identifier": value],
                copyStatuses: ["client-identifier": errSecSuccess]
            )
            XCTAssertThrowsError(try GoogleOAuthKeychain(caller: caller).loadClientConfiguration()) { error in
                XCTAssertEqual(error as? GoogleOAuthCredentialStoreError, .malformed)
            }
        }

        let legacy = Data("synthetic-client.apps.example.test".utf8)
        let caller = ScriptedGoogleKeychainCaller(
            values: ["client-identifier": legacy],
            mutationStatuses: [errSecDuplicateItem, errSecSuccess]
        )
        let store = GoogleOAuthKeychain(caller: caller)
        XCTAssertThrowsError(try store.presence()) { error in
            XCTAssertEqual(error as? GoogleOAuthCredentialStoreError, .malformed)
        }
        XCTAssertNoThrow(try store.storeClientConfiguration(try GoogleOAuthClientConfiguration(
            clientIdentifier: "replacement-client.apps.example.test",
            clientSecret: "replacement-secret-canary"
        )))
    }

    func testDeleteAllAttemptsBothExactAccountsAndIsIdempotent() throws {
        let caller = ScriptedGoogleKeychainCaller(mutationStatuses: [errSecItemNotFound, errSecSuccess])
        try GoogleOAuthKeychain(caller: caller).deleteAll()

        XCTAssertEqual(caller.recordedCalls(), [
            .delete(googleBaseSnapshot(account: "client-identifier")),
            .delete(googleBaseSnapshot(account: "refresh-token")),
        ])
    }

    func testDeleteAllAttemptsSecondAccountBeforeReportingFailure() {
        let caller = ScriptedGoogleKeychainCaller(mutationStatuses: [errSecAuthFailed, errSecAuthFailed])

        assertUnavailable { try GoogleOAuthKeychain(caller: caller).deleteAll() }

        XCTAssertEqual(caller.recordedCalls(), [
            .delete(googleBaseSnapshot(account: "client-identifier")),
            .delete(googleBaseSnapshot(account: "refresh-token")),
        ])
    }

    private func makeStore(client: String?, refresh: String?) -> GoogleOAuthKeychain {
        let values = [
            "client-identifier": client.map { value in
                Data(#"{"version":1,"clientIdentifier":"\#(value)","clientSecret":"secret"}"#.utf8)
            },
            "refresh-token": refresh.map { Data($0.utf8) },
        ]
        return GoogleOAuthKeychain(caller: ScriptedGoogleKeychainCaller(values: values))
    }

    private func assertUnavailable(
        _ operation: () throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? GoogleOAuthCredentialStoreError, .unavailable, file: file, line: line)
        }
    }
}

private func syntheticClientConfiguration() throws -> GoogleOAuthClientConfiguration {
    try GoogleOAuthClientConfiguration(
        clientIdentifier: "synthetic-client.apps.example.test",
        clientSecret: "synthetic-secret-canary"
    )
}

private func syntheticClientPayload() -> Data {
    Data(#"{"version":1,"clientIdentifier":"synthetic-client.apps.example.test","clientSecret":"synthetic-secret-canary"}"#.utf8)
}

private func googleBaseSnapshot(account: String) -> GoogleKeychainSnapshot {
    GoogleKeychainSnapshot(values: [
        kSecClass as String: .string(kSecClassGenericPassword as String),
        kSecAttrService as String: .string("DailyPlanner.GoogleOAuth.v1"),
        kSecAttrAccount as String: .string(account),
    ])
}

private func googleReadSnapshot(account: String) -> GoogleKeychainSnapshot {
    googleBaseSnapshot(account: account).adding([
        kSecReturnData as String: .bool(true),
        kSecMatchLimit as String: .string(kSecMatchLimitOne as String),
    ])
}

private func googleAddSnapshot(account: String, dataLength: Int) -> GoogleKeychainSnapshot {
    googleBaseSnapshot(account: account).adding([
        kSecValueData as String: .dataLength(dataLength),
    ])
}

private enum GoogleKeychainSnapshotValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case dataLength(Int)
}

private struct GoogleKeychainSnapshot: Equatable, Sendable {
    let values: [String: GoogleKeychainSnapshotValue]

    func adding(_ additions: [String: GoogleKeychainSnapshotValue]) -> GoogleKeychainSnapshot {
        GoogleKeychainSnapshot(values: values.merging(additions) { _, new in new })
    }
}

private enum GoogleRecordedKeychainCall: Equatable, Sendable {
    case copy(GoogleKeychainSnapshot)
    case add(GoogleKeychainSnapshot)
    case update(match: GoogleKeychainSnapshot, attributes: GoogleKeychainSnapshot)
    case delete(GoogleKeychainSnapshot)
}

private final class ScriptedGoogleKeychainCaller: KeychainCalling, @unchecked Sendable {
    private let lock = NSLock()
    private let values: [String: Data?]
    private let copyStatuses: [String: OSStatus]
    private var mutationStatuses: [OSStatus]
    private var calls: [GoogleRecordedKeychainCall] = []
    private var addedValues: [String: Data] = [:]

    init(
        values: [String: Data?] = [:],
        copyStatuses: [String: OSStatus] = [:],
        mutationStatuses: [OSStatus] = [errSecSuccess]
    ) {
        self.values = values
        self.copyStatuses = copyStatuses
        self.mutationStatuses = mutationStatuses
    }

    func recordedCalls() -> [GoogleRecordedKeychainCall] {
        lock.withLock { calls }
    }

    func addedData(account: String) -> Data? {
        lock.withLock { addedValues[account] }
    }

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lock.withLock {
            let account = requiredAccount(in: query)
            calls.append(.copy(snapshot(query)))
            let storedData = values[account] ?? nil
            let status = copyStatuses[account] ?? (storedData == nil ? errSecItemNotFound : errSecSuccess)
            if status == errSecSuccess, let data = storedData, let result {
                result.pointee = Unmanaged.passRetained(data as CFData).takeRetainedValue()
            }
            return status
        }
    }

    func add(_ attributes: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lock.withLock {
            let account = requiredAccount(in: attributes)
            calls.append(.add(snapshot(attributes)))
            if let data = (attributes as NSDictionary)[kSecValueData as String] as? Data {
                addedValues[account] = data
            }
            return nextMutationStatus()
        }
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        lock.withLock {
            _ = requiredAccount(in: query)
            calls.append(.update(match: snapshot(query), attributes: snapshot(attributes)))
            return nextMutationStatus()
        }
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        lock.withLock {
            _ = requiredAccount(in: query)
            calls.append(.delete(snapshot(query)))
            return nextMutationStatus()
        }
    }

    private func requiredAccount(in dictionary: CFDictionary) -> String {
        let values = dictionary as NSDictionary
        guard let account = values[kSecAttrAccount as String] as? String else {
            preconditionFailure("Missing expected account")
        }
        precondition(["client-identifier", "refresh-token"].contains(account), "Unexpected Keychain account")
        return account
    }

    private func nextMutationStatus() -> OSStatus {
        precondition(!mutationStatuses.isEmpty, "Missing synthetic mutation status")
        if mutationStatuses.count == 1 { return mutationStatuses[0] }
        return mutationStatuses.removeFirst()
    }

    private func snapshot(_ dictionary: CFDictionary) -> GoogleKeychainSnapshot {
        let values = dictionary as NSDictionary
        var snapshotValues: [String: GoogleKeychainSnapshotValue] = [:]
        for (key, value) in values {
            guard let key = key as? String else { preconditionFailure("Unexpected Keychain key type") }
            switch value {
            case let value as String:
                snapshotValues[key] = .string(value)
            case let value as Data:
                snapshotValues[key] = .dataLength(value.count)
            case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID():
                snapshotValues[key] = .bool(value.boolValue)
            default:
                preconditionFailure("Unexpected Keychain value type")
            }
        }
        return GoogleKeychainSnapshot(values: snapshotValues)
    }
}
