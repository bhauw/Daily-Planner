import Foundation

public protocol PrivateSettingsReading: Sendable {
    func load() throws -> PrivateSettings
}

public protocol PrivateSettingsWriting: Sendable {
    func replace(_ settings: PrivateSettings) throws
}

public protocol PrivateSettingsStore: PrivateSettingsReading, PrivateSettingsWriting {}

public enum PrivateSettingsStoreError: Equatable, Error, Sendable {
    case keyUnavailable
    case readFailed
    case authenticationFailed
    case unsupportedSchema
    case writeFailed
}

public protocol SettingsKeyMaterialProviding: Sendable {
    func existingKeyMaterial() throws -> Data?
    func keyMaterialForWrite() throws -> Data
}

public enum SettingsKeychainError: Equatable, Error, Sendable {
    case unavailable
    case invalidLength
    case randomGenerationFailed
}
