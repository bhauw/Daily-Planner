import CryptoKit
import Foundation
import Security

public struct PKCEPair: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public let method: String

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
        self.method = "S256"
    }

    public static func generate() throws -> PKCEPair {
        let verifier = try secureRandomBase64URL()
        return PKCEPair(verifier: verifier, challenge: challenge(for: verifier))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

public enum OAuthState {
    public static func generate() throws -> String {
        try secureRandomBase64URL()
    }

    public static func matches(expected: String, received: String) -> Bool {
        let expectedBytes = Array(expected.utf8)
        let receivedBytes = Array(received.utf8)
        let maximumLength = max(expectedBytes.count, receivedBytes.count)
        var difference = UInt(expectedBytes.count ^ receivedBytes.count)

        for index in 0..<maximumLength {
            let expectedByte = index < expectedBytes.count ? expectedBytes[index] : 0
            let receivedByte = index < receivedBytes.count ? receivedBytes[index] : 0
            difference |= UInt(expectedByte ^ receivedByte)
        }

        return difference == 0
    }
}

private func secureRandomBase64URL() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = bytes.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else {
        throw GoogleCryptographyError.randomnessUnavailable(status)
    }
    return base64URL(Data(bytes))
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private enum GoogleCryptographyError: Error {
    case randomnessUnavailable(OSStatus)
}
