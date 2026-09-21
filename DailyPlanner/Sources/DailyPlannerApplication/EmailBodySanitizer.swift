import Foundation
import DailyPlannerDomain

public enum EmailBodySanitizerError: Error, Equatable, Sendable {
    case bodyTooLarge
    case unsupported
}

public struct StrictEmailBodySanitizer: EmailBodySanitizing, Sendable {
    public init() {}

    public func sanitize(kind: EmailBodyKind, decodedBody: String) throws -> SanitizedEmailBody {
        guard decodedBody.utf8.count <= GoogleSyncLimits.decodedBodyBytes else {
            throw EmailBodySanitizerError.bodyTooLarge
        }

        switch kind {
        case .plainText:
            return SanitizedEmailBody(kind: .plainText, value: decodedBody)
        case .html:
            return SanitizedEmailBody(
                kind: .html,
                value: try HTMLAllowlistSanitizer.sanitize(decodedBody)
            )
        case .unsupported:
            throw EmailBodySanitizerError.unsupported
        }
    }
}

/// A deliberately small HTML tokenizer. It never interprets entities or attributes, so input
/// cannot regain markup or URL semantics after sanitization. Dangerous container contents are
/// suppressed rather than exposed as text. This is deterministic and bounded independently of
/// the behavior of a web renderer's error-correcting HTML parser.
private enum HTMLAllowlistSanitizer {
    private static let maximumNestingDepth = 64
    private static let allowedTags: Set<String> = [
        "p", "br", "div", "span", "strong", "em", "ul", "ol", "li",
        "blockquote", "pre", "code",
    ]
    private static let voidTags: Set<String> = ["br"]
    private static let suppressedTags: Set<String> = [
        "script", "style", "template", "noscript", "iframe", "svg", "math",
        "object", "embed", "applet",
    ]

    static func sanitize(_ html: String) throws -> String {
        let bytes = Array(html.utf8)
        var output = BoundedOutput(maximumBytes: GoogleSyncLimits.decodedBodyBytes)
        var allowedStack: [String] = []
        var suppressedStack: [String] = []
        var index = 0

        while index < bytes.count {
            guard bytes[index] == ascii("<") else {
                let start = index
                while index < bytes.count, bytes[index] != ascii("<") { index += 1 }
                if suppressedStack.isEmpty {
                    try output.appendEscapedText(bytes[start..<index])
                }
                continue
            }

            if hasPrefix("<!--", in: bytes, at: index) {
                guard let end = findSequence("-->", in: bytes, after: index + 4) else { break }
                index = end + 3
                continue
            }

            guard let tag = parseTag(in: bytes, at: index) else {
                if beginsMarkup(in: bytes, at: index) {
                    break
                }
                if suppressedStack.isEmpty { try output.append("&lt;") }
                index += 1
                continue
            }
            index = tag.endIndex

            if !suppressedStack.isEmpty {
                if !tag.isClosing, suppressedTags.contains(tag.name), !tag.isSelfClosing {
                    suppressedStack.append(tag.name)
                } else if tag.isClosing, tag.name == suppressedStack.last {
                    suppressedStack.removeLast()
                }
                continue
            }

            if suppressedTags.contains(tag.name) {
                if !tag.isClosing, !tag.isSelfClosing { suppressedStack.append(tag.name) }
                continue
            }
            guard allowedTags.contains(tag.name) else { continue }

            if tag.isClosing {
                guard allowedStack.last == tag.name else { continue }
                try output.append("</\(allowedStack.removeLast())>")
            } else if voidTags.contains(tag.name) {
                try output.append("<\(tag.name)>")
            } else if tag.isSelfClosing {
                try output.append("<\(tag.name)></\(tag.name)>")
            } else if allowedStack.count < maximumNestingDepth {
                try output.append("<\(tag.name)>")
                allowedStack.append(tag.name)
            }
        }

        if suppressedStack.isEmpty {
            while let name = allowedStack.popLast() {
                try output.append("</\(name)>")
            }
        }
        return output.value
    }

