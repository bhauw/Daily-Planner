import AppKit
import DailyPlannerPlatform

// Single-process entry point: an AppKit application whose one window hosts a WKWebView. The
// engine (loopback API server) and the web host are wired up by `EngineHost` once the app
// finishes launching.
//
// The retired SwiftUI surface (`PlannerRootView`) is still reachable as a secondary window,
// because it owns the Google read-only connection flow and the real encrypted settings until
// the web UI grows its own. `LaunchMode` is parsed here so `--live-readonly-canary` keeps
// working end to end.
let launchMode = LaunchMode.parse(arguments: CommandLine.arguments)
let application = NSApplication.shared
let engineHost = EngineHost(launchMode: launchMode)
application.delegate = engineHost
application.setActivationPolicy(.regular)
application.run()
