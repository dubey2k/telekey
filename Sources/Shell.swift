import AppKit

nonisolated(unsafe) var serial = ""  // adb serial of the connected TV, e.g. 192.168.0.149:5555

let validPackage = try! Regex(#"^[A-Za-z0-9._]+$"#), validHost = try! Regex(#"^[A-Za-z0-9.-]+$"#)
let validAddress = try! Regex(#"^[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]{1,5})?$"#)

// MARK: - Shell helpers

/// Runs a command found via PATH, off the main thread; returns stdout + stderr.
/// Killed after `timeout` seconds: a TV that's half asleep can leave adb waiting forever.
func run(_ args: [String], timeout: Double = 20) async -> Data {
    await withCheckedContinuation { done in
        DispatchQueue.global().async {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = args
            p.standardOutput = pipe
            p.standardError = pipe
            guard (try? p.run()) != nil else { return done.resume(returning: Data()) }
            let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            stop.cancel()
            done.resume(returning: out)
        }
    }
}
func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
func adb(_ args: String...) async -> String { text(await run(["adb", "-s", serial] + args)) }
func sh(_ cmd: String) async -> String { await adb("shell", cmd) }  // runs in the TV's shell: only pass validated/quoted input

func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
func confirm(_ message: String, _ detail: String, _ ok: String) -> Bool {
    let a = NSAlert()
    a.messageText = message
    a.informativeText = detail
    a.addButton(withTitle: ok)
    a.addButton(withTitle: "Cancel")
    return a.runModal() == .alertFirstButtonReturn
}
