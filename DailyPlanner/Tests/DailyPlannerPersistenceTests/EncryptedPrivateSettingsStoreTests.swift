import CryptoKit
import Foundation
import XCTest
@testable import DailyPlannerDomain
@testable import DailyPlannerPersistence

final class EncryptedPrivateSettingsStoreTests: XCTestCase {
    private var temporaryRoot: URL!
    private var envelopeURL: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "daily-planner-persistence-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        envelopeURL = temporaryRoot.appending(path: "settings.envelope")
    }

    override func tearDownWithError() throws {
        guard temporaryRoot.path.hasPrefix(FileManager.default.temporaryDirectory.path),
              temporaryRoot.lastPathComponent.hasPrefix("daily-planner-persistence-tests-") else {
            XCTFail("Refusing to remove an unexpected test directory")
            return
        }
        try? FileManager.default.removeItem(at: temporaryRoot)
        temporaryRoot = nil
        envelopeURL = nil
    }

    func testEncryptedStoreRoundTripsWithoutPlaintextIdentifiersOrBookmark() throws {
        let key = Data(repeating: 0x2A, count: 32)
        let store = makeStore(key: key)
        let calendarID = CalendarID(rawValue: "synthetic-private-calendar")
        let settings = PrivateSettings(
            vaultBookmark: Data("synthetic-bookmark-canary".utf8),
            calendarRoles: [calendarID: .planning],
            calendarRoleAudit: [CalendarRoleAuditEntry(
                calendarID: calendarID,
                oldRole: .excludedReference,
                newRole: .planning,
                actor: .localUser,
                changedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )]
        )

        try store.replace(settings)

        XCTAssertEqual(try store.load(), settings)
        let bytes = try Data(contentsOf: envelopeURL)
        XCTAssertNil(bytes.range(of: Data("synthetic-bookmark-canary".utf8)))
        XCTAssertNil(bytes.range(of: Data("synthetic-private-calendar".utf8)))
        XCTAssertNil(bytes.range(of: Data("localUser".utf8)))
    }

    func testTamperedEnvelopeFailsClosedWithoutReturningPartialSettings() throws {
        let store = makeStore(key: Data(repeating: 0x2A, count: 32))
        let settings = PrivateSettings(
            vaultBookmark: nil,
            calendarRoles: [.init(rawValue: "synthetic-private-calendar"): .planning],
            calendarRoleAudit: []
        )
        try store.replace(settings)

        try flipOneCiphertextByte(at: envelopeURL)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? PrivateSettingsStoreError, .authenticationFailed)
        }
    }

    func testMissingFileReturnsEmptyExcludedByDefaultSettingsWithoutCreatingAKey() throws {
        let keyProvider = RecordingKeyProvider(existing: nil)
        let store = EncryptedPrivateSettingsStore(storageURL: envelopeURL, keyProvider: keyProvider)

        XCTAssertEqual(try store.load(), .empty)
        XCTAssertEqual(keyProvider.readCount, 0)
        XCTAssertEqual(keyProvider.writeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))
    }

    func testInaccessibleExistingEnvelopeFailsClosedWithoutKeychainAccess() throws {
        let restrictedRoot = temporaryRoot.appending(path: "synthetic-restricted", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: restrictedRoot, withIntermediateDirectories: true)
        let inaccessibleURL = restrictedRoot.appending(path: "settings.envelope")
        try Data("synthetic-existing-envelope".utf8).write(to: inaccessibleURL)
        let keyProvider = RecordingKeyProvider(existing: nil)
        let store = EncryptedPrivateSettingsStore(storageURL: inaccessibleURL, keyProvider: keyProvider)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restrictedRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restrictedRoot.path)
        }

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? PrivateSettingsStoreError, .readFailed)
        }
        XCTAssertEqual(keyProvider.readCount, 0)
        XCTAssertEqual(keyProvider.writeCount, 0)
    }

    func testWrongKeyFailsAuthentication() throws {
        try makeStore(key: Data(repeating: 0x2A, count: 32)).replace(.empty)
        let wrongKeyStore = makeStore(key: Data(repeating: 0x2B, count: 32))

        XCTAssertThrowsError(try wrongKeyStore.load()) { error in
            XCTAssertEqual(error as? PrivateSettingsStoreError, .authenticationFailed)
        }
    }

    func testUnsupportedEnvelopeMetadataFailsBeforeDecryption() throws {
        let store = makeStore(key: Data(repeating: 0x2A, count: 32))
        try store.replace(.empty)
        let original = try JSONDecoder().decode(EncryptedEnvelope.self, from: Data(contentsOf: envelopeURL))
        let unsupportedEnvelopes = [
            EncryptedEnvelope(schemaVersion: 2, algorithm: "AES.GCM.256", keyVersion: 1, sealedBox: original.sealedBox),
            EncryptedEnvelope(schemaVersion: 1, algorithm: "synthetic-unsupported", keyVersion: 1, sealedBox: original.sealedBox),
            EncryptedEnvelope(schemaVersion: 1, algorithm: "AES.GCM.256", keyVersion: 2, sealedBox: original.sealedBox),
        ]

        for envelope in unsupportedEnvelopes {
            try JSONEncoder().encode(envelope).write(to: envelopeURL, options: .atomic)
            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertEqual(error as? PrivateSettingsStoreError, .unsupportedSchema)
            }
        }
    }

    func testMalformedEnvelopeMapsToFiniteReadFailure() throws {
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try Data("synthetic-malformed-envelope".utf8).write(to: envelopeURL)
        let store = makeStore(key: Data(repeating: 0x2A, count: 32))

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? PrivateSettingsStoreError, .readFailed)
        }
    }

    func testUnsupportedPrivateSettingsSchemaFailsClosed() throws {
        let store = makeStore(key: Data(repeating: 0x2A, count: 32))
        let unsupported = PrivateSettings(
            schemaVersion: 3,
            vaultBookmark: nil,
            calendarRoles: [:],
            calendarRoleAudit: []
        )

        XCTAssertThrowsError(try store.replace(unsupported)) { error in
            XCTAssertEqual(error as? PrivateSettingsStoreError, .unsupportedSchema)
        }
    }

    func testVersionOnePlaintextMigratesToVersionTwoWithoutGoogleBinding() throws {
        try writeLegacyV1Settings(calendarID: "synthetic-legacy-calendar")

        let loaded = try makeStore(key: Data(repeating: 0x2A, count: 32)).load()

        XCTAssertEqual(loaded.schemaVersion, 2)
        XCTAssertNil(loaded.googleAccountBinding)
        XCTAssertEqual(loaded.vaultBookmark, Data("synthetic-legacy-bookmark".utf8))
        XCTAssertEqual(loaded.calendarRoles[CalendarID(rawValue: "synthetic-legacy-calendar")], .planning)
        XCTAssertEqual(loaded.calendarRoleAudit, [CalendarRoleAuditEntry(
            calendarID: CalendarID(rawValue: "synthetic-legacy-calendar"),
            oldRole: .excludedReference,
            newRole: .planning,
            actor: .localUser,
            changedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )])
    }

    func testVersionTwoRoundTripEncryptsGoogleIdentity() throws {
        let store = makeStore(key: Data(repeating: 0x2A, count: 32))
        var settings = PrivateSettings.empty
        settings.googleAccountBinding = try GoogleIdentityBinding(normalizing: "owner@example.test")

        try store.replace(settings)

        XCTAssertEqual(try store.load(), settings)
        XCTAssertNil(try Data(contentsOf: envelopeURL).range(of: Data("owner@example.test".utf8)))
    }

    /// The granted capability must survive a write.
    ///
    /// It did not: `encode(to:)` simply left the field out, so `replace` appeared to succeed
    /// while discarding it and `load` always returned nil. Because nil reads as read-only, the
    /// app built no mail sender and no event scheduler on any launch that could not reach
    /// Google to ask — and then offered a re-consent the account did not need.
    ///
    /// `testVersionTwoRoundTripEncryptsGoogleIdentity` above already asserts whole-value
    /// equality and would have caught this, except that its fixture leaves the capability nil.
    /// This one sets it.
    func testVersionTwoRoundTripPreservesGrantedCapability() throws {
        let store = makeStore(key: Data(repeating: 0x3B, count: 32))
        var settings = PrivateSettings.empty
        settings.googleGrantedCapability = .readWrite

        try store.replace(settings)

        XCTAssertEqual(try store.load().googleGrantedCapability, .readWrite)
        XCTAssertEqual(try store.load(), settings)
    }

    /// The offline fallback this protects: a stored `.readWrite` must still be readable when
    /// the live probe cannot run, because falling back to nil silently removes a capability the
    /// account really has.
    func testStoredCapabilitySurvivesAReplaceThatChangesAnotherField() throws {
        let store = makeStore(key: Data(repeating: 0x4C, count: 32))
        var settings = PrivateSettings.empty
        settings.googleGrantedCapability = .readWrite
        try store.replace(settings)

        var reloaded = try store.load()
        reloaded.colorCategoryMapping = ["14": .school]
        try store.replace(reloaded)

        XCTAssertEqual(try store.load().googleGrantedCapability, .readWrite)
        XCTAssertEqual(try store.load().colorCategoryMapping, ["14": .school])
    }

    func testUnsupportedFuturePlaintextSchemaFailsAsUnsupportedSchema() throws {
        try writeAuthenticatedPlaintext(Data(#"{"schemaVersion":3}"#.utf8))

        XCTAssertThrowsError(try makeStore(key: Data(repeating: 0x2A, count: 32)).load()) { error in
            XCTAssertEqual(error as? PrivateSettingsStoreError, .unsupportedSchema)
        }
    }

    func testMalformedSupportedPlaintextSchemasMapToReadFailure() throws {
        for schemaVersion in [1, 2] {
            try writeAuthenticatedPlaintext(Data("{\"schemaVersion\":\(schemaVersion)}".utf8))

            XCTAssertThrowsError(try makeStore(key: Data(repeating: 0x2A, count: 32)).load()) { error in
                XCTAssertEqual(error as? PrivateSettingsStoreError, .readFailed)
            }
        }
    }

    func testReplaceCreatesOnlyTheImmediateStorageDirectory() throws {
        let store = makeStore(key: Data(repeating: 0x2A, count: 32))

        try store.replace(.empty)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryRoot.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path))
    }

    private func makeStore(key: Data) -> EncryptedPrivateSettingsStore {
        EncryptedPrivateSettingsStore(
            storageURL: envelopeURL,
            keyProvider: RecordingKeyProvider(existing: key)
        )
    }

    private func writeLegacyV1Settings(calendarID: String) throws {
        let payload = LegacySettingsV1Fixture(
            vaultBookmark: Data("synthetic-legacy-bookmark".utf8),
            calendarRoles: [CalendarID(rawValue: calendarID): .planning],
            calendarRoleAudit: [CalendarRoleAuditEntry(
                calendarID: CalendarID(rawValue: calendarID),
                oldRole: .excludedReference,
                newRole: .planning,
                actor: .localUser,
                changedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )]
        )
        try writeAuthenticatedPlaintext(JSONEncoder().encode(payload))
    }

    private func writeAuthenticatedPlaintext(_ plaintext: Data) throws {
        let key = SymmetricKey(data: Data(repeating: 0x2A, count: 32))
        let sealed = try AES.GCM.seal(plaintext, using: key)
        let envelope = EncryptedEnvelope(
            schemaVersion: 1,
            algorithm: "AES.GCM.256",
            keyVersion: 1,
            sealedBox: try XCTUnwrap(sealed.combined)
        )
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(envelope).write(to: envelopeURL, options: .atomic)
    }

    private func flipOneCiphertextByte(at url: URL) throws {
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(EncryptedEnvelope.self, from: data)
        var sealedBox = envelope.sealedBox
        let index = sealedBox.index(sealedBox.startIndex, offsetBy: sealedBox.count / 2)
        sealedBox[index] ^= 0x01
        let tampered = EncryptedEnvelope(
            schemaVersion: envelope.schemaVersion,
            algorithm: envelope.algorithm,
            keyVersion: envelope.keyVersion,
            sealedBox: sealedBox
        )
        try JSONEncoder().encode(tampered).write(to: url, options: .atomic)
    }
}

private struct LegacySettingsV1Fixture: Encodable {
    let schemaVersion = 1
    let vaultBookmark: Data?
    let calendarRoles: [CalendarID: CalendarRole]
    let calendarRoleAudit: [CalendarRoleAuditEntry]
}

private final class RecordingKeyProvider: SettingsKeyMaterialProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let existing: Data?
    private var reads = 0
    private var writes = 0

    init(existing: Data?) {
        self.existing = existing
    }

    func existingKeyMaterial() throws -> Data? {
        lock.withLock {
            reads += 1
            return existing
        }
    }

    func keyMaterialForWrite() throws -> Data {
        try lock.withLock {
            writes += 1
            guard let existing else {
                throw PrivateSettingsStoreError.keyUnavailable
            }
            return existing
        }
    }

    var readCount: Int {
        lock.withLock { reads }
    }

    var writeCount: Int {
        lock.withLock { writes }
    }
}
