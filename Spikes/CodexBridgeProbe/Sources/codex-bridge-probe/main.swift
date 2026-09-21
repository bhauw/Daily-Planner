import CodexBridgeCore
import Darwin
import Foundation

@main
enum CodexBridgeProbeCommand {
    static func main() async {
        do {
            let executableURL = try AppServerProcess.resolveCodexExecutable()
            let result = try await AppServerProcess(executableURL: executableURL)
                .runProbe(timeout: .seconds(120))
            print(
                "source=daily-planner-probe "
                    + "status=\(result.structuredStatus) "
                    + "protocol=\(result.protocolVersion) "
                    + "threadStarted=\(result.threadStarted) "
                    + "turnCompleted=\(result.turnCompleted) "
                    + "cleanupSucceeded=\(result.cleanupSucceeded)"
            )
        } catch let error as ProbeError {
            FileHandle.standardError.write(
                Data("probe_failed=\(safeName(for: error))\n".utf8)
            )
            exit(EXIT_FAILURE)
        } catch {
            FileHandle.standardError.write(Data("probe_failed=unexpected\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func safeName(for error: ProbeError) -> String {
        switch error {
        case .missingExecutable: "missing_executable"
        case .launchFailed: "launch_failed"
        case .earlyChildExit: "early_child_exit"
        case .malformedJSON: "malformed_json"
        case .responseIDMismatch: "response_id_mismatch"
        case .timeout: "timeout"
        case .cancelled: "cancelled"
        case .protocolError: "protocol_error"
        case .protocolViolation: "protocol_violation"
        case .structuredOutputRejected: "structured_output_rejected"
        }
    }
}
