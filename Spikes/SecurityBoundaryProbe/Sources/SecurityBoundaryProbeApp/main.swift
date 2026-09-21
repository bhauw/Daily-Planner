import AppKit
import Foundation

let arguments = CommandLine.arguments
let viewModel = ProbeViewModel()

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

if arguments.contains("--lock-helper") {
    do {
        try viewModel.runLockHelper(arguments: arguments)
        exit(EXIT_SUCCESS)
    } catch {
        exit(EXIT_FAILURE)
    }
} else if arguments.contains("--interactive-select") {
    do {
        try printJSON(viewModel.selectAndSaveBookmark(arguments: arguments))
        exit(EXIT_SUCCESS)
    } catch {
        print("{\"probeStatus\":\"failed\"}")
        exit(EXIT_FAILURE)
    }
} else if arguments.contains("--interactive-resolve") {
    do {
        try printJSON(viewModel.resolvePersistedBookmark(arguments: arguments))
        exit(EXIT_SUCCESS)
    } catch {
        print("{\"probeStatus\":\"failed\"}")
        exit(EXIT_FAILURE)
    }
} else if arguments.contains("--interactive-cleanup") {
    do {
        try printJSON(viewModel.cleanupInteractiveArtifacts(arguments: arguments))
        exit(EXIT_SUCCESS)
    } catch {
        print("{\"probeStatus\":\"failed\"}")
        exit(EXIT_FAILURE)
    }
} else if arguments.contains("--automated") {
    do {
        let result = try viewModel.runAutomated(arguments: arguments)
        try printJSON(result)
        exit(EXIT_SUCCESS)
    } catch {
        print("{\"probeStatus\":\"failed\"}")
        exit(EXIT_FAILURE)
    }
} else {
    print("{\"probeStatus\":\"invalidMode\"}")
    exit(EXIT_FAILURE)
}
