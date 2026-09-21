import SwiftUI

@main
struct ToolchainProbeApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("Daily Planner")
                    .font(.title2)
                Text("Toolchain ready")
                    .accessibilityIdentifier("toolchain-ready")
            }
            .frame(width: 320, height: 180)
        }
    }
}
