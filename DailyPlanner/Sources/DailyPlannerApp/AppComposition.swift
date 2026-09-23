import AppKit
import Foundation
import SwiftUI
import DailyPlannerAPI
import DailyPlannerApplication
import DailyPlannerDomain
import DailyPlannerGoogle
import DailyPlannerPersistence
import DailyPlannerPlatform
import DailyPlannerUI
import DailyPlannerWebHost

/// Boots the planner as a single process: it starts the loopback engine (the read-only local
/// API server) and then opens the WKWebView host that renders the React UI over it. The Swift
/// side is now a backend; the UI is web. No SwiftUI window remains.
@MainActor
public final class EngineHost: NSObject, NSApplicationDelegate {
    private var server: LocalAPIServer?
    private var host: WebHostWindow?

    private let devMode: Bool
    private let launchMode: LaunchMode
    private var settingsWindow: NSWindow?

    public init(launchMode: LaunchMode = .standard) {
        self.devMode = Self.detectDevMode()
        self.launchMode = launchMode
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        // In dev mode the page is served by the Vite dev server; the API server still owns the
        // data and must accept the Vite origin. In production everything is same-origin loopback.
        let devOrigins: Set<String> = devMode
            ? ["http://localhost:5173", "http://127.0.0.1:5173"]
            : []

        // Open on the synthetic source, which touches no Keychain and cannot block. Reading the
        // real encrypted settings and the Google credentials can raise a modal Keychain prompt,
        // and doing that here would hang launch with no window on screen — the user would face a
        // security dialog from an app that had not appeared yet.
        let server = LocalAPIServer(
            webRoot: Self.bundledWebRoot(),
            extraAllowedOrigins: devOrigins
        )
        self.server = server

        Task { @MainActor in
            do {
                let port = try await server.start()
                self.presentWindow(port: port, token: server.token)
                self.upgradeToLiveSourceIfConnected(server: server)
                // `--live-readonly-canary` used to be inert: `launchMode` was stored and never
                // read, so the flag opened nothing. It presents the settings surface again.
                if self.launchMode == .liveReadOnlyCanary { self.openSettingsWindow() }
            } catch {
                self.presentStartupFailure()
            }
        }
    }

