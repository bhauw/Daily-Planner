import Foundation
import DailyPlannerDomain

public struct DeterministicGoogleContentPrivacyClassifier: GoogleContentClassifying, Sendable {
    public init() {}

    public func classify(_ input: GoogleContentClassificationInput) -> SourcePrivacyClass {
        let text: String
        switch input {
        case let .email(subject, sender, body, bodyKind):
            guard bodyKind != .unsupported else { return .private }
            text = [subject, sender, body ?? ""].joined(separator: "\n")
        case let .event(title, description, location):
            text = [title, description ?? "", location ?? ""].joined(separator: "\n")
        case let .task(title, notes):
            text = [title, notes ?? ""].joined(separator: "\n")
        case .unknown:
            return .private
        }

        guard let match = SensitiveIndicator.matches(text) else { return .private }
        return match ? .private : .ordinary
    }
}

private enum SensitiveIndicator {
    private static let phrases: [[String]] = [
        // Financial and government identity data.
        ["bank", "account"], ["routing", "number"], ["credit", "card"],
        ["debit", "card"], ["tax", "return"], ["social", "security"],
        ["wire", "transfer"], ["account", "number"], ["bank", "balance"],
        // Credentials and secrets.
        ["password", "reset"], ["reset", "code"], ["api", "key"],
        ["client", "secret"], ["private", "key"], ["access", "token"],
        ["recovery", "code"], ["one", "time", "code"], ["verification", "code"],
        // Health and legal data.
        ["medical", "record"], ["health", "insurance"], ["blood", "test"],
        ["medical", "appointment"], ["lawyer", "consultation"],
        ["legal", "privilege"], ["attorney", "client"], ["court", "order"],
    ]

    private static let words: Set<String> = [
        "ssn", "passcode", "password", "credential", "credentials", "secret",
        "diagnosis", "diagnosed", "prescription", "patient", "therapy",
        "attorney", "lawsuit", "subpoena",
    ]

    static func matches(_ text: String) -> Bool? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= GoogleSyncLimits.decodedBodyBytes + 16_384,
              !text.unicodeScalars.contains(where: { scalar in
            scalar.value == 0xFFFD
                || scalar.properties.isDefaultIgnorableCodePoint
                || scalar.properties.isNoncharacterCodePoint
                || (CharacterSet.controlCharacters.contains(scalar)
                    && scalar.value != 0x09 && scalar.value != 0x0A && scalar.value != 0x0D)
        }) else { return nil }

        let normalized = text
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .precomposedStringWithCanonicalMapping
        guard let visibleText = VisibleTextExtractor.extract(from: normalized) else { return nil }
        let visibleTokens = tokens(in: visibleText)
        guard !visibleTokens.isEmpty else { return nil }

