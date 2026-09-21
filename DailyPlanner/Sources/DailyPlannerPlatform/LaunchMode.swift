public enum LaunchMode: Equatable, Sendable {
    case standard
    case liveReadOnlyCanary

    public static func parse(arguments: [String]) -> LaunchMode {
        Array(arguments.dropFirst()) == ["--live-readonly-canary"]
            ? .liveReadOnlyCanary
            : .standard
    }
}
