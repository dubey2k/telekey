import Foundation

@MainActor let validPackage = try! Regex(#"^[A-Za-z0-9._]+$"#)
@MainActor let validHost = try! Regex(#"^[A-Za-z0-9.-]+$"#)
@MainActor let validAddress = try! Regex(#"^[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]{1,5})?$"#)

struct Output: Sendable {
    let out: Data, err: Data, status: Int32

    var ok: Bool { status == 0 }
    var stdout: String { Self.trim(out) }
    var text: String { [Self.trim(out), Self.trim(err)].filter { !$0.isEmpty }.joined(separator: "\n") }

    private static func trim(_ d: Data) -> String {
        String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs a command from PATH (adb is bundled in Resources). Killed on timeout or when the task is cancelled.
func run(_ args: [String], timeout: Duration = .seconds(20)) async -> Output {
    let p = Process(), out = Pipe(), err = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    p.standardOutput = out
    p.standardError = err
    guard (try? p.run()) != nil else { return Output(out: Data(), err: Data(), status: -1) }

    let watchdog = Task { try? await Task.sleep(for: timeout); if !Task.isCancelled { p.terminate() } }
    defer { watchdog.cancel() }

    return await withTaskCancellationHandler {
        // read both pipes together, or a full stderr stalls adb
        async let o = background { out.fileHandleForReading.readDataToEndOfFile() }
        async let e = background { err.fileHandleForReading.readDataToEndOfFile() }
        let (od, ed) = await (o, e)
        await background { p.waitUntilExit() }
        return Output(out: od, err: ed, status: p.terminationStatus)
    } onCancel: {
        p.terminate()
    }
}

func adb(_ serial: String, _ args: String..., timeout: Duration = .seconds(20)) async -> Output {
    await run(["adb", "-s", serial] + args, timeout: timeout)
}

/// Only pass validated input, or text wrapped in `quoted()`.
func shell(_ serial: String, _ command: String, timeout: Duration = .seconds(20)) async -> Output {
    await adb(serial, "shell", command, timeout: timeout)
}

func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

/// Blocking work goes to GCD, not Swift's small cooperative pool.
func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { done in DispatchQueue.global().async { done.resume(returning: work()) } }
}
