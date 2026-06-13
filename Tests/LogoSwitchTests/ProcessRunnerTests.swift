import Testing
import Foundation
@testable import LogoSwitch

/// `ProcessRunner` is internal (red-line defense), so these use `@testable`.
@Suite("ProcessRunner", .serialized)
struct ProcessRunnerTests {

    @Test("stub forwards args to the handler and returns its Result")
    func stubForwardsArgs() {
        // The handler is @Sendable, so it can't mutate a captured var; echo the
        // args back through stdout to assert they were forwarded.
        let runner = ProcessRunner.stub { args in
            .init(exitCode: 0, stdout: Data(args.joined(separator: " ").utf8), timedOut: false)
        }
        let r = runner.run("/bin/whatever", ["auth", "status"], nil, 1)
        #expect(r.exitCode == 0)
        #expect(String(data: r.stdout, encoding: .utf8) == "auth status")
        #expect(r.timedOut == false)
    }

    @Test("live captures stdout + exit 0 from a quick command")
    func liveCapturesStdout() {
        let r = ProcessRunner.live.run("/bin/echo", ["hello-logoswitch"], nil, 5)
        #expect(r.exitCode == 0)
        #expect(r.timedOut == false)
        let out = String(data: r.stdout, encoding: .utf8) ?? ""
        #expect(out.contains("hello-logoswitch"))
    }

    @Test("live terminates a child that overruns the timeout, flagging timedOut")
    func liveTimesOut() {
        let r = ProcessRunner.live.run("/bin/sleep", ["5"], nil, 0.4)
        #expect(r.timedOut == true)
        #expect(r.exitCode != 0)   // terminated, not a clean exit
    }

    // The deadlock regression: a child that floods stderr must NOT wedge the
    // stdout read (stderr is /dev/null, so there is no pipe buffer to fill). If
    // this ever hangs, the timeout would (wrongly) trip — assert it does not.
    @Test("live does not deadlock when the child floods stderr")
    func liveNoStderrDeadlock() {
        let r = ProcessRunner.live.run(
            "/bin/sh",
            ["-c", "seq 1 200000 1>&2; echo done"],
            nil,
            10
        )
        #expect(r.timedOut == false)
        #expect(r.exitCode == 0)
        #expect((String(data: r.stdout, encoding: .utf8) ?? "").contains("done"))
    }
}