        return containsIndicator(in: tokens(in: normalized))
            || containsIndicator(in: visibleTokens)
    }

    private static func tokens(in text: String) -> [String] {
        text.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }.map(String.init)
    }

    private static func containsIndicator(in tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        if tokens.contains(where: words.contains) { return true }

        return phrases.contains { phrase in
            guard phrase.count <= tokens.count else { return false }
            for start in 0...(tokens.count - phrase.count) {
                if Array(tokens[start..<(start + phrase.count)]) == phrase { return true }
            }
            return false
        }
    }

    private enum VisibleTextExtractor {
        static func extract(from input: String) -> String? {
            let bytes = Array(input.utf8)
            var output = ""
            output.reserveCapacity(bytes.count)
            var index = 0

            while index < bytes.count {
                if bytes[index] == ascii("<") {
                    if hasPrefix("<!--", in: bytes, at: index) {
                        guard let end = findSequence("-->", in: bytes, after: index + 4) else {
                            return nil
                        }
                        index = end + 3
                        continue
                    }
                    if beginsMarkup(in: bytes, at: index) {
                        guard let end = findTagEnd(in: bytes, after: index + 1) else { return nil }
                        index = end + 1
                        continue
                    }
                }

                if bytes[index] == ascii("&"), beginsEntity(in: bytes, at: index) {
                    guard let decoded = decodeEntity(in: bytes, at: index) else { return nil }
                    guard !decoded.scalar.properties.isDefaultIgnorableCodePoint,
                          !decoded.scalar.properties.isNoncharacterCodePoint,
                          decoded.scalar.value != 0,
                          decoded.scalar.value != 0xFFFD else { return nil }
                    output.unicodeScalars.append(decoded.scalar)
                    index = decoded.endIndex
                    continue
                }

                let start = index
                index += 1
                while index < bytes.count,
                      bytes[index] != ascii("<"), bytes[index] != ascii("&") {
                    index += 1
                }
                output.append(String(decoding: bytes[start..<index], as: UTF8.self))
            }
            return output
        }

        private struct DecodedEntity {
            let scalar: Unicode.Scalar
            let endIndex: Int
        }

        private static func decodeEntity(in bytes: [UInt8], at start: Int) -> DecodedEntity? {
            var end = start + 1
            let maximumEnd = min(bytes.count, start + 34)
            while end < maximumEnd, bytes[end] != ascii(";") { end += 1 }
            guard end < bytes.count, bytes[end] == ascii(";") else { return nil }
            let body = String(decoding: bytes[(start + 1)..<end], as: UTF8.self)

            let scalar: Unicode.Scalar?
            switch body {
            case "amp": scalar = "&".unicodeScalars.first
            case "lt": scalar = "<".unicodeScalars.first
            case "gt": scalar = ">".unicodeScalars.first
            case "quot": scalar = "\"".unicodeScalars.first
            case "apos": scalar = "'".unicodeScalars.first
            case "nbsp": scalar = " ".unicodeScalars.first
            default:
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    scalar = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
                } else if body.hasPrefix("#") {
                    scalar = UInt32(body.dropFirst(), radix: 10).flatMap(Unicode.Scalar.init)
                } else {
                    scalar = nil
                }
            }
            guard let scalar else { return nil }
            return DecodedEntity(scalar: scalar, endIndex: end + 1)
        }

        private static func beginsEntity(in bytes: [UInt8], at index: Int) -> Bool {
            guard index + 1 < bytes.count else { return false }
            let next = bytes[index + 1]
            return next == ascii("#")
                || (ascii("A")...ascii("Z")).contains(next)
                || (ascii("a")...ascii("z")).contains(next)
        }

        private static func beginsMarkup(in bytes: [UInt8], at index: Int) -> Bool {
            guard index + 1 < bytes.count else { return false }
            let next = bytes[index + 1]
            return next == ascii("!") || next == ascii("?") || next == ascii("/")
                || (ascii("A")...ascii("Z")).contains(next)
                || (ascii("a")...ascii("z")).contains(next)
        }

        private static func findTagEnd(in bytes: [UInt8], after start: Int) -> Int? {
            var quote: UInt8?
            var cursor = start
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if let activeQuote = quote {
                    if byte == activeQuote { quote = nil }
                } else if byte == ascii("\"") || byte == ascii("'") {
                    quote = byte
                } else if byte == ascii(">") {
                    return cursor
                }
                cursor += 1
            }
            return nil
        }

        private static func hasPrefix(_ prefix: String, in bytes: [UInt8], at index: Int) -> Bool {
            let prefixBytes = Array(prefix.utf8)
            guard index + prefixBytes.count <= bytes.count else { return false }
            return bytes[index..<(index + prefixBytes.count)].elementsEqual(prefixBytes)
        }

        private static func findSequence(
            _ sequence: String, in bytes: [UInt8], after start: Int
        ) -> Int? {
            let sequenceBytes = Array(sequence.utf8)
            var cursor = start
            while cursor + sequenceBytes.count <= bytes.count {
                if bytes[cursor..<(cursor + sequenceBytes.count)].elementsEqual(sequenceBytes) {
                    return cursor
                }
                cursor += 1
            }
            return nil
        }

        private static func ascii(_ character: Character) -> UInt8 {
            character.asciiValue!
        }
    }
}
