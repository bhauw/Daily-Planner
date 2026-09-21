import Foundation

public struct EncryptedEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let algorithm: String
    public let keyVersion: Int
    public let sealedBox: Data

    public init(schemaVersion: Int, algorithm: String, keyVersion: Int, sealedBox: Data) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.keyVersion = keyVersion
        self.sealedBox = sealedBox
    }
}
