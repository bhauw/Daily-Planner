import AppKit
import Foundation
import WebKit

/// Configuration for the web host window: where to load the UI from, and the credentials the
/// page needs to reach the loopback API.
public struct WebHostConfiguration: Sendable {
    /// The URL the web view loads. Production: the loopback server root. Dev: the Vite server.
    public let pageURL: URL
    /// The loopback API origin the injected client calls (e.g. `http://127.0.0.1:<port>`).
    public let apiBaseURL: URL
    /// The per-launch bearer token, injected into the page — never a query parameter.
    public let token: String
    /// Whether this is a dev session (enables the web inspector).
    public let devMode: Bool

    public init(pageURL: URL, apiBaseURL: URL, token: String, devMode: Bool) {
        self.pageURL = pageURL
        self.apiBaseURL = apiBaseURL
        self.token = token
        self.devMode = devMode
    }
}

/// Hosts the React UI in a `WKWebView` inside a native window. The bearer token and API base
/// are handed to the page through a document-start user script, so the token never appears in a
/// URL, the page HTML, or a log line.
@MainActor
public final class WebHostWindow: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let configuration: WebHostConfiguration
    private var window: NSWindow?
    private var webView: WKWebView?

    public init(configuration: WebHostConfiguration) {
        self.configuration = configuration
        super.init()
    }

    public func show() {
        let webView = makeWebView()
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Daily Planner"
        window.contentMinSize = NSSize(width: 1100, height: 680)
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("DailyPlannerMainWindow")
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window

        webView.load(URLRequest(url: configuration.pageURL))
    }

    /// Reloads the page. Used when the engine swaps from the synthetic source to the live one,
    /// so the user sees their real day without having to hit Refresh themselves.
    public func reload() {
        webView?.reload()
    }

    private func makeWebView() -> WKWebView {
        let controller = WKUserContentController()
        controller.addUserScript(injectionScript())

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        // No persistent website data: the token lives only in-memory for this launch.
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        // Without a UI delegate, WKWebView drops every `window.open` on the floor — no pop-up,
        // no error, no console message. That is what made "Open in Calendar", "Find in Gmail",
        // "Open in Tasks" and the post-schedule "Open in Google Calendar" link do nothing at all
        // in the signed app while working fine in a browser.
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        if configuration.devMode {
            webView.isInspectable = true
        }
        return webView
    }

    /// Injected at document start, into the main frame only: the client reads these globals to
    /// address and authenticate against the loopback API. JSON-encoded so the values cannot
    /// break out of the string literals.
    ///
    /// The token global MUST stay named `__DP_TOKEN__`: that is the name
    /// `web/src/api/client.ts` reads (and `web/src/dev/mock.ts` sets for `npm run dev`).
    /// These names were invented independently on each side once before — the host published
    /// `__DAILY_PLANNER_TOKEN__` while the client read `__DP_TOKEN__`, so `token()` was always
    /// undefined and the shipped UI showed "Not connected to the engine" with no error anywhere.
    /// Rename on one side only and the app silently loses its data.
    private func injectionScript() -> WKUserScript {
        let api = jsString(configuration.apiBaseURL.absoluteString)
        let token = jsString(configuration.token)
        let source = """
        Object.defineProperty(window, "__DAILY_PLANNER_API__", { value: \(api), writable: false, configurable: false });
        Object.defineProperty(window, "__DP_TOKEN__", { value: \(token), writable: false, configurable: false });
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    // MARK: - External links

    /// `window.open` and `target="_blank"`. Returning nil means "no new web view was created",
    /// which is correct here: the link is handed to the system browser instead, so another site
    /// never renders inside the window holding the user's day — and never inside a web view
    /// carrying the loopback bearer token.
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let url = navigationAction.request.url
        switch ExternalLinkPolicy.decide(url: url, appOrigin: self.configuration.pageURL) {
        case .openInSystemBrowser:
            if let url { NSWorkspace.shared.open(url) }
        case .keepInWebView:
            // A same-origin pop-up is one of our own routes; load it in place rather than
            // spawning a second window with no token in it.
            if let url { webView.load(URLRequest(url: url)) }
        case .refuse:
            break
        }
        return nil
    }

    /// Top-level navigation away from the app's own origin. Without this a plain link could
    /// replace the planner UI with a Google page inside the app window, and the only way back
    /// would be to quit — the window has no address bar and no Back button.
    /// The async form on purpose. The completion-handler variant differs from the protocol's
    /// declaration by an isolation attribute, so Swift treats it as a *near* match, compiles it
    /// with a warning, and never calls it — an optional delegate method that silently does
    /// nothing, which is the same failure this whole change exists to fix.
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .linkActivated else { return .allow }
        switch ExternalLinkPolicy.decide(url: navigationAction.request.url, appOrigin: configuration.pageURL) {
        case .keepInWebView:
            return .allow
        case .openInSystemBrowser:
            if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            return .cancel
        case .refuse:
            return .cancel
        }
    }

    private func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        // JSONSerialization emits a one-element array; strip the brackets to get the literal.
        return String(array.dropFirst().dropLast())
    }
}