    /// Resolves the real account off the main thread and swaps it in once ready, then reloads the
    /// page so the user sees their real day without pressing Refresh. If nothing is connected, or
    /// the user dismisses the Keychain prompt, the app simply stays on the synthetic source.
    private func upgradeToLiveSourceIfConnected(server: LocalAPIServer) {
        Task.detached(priority: .userInitiated) {
            guard let live = await Self.makeLiveService() else { return }
            server.replaceService(live)
            await MainActor.run { self.host?.reload() }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    private func presentWindow(port: UInt16, token: String) {
        guard let apiBaseURL = URL(string: "http://127.0.0.1:\(port)") else {
            presentStartupFailure()
            return
        }
        let pageURL: URL
        if devMode, let devURL = URL(string: "http://localhost:5173/?dev=1") {
            pageURL = devURL
        } else {
            pageURL = apiBaseURL.appendingPathComponent("/")
        }

        let host = WebHostWindow(
            configuration: WebHostConfiguration(
                pageURL: pageURL,
                apiBaseURL: apiBaseURL,
                token: token,
                devMode: devMode
            )
        )
        self.host = host
        host.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Settings window

    /// Opens the SwiftUI surface as a secondary window.
    ///
    /// This is the only place a calendar can be given the `planning` role: the web Settings
    /// workspace is still a stub ("configured in a later milestone"), and without at least one
    /// planning calendar the engine serves an empty day by design. `PlannerRootView` existed but
    /// nothing ever instantiated it outside the tests, so the assignment was unreachable in the
    /// shipped app and the calendar could never show anything.
    @objc public func openSettingsWindow() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Resolving the account reads the Keychain, so it happens off the main actor and the
        // window is built once it is ready — same rule as `makeLiveService`.
        Task.detached(priority: .userInitiated) {
            let live = AppComposition.makeLiveCalendarSource()
            await MainActor.run { self.presentSettingsWindow(liveSource: live) }
        }
    }

    private func presentSettingsWindow(liveSource: (any PlannerCalendarSource)?) {
        let model = AppComposition.makeRootModel(launchMode: launchMode, liveSource: liveSource)
        // The window IS the settings surface — not a sheet floating over the old three-column
        // preview root. Presenting it as a sheet left the legacy UI visible around and behind it,
        // which reads as two half-built screens stacked on each other, and the root underneath
        // serves no purpose here: this window is only ever reached through "Settings…".
        //
        // The connection state drives which controls are offered, and it is only read on demand,
        // so read it now rather than making the user press "Check connection status" first.
        Task { await model.loadGoogleConnectionState() }
        let window = NSWindow(
            contentViewController: NSHostingController(
                rootView: PlannerSettingsView(model: model) { [weak self] in
                    self?.settingsWindow?.performClose(nil)
                }
            )
        )
        window.title = "Daily Planner Settings"
        window.setContentSize(NSSize(width: 720, height: 620))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DailyPlannerSettingsWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Installs a real main menu. Without one the app got AppKit's bare default, which has no
    /// Settings item and no Edit menu — so the settings surface had no route and ⌘C/⌘V did not
    /// work in the web UI's text fields.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Daily Planner",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Daily Planner",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(
            withTitle: "Quit Daily Planner",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func presentStartupFailure() {
        let alert = NSAlert()
        alert.messageText = "Daily Planner could not start its engine."
        alert.informativeText = "The local engine failed to bind a loopback port. Quit and relaunch."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// Chooses the data source the engine serves.
    ///
    /// If a Google account is connected, the API serves the real account through
    /// `GoogleCalendarSource` and the real encrypted settings store — so calendar roles, the
    /// colour→category mapping and the vault flag are the user's actual saved values. If no
    /// account is connected (or the credentials are incomplete), it falls back to the synthetic
    /// source so the app still opens and explains itself rather than erroring.
    ///
    /// Read-only either way: only read clients are constructed, and the router serves GET/HEAD.
    /// `nonisolated` on purpose: this touches the Keychain, which can block on a modal prompt.
    /// It must never run on the main actor or it would freeze the UI it is trying to populate.
    private nonisolated static func makeLiveService() async -> PlannerAPIService? {
        let settingsStore = EncryptedPrivateSettingsStore.production()
        let credentials = GoogleOAuthKeychain()

        guard let presence = try? credentials.presence(), presence == .complete else {
            return nil
        }

        let transport = URLSessionGoogleHTTPTransport()
        let tokens = StoredGoogleAccessTokenProvider(
            credentials: credentials,
            tokenService: GoogleOAuthTokenService(transport: transport)
        )
        // An unmapped colour falls back to `.other` inside the source, so an empty mapping is
        // a usable (if uncategorised) day rather than a failure.
        let mapping = (try? settingsStore.load())?.colorCategoryMapping ?? [:]
        let source = GoogleCalendarSource(
            calendarClient: GoogleCalendarReadClient(transport: transport),
            colorsClient: GoogleColorsReadClient(transport: transport),
            tokens: tokens,
            colorMapping: mapping
        )
        let tasks = GoogleTasksSource(
            client: GoogleTasksReadClient(transport: transport),
            tokens: tokens
        )
        let mail = GoogleMailSource(
            client: GmailReadClient(transport: transport),
            tokens: tokens
        )

        // The write path exists only if the grant actually carries the scopes for it. An account
        // whose grant is read-only builds no sender and no scheduler at all — so `/api/mail/send`
        // has nothing to call and answers 403, rather than reaching Google to be refused there.
        //
        // ASKED OF GOOGLE, not read from the settings blob. The persisted value is written once,
        // when the account is confirmed, and it was found empty on an account whose token carried
        // gmail.send and calendar.events the whole time — so the app told the user it was
        // read-only, and the only remedy it offered was a re-consent that was not needed. Google
        // states the granted scopes on every refresh; that is the reading that cannot go stale.
        //
        // The stored value is the fallback for when the probe cannot run (offline at launch), and
        // is corrected below whenever the two disagree.
        let stored = (try? settingsStore.load())?.googleGrantedCapability
        let capability = await Self.resolveCapability(tokens: tokens, stored: stored, settingsStore: settingsStore)
        let mailSender: GoogleMailSender? = capability?.canSendMail == true
            ? GoogleMailSender(client: GmailSendClient(transport: transport), tokens: tokens)
            : nil
        // One client, two ports. The grant that lets this app put an event on a calendar is the
        // same one that lets it move an event already there, so they are built together or not
        // at all — but they stay separate values, because the service asks them separately and
        // a composition that wanted create-without-edit could say so here.
        let writeClient = capability?.canCreateEvents == true
            ? GoogleCalendarWriteClient(transport: transport)
            : nil
        let eventScheduler = writeClient.map { GoogleCalendarScheduler(client: $0, tokens: tokens) }
        let eventRescheduler = writeClient.map { GoogleCalendarRescheduler(client: $0, tokens: tokens) }

        // The assistant, if one is on this machine.
        //
        // Not gated on the Google grant: drafting a reply needs a model, not a permission from
        // Google. Nil when the CLI is not installed, which is what makes "this app cannot
        // generate" a structural fact rather than a setting — and the rail reads the provider
        // for whether content leaves, so a local-model adapter dropped in here would change
        // that line without touching anything else.
        let replyWriter = ClaudeCodeReplyWriter.locate().map { ClaudeCodeReplyWriter(executable: $0) }

        return PlannerAPIService(
            source: source,
            settingsStore: settingsStore,
            clock: SystemClock(),
            taskReader: tasks,
            mailReader: mail,
            mailSender: mailSender,
            eventScheduler: eventScheduler,
            eventRescheduler: eventRescheduler,
            replyWriter: replyWriter,
            // The same Gmail source reads a body on demand, on the read grant it already has.
            // The same CLI summarises one — but only when asked, on its own route.
            mailBodyReader: mail,
            summarizer: replyWriter,
            // Drafts are signed with the Mac account's first name: it is his, it is already on
            // this machine, and it means there is no setting to forget to fill in.
            signOffName: NSFullUserName().split(separator: " ").first.map(String.init),
            capability: capability
        )
    }

    /// The live capability, with the stored one as the fallback — and the store corrected when
    /// they disagree, so the Settings window stops offering a re-consent nobody needs.
    ///
    /// Failing back to `stored` rather than to `.readOnly` is deliberate: being offline at launch
    /// must not silently take away a capability the account has. Failing back to nil-as-read-only
    /// when there is no stored value either is the cautious end of the same rule.
    private nonisolated static func resolveCapability(
        tokens: StoredGoogleAccessTokenProvider,
        stored: GoogleGrantedCapability?,
        settingsStore: EncryptedPrivateSettingsStore
    ) async -> GoogleGrantedCapability? {
        guard let live = try? await tokens.grantedCapability() else { return stored }
        guard live != stored else { return live }
        if var settings = try? settingsStore.load() {
            settings.googleGrantedCapability = live
            try? settingsStore.replace(settings)
        }
        return live
    }

    /// Locates the built web bundle inside the app bundle, if present. Returns nil in a bare
    /// SwiftPM run or before task 03 bundles assets — the server then serves its placeholder.
    private static func bundledWebRoot() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true),
            Bundle.main.resourceURL?.appendingPathComponent("dist", isDirectory: true),
        ].compactMap { $0 }
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private static func detectDevMode() -> Bool {
        if CommandLine.arguments.contains("--dev") { return true }
        if ProcessInfo.processInfo.environment["DAILY_PLANNER_DEV"] == "1" { return true }
        return false
    }
}

/// Everything the planner workflows need from a calendar back end. Both
/// `M1SyntheticCalendarSource` and `GoogleCalendarSource` satisfy it, which is what lets the
/// settings surface run on real calendars.
public typealias PlannerCalendarSource = CalendarCatalogReading
    & PlanningCalendarReading
    & ExcludedReferenceViewing
    & ColorCatalogReading

@MainActor
public enum AppComposition {
    /// Builds a read-only source over the connected Google account, or nil when no account is
    /// connected.
    ///
    /// `nonisolated` for the same reason as `EngineHost.makeLiveService`: it reads the Keychain,
    /// which can block on a modal prompt. It must never run on the main actor.
    public nonisolated static func makeLiveCalendarSource() -> GoogleCalendarSource? {
        let settingsStore = EncryptedPrivateSettingsStore.production()
        let credentials = GoogleOAuthKeychain()
        guard let presence = try? credentials.presence(), presence == .complete else { return nil }

        let transport = URLSessionGoogleHTTPTransport()
        let tokens = StoredGoogleAccessTokenProvider(
            credentials: credentials,
            tokenService: GoogleOAuthTokenService(transport: transport)
        )
        let mapping = (try? settingsStore.load())?.colorCategoryMapping ?? [:]
        return GoogleCalendarSource(
            calendarClient: GoogleCalendarReadClient(transport: transport),
            colorsClient: GoogleColorsReadClient(transport: transport),
            tokens: tokens,
            colorMapping: mapping
        )
    }

    /// Builds the SwiftUI surface's model. Pass `liveSource` to run it on the connected account.
    public static func makeRootModel(
        launchMode: LaunchMode = .standard,
        liveSource: (any PlannerCalendarSource)? = nil
    ) -> PlannerAppModel {
        let settingsStore = EncryptedPrivateSettingsStore.production()
        let credentials = GoogleOAuthKeychain()
        let transport = URLSessionGoogleHTTPTransport()
        let authorization = GoogleAuthorizationSession(browser: MacSystemBrowser())
        let connectionController = GoogleReadOnlyConnectionController(
            authorization: authorization,
            credentials: credentials,
            transport: transport
        )
        let googleConnection = GoogleConnectionWorkflow(
            controller: connectionController,
            settingsStore: settingsStore
        )
        let clock = SystemClock()
        let now = clock.now
        // The connected account when there is one, so the role picker lists the user's REAL
        // calendars. This used to be hardwired to `M1SyntheticCalendarSource`, whose catalog is
        // two placeholders ("Synthetic School Calendar" / "Synthetic Reference Calendar") — so a
        // planning role could only ever be assigned to a synthetic id, which no real Google
        // calendar id can match. `CalendarRolePolicy` then defaulted every real calendar to
        // `.excludedReference`, `planningCalendarIDs` came back empty, and
        // `GoogleCalendarSource.planningEvents` returned `[]` without making a single API call.
        // That is why the calendar was blank on real data while Mail and Tasks were correct.
        let source: any PlannerCalendarSource = liveSource ?? M1SyntheticCalendarSource(referenceDate: now)
        let isCanary = launchMode == .liveReadOnlyCanary
        return PlannerAppModel(
            vaultOnboarding: VaultOnboardingWorkflow(
                picker: MacVaultFolderPicker(),
                settingsStore: settingsStore
            ),
            roles: CalendarRoleWorkflow(settingsStore: settingsStore, catalogReader: source),
            planning: PlanningPreviewWorkflow(
                catalogReader: source,
                planningReader: source,
                settingsReader: settingsStore,
                clock: clock
            ),
            referenceView: ReferenceCalendarWorkflow(
                referenceReader: source,
                settingsReader: settingsStore
            ),
            googleConnection: googleConnection,
            previewInterval: LocalSchedulePolicy.v1.localDayInterval(containing: now),
            colorMapping: ColorCategoryWorkflow(settingsStore: settingsStore, catalogReader: source),
            startsWithSettingsPresented: isCanary,
            googleConnectionGuidance: isCanary
                ? "Canary mode is ready. Click Connect to begin; nothing starts automatically."
                : nil
        )
    }
}
