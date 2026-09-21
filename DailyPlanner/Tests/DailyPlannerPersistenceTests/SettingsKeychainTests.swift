import CoreFoundation
import Foundation
import Security
import XCTest
@testable import DailyPlannerDomain
@testable import DailyPlannerPersistence

final class SettingsKeychainTests: XCTestCase {
    func testExistingKeyUsesExactFixedReadQuery() throws {
        let caller = RecordingKeychainCaller(copyStatus: errSecSuccess, copyData: Data(repeating: 0x31, count: 32))
        let keychain = SettingsKeychain(caller: caller)

        let result = try keychain.existingKeyMaterial()

        XCTAssertEqual(result?.count, 32)
        XCTAssertEqual(caller.recordedCalls(), [.copy(readSnapshot)])
    }

    func testMissingPreferredAndFallbackKeysReturnNilAfterTwoReads() throws {
        let caller = RecordingKeychainCaller()
        let keychain = SettingsKeychain(caller: caller)

        XCTAssertNil(try keychain.existingKeyMaterial())
        XCTAssertEqual(caller.recordedCalls(), [.copy(readSnapshot), .copy(fallbackReadSnapshot)])
    }

    func testWriteGeneratesAndAddsA32ByteDeviceOnlyKey() throws {
        let caller = RecordingKeychainCaller()
        let keychain = SettingsKeychain(caller: caller)

        let key = try keychain.keyMaterialForWrite()

        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(caller.recordedCalls(), [
            .copy(readSnapshot),
            .copy(fallbackReadSnapshot),
            .add(addSnapshot),
        ])
    }

    func testWriteReturnsExistingKeyWithoutMutation() throws {
        let caller = RecordingKeychainCaller(copyStatus: errSecSuccess, copyData: Data(repeating: 0x31, count: 32))
        let keychain = SettingsKeychain(caller: caller)

        let key = try keychain.keyMaterialForWrite()

        XCTAssertEqual(key, Data(repeating: 0x31, count: 32))
        XCTAssertEqual(caller.recordedCalls(), [.copy(readSnapshot)])
    }

    func testDuplicateAddUpdatesOnlyThe32ByteValueAtTheFixedIdentity() throws {
        let caller = RecordingKeychainCaller(mutationStatuses: [errSecDuplicateItem, errSecSuccess])
        let keychain = SettingsKeychain(caller: caller)

        let key = try keychain.keyMaterialForWrite()

        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(caller.recordedCalls(), [
            .copy(readSnapshot),
            .copy(fallbackReadSnapshot),
            .add(addSnapshot),
            .update(match: baseSnapshot, attributes: updateSnapshot),
        ])
    }

    func testDeleteUsesOnlyTheFixedIdentityAndMissingIsIdempotent() throws {
        let successCaller = RecordingKeychainCaller()
        try SettingsKeychain(caller: successCaller).deleteKeyMaterial()
        XCTAssertEqual(successCaller.recordedCalls(), [
            .delete(baseSnapshot),
            .delete(fallbackBaseSnapshot),
        ])

        let missingCaller = RecordingKeychainCaller(mutationStatus: errSecItemNotFound)
        try SettingsKeychain(caller: missingCaller).deleteKeyMaterial()
        XCTAssertEqual(missingCaller.recordedCalls(), [
            .delete(baseSnapshot),
            .delete(fallbackBaseSnapshot),
        ])
    }

    func testMissingPreferredItemReadsExistingFallbackAfterRestart() throws {
        let fallbackKey = Data(repeating: 0x42, count: 32)
        let caller = RecordingKeychainCaller(copyResponses: [
            (errSecItemNotFound, nil),
            (errSecSuccess, fallbackKey),
        ])

        XCTAssertEqual(try SettingsKeychain(caller: caller).existingKeyMaterial(), fallbackKey)
        XCTAssertEqual(caller.recordedCalls(), [
            .copy(readSnapshot),
            .copy(fallbackReadSnapshot),
        ])
    }

    func testMissingEntitlementReadsExistingFallback() throws {
        let fallbackKey = Data(repeating: 0x43, count: 32)
        let caller = RecordingKeychainCaller(copyResponses: [
            (errSecMissingEntitlement, nil),
            (errSecSuccess, fallbackKey),
        ])

        XCTAssertEqual(try SettingsKeychain(caller: caller).existingKeyMaterial(), fallbackKey)
        XCTAssertEqual(caller.recordedCalls(), [
            .copy(readSnapshot),
            .copy(fallbackReadSnapshot),
        ])
    }

