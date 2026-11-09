// Checks for the code everything else relies on: running commands, quoting, validation, protocol encoding.
// build.sh runs these before building the app:
//   swiftc -parse-as-library Sources/Shell.swift Tests/checks.swift -o build/checks && build/checks
import Foundation

@main enum Checks {
    @MainActor static var failed = 0

    @MainActor static func check(_ ok: Bool, _ what: String) {
        if !ok { failed += 1; print("FAIL: \(what)") }
    }

    @MainActor static func main() async {
        // stdout and stderr stay apart, and the exit status comes through
        let r = await run(["sh", "-c", "echo out; echo err >&2; exit 3"])
        check(r.stdout == "out", "stdout alone")
        check(r.text == "out\nerr", "stdout + stderr for messages")
        check(r.status == 3 && !r.ok, "exit status")

        // a command that fills stderr doesn't deadlock while stdout is read
        let big = await run(["sh", "-c", "head -c 300000 /dev/zero >&2; echo done"])
        check(big.stdout == "done" && big.err.count == 300_000, "large stderr")

        // a hung command is killed at its timeout
        var t = Date()
        let slow = await run(["sleep", "10"], timeout: .milliseconds(300))
        check(!slow.ok && Date().timeIntervalSince(t) < 3, "timeout kills the command")

        // cancelling the task kills the command
        t = Date()
        let task = Task { await run(["sleep", "10"]) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let cancelled = await task.value
        check(!cancelled.ok && Date().timeIntervalSince(t) < 3, "cancellation kills the command")

        // a missing command fails instead of hanging
        check(!(await run(["telekey-no-such-command"])).ok, "missing command")

        // quoting survives the TV's shell
        check(quoted("it's") == #"'it'\''s'"#, "quote escaping")
        check(await run(["sh", "-c", "printf %s " + quoted("a'b; rm -rf ~")]).stdout == "a'b; rm -rf ~", "quoted text stays literal")

        // validation
        check("192.168.0.149".wholeMatch(of: validAddress) != nil && "10.0.0.2:5555".wholeMatch(of: validAddress) != nil, "valid addresses")
        check("192.168.0.149; reboot".wholeMatch(of: validAddress) == nil, "address injection rejected")
        check("com.tcl.esticker".wholeMatch(of: validPackage) != nil && "a b".wholeMatch(of: validPackage) == nil, "package names")
        check("dns.adguard-dns.com".wholeMatch(of: validHost) != nil && "x;reboot".wholeMatch(of: validHost) == nil, "hostnames")

        print(failed == 0 ? "checks: all passed" : "checks: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
