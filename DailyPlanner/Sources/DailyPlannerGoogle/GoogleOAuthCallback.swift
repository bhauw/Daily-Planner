import Foundation

public struct GoogleOAuthCallback: Equatable, Sendable {
    public let authorizationCode: String

    public static func parse(target: String, expectedState: String) throws -> GoogleOAuthCallback {
        guard isVisibleASCII(target), !target.contains("#"), !target.hasPrefix("//") else {
            throw GoogleOAuthCallbackError.invalidRequest
        }

        let targetParts = target.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
        guard targetParts.count == 2,
              targetParts[0] == "/oauth/callback",
              !targetParts[1].isEmpty else {
            throw GoogleOAuthCallbackError.invalidRequest
        }

        let pairs = targetParts[1].split(separator: "&", omittingEmptySubsequences: false)

        var values: [String: String] = [:]
        var successMetadata: [String: Substring] = [:]
        for pair in pairs {
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else {
                throw GoogleOAuthCallbackError.invalidRequest
            }
            let name = String(components[0])
            guard values[name] == nil, successMetadata[name] == nil else {
                throw GoogleOAuthCallbackError.invalidRequest
            }

            if name == "code" || name == "error" || name == "state" {
                let value = try decodeOpaqueValue(components[1])
                guard !value.isEmpty else {
                    throw GoogleOAuthCallbackError.invalidRequest
                }
                values[name] = value
            } else if name == "iss" || name == "scope" || name == "authuser" || name == "prompt" {
                guard isValidIgnoredMetadataValue(components[1]) else {
                    throw GoogleOAuthCallbackError.invalidRequest
                }
                successMetadata[name] = components[1]
            } else {
                throw GoogleOAuthCallbackError.invalidRequest
            }
        }

        if let providerError = values["error"] {
            guard pairs.count == 2,
                  successMetadata.isEmpty,
                  providerError == "access_denied",
                  values["code"] == nil,
                  let receivedState = values["state"] else {
                throw GoogleOAuthCallbackError.invalidRequest
            }
            guard OAuthState.matches(expected: expectedState, received: receivedState) else {
                throw GoogleOAuthCallbackError.stateMismatch
            }
            throw GoogleOAuthCallbackError.authorizationDenied
        }

        guard let code = values["code"], let receivedState = values["state"] else {
            throw GoogleOAuthCallbackError.invalidRequest
        }
        if let issuer = successMetadata["iss"] {
            guard issuer == "https://accounts.google.com" else {
                throw GoogleOAuthCallbackError.invalidRequest
            }
        }
        guard OAuthState.matches(expected: expectedState, received: receivedState) else {
            throw GoogleOAuthCallbackError.stateMismatch
        }
        return GoogleOAuthCallback(authorizationCode: code)
    }
}

public enum GoogleOAuthCallbackError: Error, Equatable, Sendable {
    case invalidRequest
    case authorizationDenied
    case stateMismatch
}

private func isVisibleASCII(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
}

private func decodeOpaqueValue(_ rawValue: Substring) throws -> String {
    let bytes = Array(rawValue.utf8)
    var decoded: [UInt8] = []
    decoded.reserveCapacity(bytes.count)
    var index = 0

    while index < bytes.count {
        let byte = bytes[index]
        if byte == 43 {
            throw GoogleOAuthCallbackError.invalidRequest
        }
        if byte != 37 {
            guard (0x21...0x7E).contains(byte), !isAmbiguousDecodedByte(byte) else {
                throw GoogleOAuthCallbackError.invalidRequest
            }
            decoded.append(byte)
            index += 1
            continue
        }

        guard index + 2 < bytes.count,
              let high = hexadecimalValue(bytes[index + 1]),
              let low = hexadecimalValue(bytes[index + 2]) else {
            throw GoogleOAuthCallbackError.invalidRequest
        }
        let decodedByte = high << 4 | low
        guard (0x21...0x7E).contains(decodedByte), !isAmbiguousDecodedByte(decodedByte) else {
            throw GoogleOAuthCallbackError.invalidRequest
        }
        decoded.append(decodedByte)
        index += 3
    }

    guard let result = String(bytes: decoded, encoding: .utf8), isVisibleASCII(result) else {
        throw GoogleOAuthCallbackError.invalidRequest
    }
    return result
}

private func hexadecimalValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: byte - 48
    case 65...70: byte - 55
    case 97...102: byte - 87
    default: nil
    }
}

private func isAmbiguousDecodedByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 37, 38, 61, 35, 63, 43:
        true
    default:
        false
    }
}

private func isValidIgnoredMetadataValue(_ rawValue: Substring) -> Bool {
    guard !rawValue.isEmpty else { return false }
    let bytes = Array(rawValue.utf8)
    var index = 0
    while index < bytes.count {
        guard (0x21...0x7E).contains(bytes[index]) else { return false }
        if bytes[index] == 37 {
            guard index + 2 < bytes.count,
                  hexadecimalValue(bytes[index + 1]) != nil,
                  hexadecimalValue(bytes[index + 2]) != nil else { return false }
            index += 3
        } else {
            index += 1
        }
    }
    return true
}