    func testFallbackReadRejectsMalformedKeyLength() {
        let caller = RecordingKeychainCaller(copyResponses: [
            (errSecItemNotFound, nil),
            (errSecSuccess, Data(repeating: 0x44, count: 31)),
        ])

        XCTAssertThrowsError(try SettingsKeychain(caller: caller).existingKeyMaterial()) { error in
            XCTAssertEqual(error as? SettingsKeychainError, .invalidLength)
        }
        XCTAssertEqual(caller.recordedCalls(), [
            .copy(readSnapshot),
            .copy(fallbackReadSnapshot),
        ])
    }

    func testArbitraryPreferredReadErrorDoesNotFallBack() {
        let caller = RecordingKeychainCaller(copyStatus: errSecAuthFailed)

        assertUnavailable { try SettingsKeychain(caller: caller).existingKeyMaterial() }
        XCTAssertEqual(caller.recordedCalls(), [.copy(readSnapshot)])
    }

    func testFallbackReadErrorMapsToFiniteUnavailableError() {
        let caller = RecordingKeychainCaller(copyResponses: [
            (errSecItemNotFound, nil),
            (errSecAuthFailed, nil),
        ])

        assertUnavailable { try SettingsKeychain(caller: caller).existingKeyMaterial() }
        XCTAssertEqual(caller.recordedCalls(), [
            .copy(readSnapshot),
            .copy(fallbackReadSnapshot),
        ])
    }

    func testMissingEntitlementOnPreferredAddStoresDeviceOnlyFallbackKey() throws {
        let caller = RecordingKeychainCaller(
            copyResponses: [(errSecMissingEntitlement, nil), (errSecItemNotFound, nil)],
            mutationStatuses: [errSecMissingEntitlement, errSecSuccess]
        )

        let key = try SettingsKeychain(caller: caller).keyMaterialForWrite()

        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(caller.recordedCalls(), [
            .copy(readSnapshot),
            .copy(fallbackReadSnapshot),
            .add(addSnapshot),
            .add(fallbackAddSnapshot),
        ])
    }

    func testDuplicateFallbackAddUpdatesOnlyValueAtFallbackIdentity() throws {
        let caller = RecordingKeychainCaller(
            copyResponses: [(errSecMissingEntitlement, nil), (errSecItemNotFound, nil)],
            mutationStatuses: [errSecMissingEntitlement, errSecDuplicateItem, errSecSuccess]
        )

        let key = try SettingsKeychain(caller: caller).keyMaterialForWrite()

        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(caller.recordedCalls(), [
            .copy(readSnapshot),
            .copy(fallbackReadSnapshot),
            .add(addSnapshot),
            .add(fallbackAddSnapshot),
            .update(match: fallbackBaseSnapshot, attributes: updateSnapshot),
        ])
    }

    func testMissingEntitlementOnPreferredUpdateStoresFallbackKey() throws {
        let caller = RecordingKeychainCaller(
            copyResponses: [(errSecItemNotFound, nil), (errSecItemNotFound, nil)],
            mutationStatuses: [errSecDuplicateItem, errSecMissingEntitlement, errSecSuccess]
        )

        let key = try SettingsKeychain(caller: caller).keyMaterialForWrite()

        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(caller.recordedCalls(), [
            .copy(readSnapshot),
            .copy(fallbackReadSnapshot),
            .add(addSnapshot),
            .update(match: baseSnapshot, attributes: updateSnapshot),
            .add(fallbackAddSnapshot),
        ])
    }

    func testArbitraryPreferredAddErrorDoesNotFallBack() {
        let caller = RecordingKeychainCaller(mutationStatus: errSecAuthFailed)

        assertUnavailable { try SettingsKeychain(caller: caller).keyMaterialForWrite() }
        XCTAssertEqual(caller.recordedCalls(), [
            .copy(readSnapshot),
            .copy(fallbackReadSnapshot),
            .add(addSnapshot),
        ])
    }

    func testFallbackAddAndUpdateErrorsMapToFiniteUnavailableError() {
        let deniedAdd = RecordingKeychainCaller(
            copyResponses: [(errSecMissingEntitlement, nil), (errSecItemNotFound, nil)],
            mutationStatuses: [errSecMissingEntitlement, errSecAuthFailed]
        )
        assertUnavailable { try SettingsKeychain(caller: deniedAdd).keyMaterialForWrite() }

        let deniedUpdate = RecordingKeychainCaller(
            copyResponses: [(errSecMissingEntitlement, nil), (errSecItemNotFound, nil)],
            mutationStatuses: [errSecMissingEntitlement, errSecDuplicateItem, errSecAuthFailed]
        )
        assertUnavailable { try SettingsKeychain(caller: deniedUpdate).keyMaterialForWrite() }
    }