    private struct Tag {
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
        let endIndex: Int
    }

    private static func parseTag(in bytes: [UInt8], at start: Int) -> Tag? {
        var cursor = start + 1
        guard cursor < bytes.count else { return nil }
        if bytes[cursor] == ascii("!") || bytes[cursor] == ascii("?") {
            guard let end = findTagEnd(in: bytes, after: cursor + 1) else { return nil }
            return Tag(name: "", isClosing: false, isSelfClosing: true, endIndex: end + 1)
        }

        let isClosing = bytes[cursor] == ascii("/")
        if isClosing { cursor += 1 }
        let nameStart = cursor
        while cursor < bytes.count, isASCIITagNameByte(bytes[cursor]) { cursor += 1 }
        guard cursor > nameStart else { return nil }
        let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self).lowercased()
        guard let end = findTagEnd(in: bytes, after: cursor) else { return nil }

        var beforeEnd = end
        while beforeEnd > cursor, isASCIIWhitespace(bytes[beforeEnd - 1]) { beforeEnd -= 1 }
        let isSelfClosing = beforeEnd > cursor && bytes[beforeEnd - 1] == ascii("/")
        return Tag(name: name, isClosing: isClosing, isSelfClosing: isSelfClosing, endIndex: end + 1)
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

    private static func beginsMarkup(in bytes: [UInt8], at index: Int) -> Bool {
        guard index + 1 < bytes.count else { return false }
        let next = bytes[index + 1]
        return next == ascii("!") || next == ascii("?") || next == ascii("/")
            || (ascii("A")...ascii("Z")).contains(next)
            || (ascii("a")...ascii("z")).contains(next)
    }

    private static func isASCIITagNameByte(_ byte: UInt8) -> Bool {
        (ascii("A")...ascii("Z")).contains(byte)
            || (ascii("a")...ascii("z")).contains(byte)
            || (ascii("0")...ascii("9")).contains(byte)
            || byte == ascii("-")
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
    }

    private static func hasPrefix(_ prefix: String, in bytes: [UInt8], at index: Int) -> Bool {
        let prefixBytes = Array(prefix.utf8)
        guard index + prefixBytes.count <= bytes.count else { return false }
        return bytes[index..<(index + prefixBytes.count)].elementsEqual(prefixBytes)
    }

    private static func findSequence(_ sequence: String, in bytes: [UInt8], after start: Int) -> Int? {
        let sequenceBytes = Array(sequence.utf8)
        guard sequenceBytes.count <= bytes.count else { return nil }
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

    private struct BoundedOutput {
        private(set) var value = ""
        private var byteCount = 0
        let maximumBytes: Int

        init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }

        mutating func append(_ string: String) throws {
            let addedBytes = string.utf8.count
            guard byteCount <= maximumBytes - addedBytes else {
                throw EmailBodySanitizerError.bodyTooLarge
            }
            value.append(string)
            byteCount += addedBytes
        }

        mutating func appendEscapedText(_ bytes: ArraySlice<UInt8>) throws {
            var runStart = bytes.startIndex
            var cursor = bytes.startIndex
            while cursor < bytes.endIndex {
                let replacement: String?
                switch bytes[cursor] {
                case ascii("&"): replacement = "&amp;"
                case ascii("<"): replacement = "&lt;"
                case ascii(">"): replacement = "&gt;"
                default: replacement = nil
                }
                if let replacement {
                    if runStart < cursor {
                        try append(String(decoding: bytes[runStart..<cursor], as: UTF8.self))
                    }
                    try append(replacement)
                    runStart = cursor + 1
                }
                cursor += 1
            }
            if runStart < bytes.endIndex {
                try append(String(decoding: bytes[runStart..<bytes.endIndex], as: UTF8.self))
            }
        }
    }
}
