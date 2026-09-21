import CryptoKit
import DailyPlannerDomain
import Foundation

public struct EncryptedPrivateSettingsStore: PrivateSettingsStore, Sendable {
    private static let envelopeSchemaVersion = 1
    private static let algorithm = "AES.GCM.256"
    private static let keyVersion = 1

    private let storageURL: URL
    private let keyProvider: any SettingsKeyMaterialProviding

    public init(storageURL: URL, keyProvider: any SettingsKeyMaterialProviding) {
        self.storageURL = storageURL
        self.keyProvider = keyProvider
    }

    public static func production() -> EncryptedPrivateSettingsStore {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let storageURL = applicationSupport
            .appending(path: "DailyPlanner", directoryHint: .isDirectory)
            .appending(path: "private-settings-v1.envelope", directoryHint: .notDirectory)
        return EncryptedPrivateSettingsStore(storageURL: storageURL, keyProvider: SettingsKeychain())
    }

    public func load() throws -> PrivateSettings {
        let data: Data
        do {
            data = try Data(contentsOf: storageURL)
        } catch {
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain,
               cocoaError.code == CocoaError.fileReadNoSuchFile.rawValue {
                return .empty
            }
            throw PrivateSettingsStoreError.readFailed
        }

        let envelope: EncryptedEnvelope
        do {
            envelope = try JSONDecoder().decode(EncryptedEnvelope.self, from: data)
        } catch {
            throw PrivateSettingsStoreError.readFailed
        }

        guard envelope.schemaVersion == Self.envelopeSchemaVersion,
              envelope.algorithm == Self.algorithm,
              envelope.keyVersion == Self.keyVersion else {
            throw PrivateSettingsStoreError.unsupportedSchema
        }

        let keyMaterial = try existingKeyMaterial()
        guard keyMaterial.count == 32 else {
            throw PrivateSettingsStoreError.keyUnavailable
        }

        let plaintext: Data
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: envelope.sealedBox)
            plaintext = try AES.GCM.open(sealedBox, using: SymmetricKey(data: keyMaterial))
        } catch {
            throw PrivateSettingsStoreError.authenticationFailed
        }

        return try decodeSettings(plaintext)
    }

    public func replace(_ settings: PrivateSettings) throws {
        guard settings.schemaVersion == PrivateSettings.currentSchemaVersion else {
            throw PrivateSettingsStoreError.unsupportedSchema
        }

        let keyMaterial = try keyMaterialForWrite()
        guard keyMaterial.count == 32 else {
            throw PrivateSettingsStoreError.keyUnavailable
        }

        let encodedEnvelope: Data
        do {
            let plaintext = try JSONEncoder().encode(settings)
            let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyMaterial))
            guard let combined = sealed.combined else {
                throw PrivateSettingsStoreError.writeFailed
            }
            encodedEnvelope = try JSONEncoder().encode(EncryptedEnvelope(
                schemaVersion: Self.envelopeSchemaVersion,
                algorithm: Self.algorithm,
                keyVersion: Self.keyVersion,
                sealedBox: combined
            ))
        } catch let error as PrivateSettingsStoreError {
            throw error
        } catch {
            throw PrivateSettingsStoreError.writeFailed
        }

        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encodedEnvelope.write(to: storageURL, options: .atomic)
        } catch {
            throw PrivateSettingsStoreError.writeFailed
        }
    }

    private func existingKeyMaterial() throws -> Data {
        do {
            guard let keyMaterial = try keyProvider.existingKeyMaterial() else {
                throw PrivateSettingsStoreError.keyUnavailable
            }
            return keyMaterial
        } catch let error as PrivateSettingsStoreError {
            throw error
        } catch {
            throw PrivateSettingsStoreError.keyUnavailable
        }
    }

    private func keyMaterialForWrite() throws -> Data {
        do {
            return try keyProvider.keyMaterialForWrite()
        } catch let error as PrivateSettingsStoreError {
            throw error
        } catch {
            throw PrivateSettingsStoreError.keyUnavailable
        }
    }

    private func decodeSettings(_ plaintext: Data) throws -> PrivateSettings {
        let decoder = JSONDecoder()
        let schemaVersion: Int
        do {
            schemaVersion = try decoder.decode(SettingsSchemaHeader.self, from: plaintext).schemaVersion
        } catch {
            throw PrivateSettingsStoreError.readFailed
        }

        switch schemaVersion {
        case 1:
            do {
                let legacy = try decoder.decode(LegacyPrivateSettingsV1.self, from: plaintext)
                return PrivateSettings(
                    vaultBookmark: legacy.vaultBookmark,
                    googleAccountBinding: nil,
                    calendarRoles: legacy.calendarRoles,
                    calendarRoleAudit: legacy.calendarRoleAudit
                )
            } catch {
                throw PrivateSettingsStoreError.readFailed
            }
        case PrivateSettings.currentSchemaVersion:
            do {
                return try decoder.decode(PrivateSettings.self, from: plaintext)
            } catch {
                throw PrivateSettingsStoreError.readFailed
            }
        default:
            throw PrivateSettingsStoreError.unsupportedSchema
        }
    }
}

private struct SettingsSchemaHeader: Decodable {
    let schemaVersion: Int
}

private struct LegacyPrivateSettingsV1: Decodable {
    let vaultBookmark: Data?
    let calendarRoles: [CalendarID: CalendarRole]
    let calendarRoleAudit: [CalendarRoleAuditEntry]
}