    func testDeleteFallsBackOnlyForMissingEntitlementAndFallbackErrorsRemainFinite() throws {
        let fallbackCaller = RecordingKeychainCaller(
            mutationStatuses: [errSecMissingEntitlement, errSecSuccess]
        )
        try SettingsKeychain(caller: fallbackCaller).deleteKeyMaterial()
        XCTAssertEqual(fallbackCaller.recordedCalls(), [
            .delete(baseSnapshot),
            .delete(fallbackBaseSnapshot),
        ])

        let deniedPreferred = RecordingKeychainCaller(mutationStatus: errSecAuthFailed)
        assertUnavailable { try SettingsKeychain(caller: deniedPreferred).deleteKeyMaterial() }
        XCTAssertEqual(deniedPreferred.recordedCalls(), [
            .delete(baseSnapshot),
            .delete(fallbackBaseSnapshot),
        ])

        let deniedFallback = RecordingKeychainCaller(
            mutationStatuses: [errSecSuccess, errSecAuthFailed]
        )
        assertUnavailable { try SettingsKeychain(caller: deniedFallback).deleteKeyMaterial() }
        XCTAssertEqual(deniedFallback.recordedCalls(), [
            .delete(baseSnapshot),
            .delete(fallbackBaseSnapshot),
        ])
    }

    func testCorruptKeyLengthMapsToFiniteInvalidLengthError() {
        let caller = RecordingKeychainCaller(copyStatus: errSecSuccess, copyData: Data(repeating: 0x31, count: 31))

        XCTAssertThrowsError(try SettingsKeychain(caller: caller).existingKeyMaterial()) { error in
            XCTAssertEqual(error as? SettingsKeychainError, .invalidLength)
        }
    }

    func testDeniedReadAddUpdateAndDeleteMapToFiniteUnavailableError() {
        let deniedRead = RecordingKeychainCaller(copyStatus: errSecAuthFailed)
        assertUnavailable { try SettingsKeychain(caller: deniedRead).existingKeyMaterial() }

        let deniedAdd = RecordingKeychainCaller(mutationStatus: errSecAuthFailed)
        assertUnavailable { try SettingsKeychain(caller: deniedAdd).keyMaterialForWrite() }

        let deniedUpdate = RecordingKeychainCaller(mutationStatuses: [errSecDuplicateItem, errSecAuthFailed])
        assertUnavailable { try SettingsKeychain(caller: deniedUpdate).keyMaterialForWrite() }

        let deniedDelete = RecordingKeychainCaller(mutationStatus: errSecAuthFailed)
        assertUnavailable { try SettingsKeychain(caller: deniedDelete).deleteKeyMaterial() }
    }

    private func assertUnavailable(
        _ operation: () throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? SettingsKeychainError, .unavailable, file: file, line: line)
        }
    }
}

private let baseValues: [String: KeychainSnapshotValue] = [
    kSecClass as String: .string(kSecClassGenericPassword as String),
    kSecAttrService as String: .string("DailyPlanner.PrivateSettings.v1"),
    kSecAttrAccount as String: .string("envelope-key"),
    kSecUseDataProtectionKeychain as String: .bool(true),
    kSecAttrSynchronizable as String: .bool(false),
]

private let baseSnapshot = KeychainQuerySnapshot(values: baseValues)
private let readSnapshot = KeychainQuerySnapshot(values: baseValues.merging([
    kSecReturnData as String: .bool(true),
    kSecMatchLimit as String: .string(kSecMatchLimitOne as String),
]) { _, new in new })
private let addSnapshot = KeychainQuerySnapshot(values: baseValues.merging([
    kSecAttrAccessible as String: .string(kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String),
    kSecValueData as String: .dataLength(32),
]) { _, new in new })
private let updateSnapshot = KeychainQuerySnapshot(values: [
    kSecValueData as String: .dataLength(32),
])
private let fallbackBaseValues: [String: KeychainSnapshotValue] = [
    kSecClass as String: .string(kSecClassGenericPassword as String),
    kSecAttrService as String: .string("DailyPlanner.PrivateSettings.v1"),
    kSecAttrAccount as String: .string("envelope-key"),
    kSecAttrSynchronizable as String: .bool(false),
]
private let fallbackBaseSnapshot = KeychainQuerySnapshot(values: fallbackBaseValues)
private let fallbackReadSnapshot = KeychainQuerySnapshot(values: fallbackBaseValues.merging([
    kSecReturnData as String: .bool(true),
    kSecMatchLimit as String: .string(kSecMatchLimitOne as String),
]) { _, new in new })
private let fallbackAddSnapshot = KeychainQuerySnapshot(values: fallbackBaseValues.merging([
    kSecAttrAccessible as String: .string(kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String),
    kSecValueData as String: .dataLength(32),
]) { _, new in new })

