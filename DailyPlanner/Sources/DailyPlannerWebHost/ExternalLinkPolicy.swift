import Foundation

/// What the host window should do with a URL the page wants to open.
///
/// A `WKWebView` with no `WKUIDelegate` does not open pop-ups — it silently drops them. The app
/// shipped without one, so every `window.open` in the UI did nothing at all: "Open in Calendar",
/// "Find in Gmail", "Open in Tasks", the "Open in Google Calendar" link offered after an event is
/// created, and — worst — the Gmail fallbacks that exist precisely for accounts whose grant
/// cannot write. The safety net was never connected to anything.
///
/// The decision is a pure function so it can be read and tested on its own. Which links leave the
/// app is exactly the kind of rule that should not live inside a delegate callback.
public enum ExternalLinkDecision: Equatable, Sendable {
    /// Hand to the system browser. The app is a planner, not a browser; another site does not
    /// belong inside the window that holds the user's day.
    case openInSystemBrowser
    /// Stay in the web view: this is the app's own UI.
    case keepInWebView
    /// Neither. Refused rather than guessed at.
    case refuse
}

public enum ExternalLinkPolicy {
    /// Only these ever reach the system browser. An allowlist rather than a denylist because the
    /// argument runs the wrong way otherwise: `file:`, `javascript:` and custom schemes each have
    /// their own reason to be refused, and a scheme nobody has thought about yet should be
    /// refused too, not opened because it was not on a list.
    static let openableSchemes: Set<String> = ["http", "https"]

    /// - Parameters:
    ///   - url: the URL the page asked to open, if it named one at all.
    ///   - appOrigin: the loopback origin serving the app's own UI.
    public static func decide(url: URL?, appOrigin: URL) -> ExternalLinkDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .refuse }
        guard openableSchemes.contains(scheme) else { return .refuse }

        // The app's own pages stay put. A route inside the UI opened with target="_blank" must
        // not be handed to Safari, where it would have no bearer token and render as a dead shell.
        if isSameOrigin(url, as: appOrigin) { return .keepInWebView }

        return .openInSystemBrowser
    }

    /// Scheme, host and port must all match. Compared in full rather than by a host suffix: a
    /// check like `hasSuffix("127.0.0.1")` is the shape that lets `evil-127.0.0.1` through.
    static func isSameOrigin(_ url: URL, as origin: URL) -> Bool {
        guard let lhs = url.scheme?.lowercased(), let rhs = origin.scheme?.lowercased(), lhs == rhs else {
            return false
        }
        guard let lhsHost = url.host?.lowercased(), let rhsHost = origin.host?.lowercased(), lhsHost == rhsHost else {
            return false
        }
        return normalizedPort(of: url) == normalizedPort(of: origin)
    }

    private static func normalizedPort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
