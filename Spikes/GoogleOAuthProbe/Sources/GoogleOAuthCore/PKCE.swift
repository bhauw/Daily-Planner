import CryptoKit
import Foundation
import Security

public enum PKCEError: Error, Equatable, Sendable {
    case randomGenerationFailed
    case invalidVerifier
}

public struct PKCEPair: Equatable, Sendable {
    public let verifier: String
    public let challenge: String
    public let method = "S256"

    public init(verifier: String) throws {
        guard (43...128).contains(verifier.utf8.count),
              verifier.allSatisfy({
                  $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" || $0 == "~"
              }) else {
            throw PKCEError.invalidVerifier
        }

        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Self.base64URL(Data(digest))
    }

    public static func generate() throws -> PKCEPair {
        try PKCEPair(verifier: base64URL(try SecureRandom.bytes(count: 64)))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum OAuthState {
    public static func generate() throws -> String {
        PKCEPair.base64URL(try SecureRandom.bytes(count: 32))
    }
}

public enum ConstantTime {
    public static func equals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var difference = UInt(left.count ^ right.count)

        for index in 0..<count {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= UInt(leftByte ^ rightByte)
        }

        return difference == 0
    }
}

private enum SecureRandom {
    static func bytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PKCEError.randomGenerationFailed
        }
        return Data(bytes)
    }
}