enum KeychainSnapshotValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case dataLength(Int)
}

struct KeychainQuerySnapshot: Equatable, Sendable {
    let values: [String: KeychainSnapshotValue]
}

enum RecordedKeychainCall: Equatable, Sendable {
    case copy(KeychainQuerySnapshot)
    case add(KeychainQuerySnapshot)
    case update(match: KeychainQuerySnapshot, attributes: KeychainQuerySnapshot)
    case delete(KeychainQuerySnapshot)
}

final class RecordingKeychainCaller: KeychainCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var copyResponses: [(status: OSStatus, data: Data?)]
    private var mutationStatuses: [OSStatus]
    private var calls: [RecordedKeychainCall] = []

    init(
        copyStatus: OSStatus = errSecItemNotFound,
        copyData: Data? = nil,
        mutationStatus: OSStatus = errSecSuccess
    ) {
        self.copyResponses = [(copyStatus, copyData)]
        self.mutationStatuses = [mutationStatus]
    }

    init(
        copyStatus: OSStatus = errSecItemNotFound,
        copyData: Data? = nil,
        mutationStatuses: [OSStatus]
    ) {
        self.copyResponses = [(copyStatus, copyData)]
        self.mutationStatuses = mutationStatuses
    }

    init(
        copyResponses: [(OSStatus, Data?)],
        mutationStatuses: [OSStatus] = [errSecSuccess]
    ) {
        self.copyResponses = copyResponses
        self.mutationStatuses = mutationStatuses
    }

    func recordedCalls() -> [RecordedKeychainCall] {
        lock.withLock { calls }
    }

    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        lock.withLock {
            calls.append(.copy(snapshot(query)))
            let response = nextCopyResponse()
            if response.status == errSecSuccess, let data = response.data, let result {
                result.pointee = Unmanaged.passRetained(data as CFData).takeRetainedValue()
            }
            return response.status
        }
    }

    func add(
        _ attributes: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        lock.withLock {
            calls.append(.add(snapshot(attributes)))
            return nextMutationStatus()
        }
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        lock.withLock {
            calls.append(.update(match: snapshot(query), attributes: snapshot(attributes)))
            return nextMutationStatus()
        }
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        lock.withLock {
            calls.append(.delete(snapshot(query)))
            return nextMutationStatus()
        }
    }

    private func nextMutationStatus() -> OSStatus {
        precondition(!mutationStatuses.isEmpty, "Missing synthetic mutation status")
        if mutationStatuses.count == 1 {
            return mutationStatuses[0]
        }
        return mutationStatuses.removeFirst()
    }

    private func nextCopyResponse() -> (status: OSStatus, data: Data?) {
        precondition(!copyResponses.isEmpty, "Missing synthetic copy response")
        if copyResponses.count == 1 {
            return copyResponses[0]
        }
        return copyResponses.removeFirst()
    }

    private func snapshot(_ dictionary: CFDictionary) -> KeychainQuerySnapshot {
        let values = dictionary as NSDictionary
        var snapshotValues: [String: KeychainSnapshotValue] = [:]
        for (key, value) in values {
            guard let key = key as? String else {
                preconditionFailure("Unexpected synthetic Keychain key type")
            }
            switch value {
            case let value as String:
                snapshotValues[key] = .string(value)
            case let value as Data:
                snapshotValues[key] = .dataLength(value.count)
            case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID():
                snapshotValues[key] = .bool(value.boolValue)
            case let value as NSNumber:
                snapshotValues[key] = .integer(value.intValue)
            default:
                preconditionFailure("Unexpected synthetic Keychain value type")
            }
        }
        return KeychainQuerySnapshot(values: snapshotValues)
    }
}
