import Foundation

/// Tells the user their OAuth client fields look wrong *before* they spend a consent round
/// finding out from Google.
///
/// Braxton pasted 68 characters into the client secret field. It was not a secret — a Google
/// secret is `GOCSPX-` plus 28 characters, letters, digits, `-` and `_` — it was a fragment of
/// the downloaded credentials JSON, label and quotes included. The field accepted it (the only
/// rules were non-empty, under 4KB, no control characters), the app stored it, and the failure
/// arrived much later as an HTTP 401 at the token exchange, mapped to "the provider is
/// temporarily unavailable". Two consent rounds and a trip to the Cloud Console went into
/// learning what the field could have said immediately.
///
/// Deliberately ADVICE, not validation. These shapes are Google's, not ours, and they can change
/// without warning; a hard reject on a heuristic would lock a user out of their own app the day
/// Google changes a prefix. So this never blocks a save — it just tells the truth about what the
/// value looks like.
public enum GoogleClientFieldAdvice {
    /// The value's shape is wrong in a way worth saying out loud, or nil when it looks fine.
    public static func clientIdentifierAdvice(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if looksLikeJSON(trimmed) {
            return "Paste only the value — this still has JSON punctuation in it."
        }
        guard trimmed.hasSuffix(".apps.googleusercontent.com") else {
            return "A client ID ends in .apps.googleusercontent.com."
        }
        return nil
    }

    public static func clientSecretAdvice(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if looksLikeJSON(trimmed) {
            return "Paste only the secret itself — this still has JSON punctuation in it."
        }
        if trimmed.hasSuffix(".apps.googleusercontent.com") {
            return "That is the client ID, not the secret."
        }
        guard trimmed.hasPrefix("GOCSPX-") else {
            return "A client secret starts with GOCSPX- and is about 35 characters."
        }
        guard trimmed.allSatisfy(isSecretCharacter) else {
            return "A client secret contains only letters, digits, - and _."
        }
        return nil
    }

    /// True when the value still carries the punctuation of the credentials file it came from.
    private static func looksLikeJSON(_ value: String) -> Bool {
        value.contains(where: { $0 == "\"" || $0 == "{" || $0 == "}" || $0 == ":" })
    }

    private static func isSecretCharacter(_ character: Character) -> Bool {
        character.isLetter && character.isASCII
            || character.isNumber && character.isASCII
            || character == "-"
            || character == "_"
    }
}
