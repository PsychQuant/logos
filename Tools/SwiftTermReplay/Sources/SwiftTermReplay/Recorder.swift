import ArgumentParser
import Foundation
import Darwin

extension SwiftTermReplay {

    struct Record: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a command in a PTY and record stdout to a ttyrec file."
        )

        @Option(name: .shortAndLong, help: "Output ttyrec file path")
        var output: String = "capture.ttyrec"

        @Argument(parsing: .remaining, help: "Command + args (e.g. 'claude' or 'bash -c \"ls\"')")
        var command: [String]

        mutating func run() throws {
            guard !command.isEmpty else {
                throw ValidationError("Must provide a command to record.")
            }

            let outputURL = URL(fileURLWithPath: output)
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
                throw ValidationError("Cannot create \(output)")
            }
            let fileHandle = try FileHandle(forWritingTo: outputURL)
            defer { try? fileHandle.close() }

            // Open PTY
            var amaster: Int32 = -1
            var aslave: Int32 = -1
            guard openpty(&amaster, &aslave, nil, nil, nil) == 0 else {
                throw ValidationError("openpty failed: \(String(cString: strerror(errno)))")
            }

            // Use posix_spawn with file actions to set up PTY for child.
            // fork() is unavailable in modern Swift on Darwin.
            var fileActions: posix_spawn_file_actions_t? = nil
            posix_spawn_file_actions_init(&fileActions)
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            // Have child use slave PTY for stdin/stdout/stderr
            posix_spawn_file_actions_adddup2(&fileActions, aslave, 0)
            posix_spawn_file_actions_adddup2(&fileActions, aslave, 1)
            posix_spawn_file_actions_adddup2(&fileActions, aslave, 2)
            posix_spawn_file_actions_addclose(&fileActions, aslave)
            posix_spawn_file_actions_addclose(&fileActions, amaster)

            var attrs: posix_spawnattr_t? = nil
            posix_spawnattr_init(&attrs)
            defer { posix_spawnattr_destroy(&attrs) }
            // Make child a new session leader so it owns the controlling TTY
            var flags: Int16 = Int16(POSIX_SPAWN_SETSIGDEF)
            // POSIX_SPAWN_SETSID = 0x0400 on Darwin (sets session id; the new
            // session leader will acquire slave PTY as controlling terminal).
            flags |= 0x0400
            posix_spawnattr_setflags(&attrs, flags)

            // Build argv (C-style)
            let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
            defer { for ptr in argv where ptr != nil { free(ptr) } }

            // Inherit current environment
            var pid: pid_t = 0
            let spawnRC = posix_spawnp(&pid, command[0], &fileActions, &attrs, argv, environ)
            guard spawnRC == 0 else {
                throw ValidationError("posix_spawnp failed: \(String(cString: strerror(spawnRC)))")
            }

            // Parent: close slave (child has it), then read from master
            close(aslave)

            // SIGINT handler: flush + reap + exit cleanly. C function pointer can't
            // capture state, so we use a static handler that exits.
            signal(SIGINT) { _ in
                FileHandle.standardError.write(Data("\n[recorder] caught SIGINT — finalizing capture\n".utf8))
                Darwin.exit(0)
            }

            let startTime = Date()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            FileHandle.standardError.write(
                Data("Recording \(command.joined(separator: " ")) → \(output) (Ctrl-C to stop)\n".utf8)
            )

            // Forward stdin to PTY master so user/scripted input reaches the child.
            // Use a background thread that copies stdin → master.
            let masterCopy = amaster
            DispatchQueue.global().async {
                let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
                defer { inBuf.deallocate() }
                while true {
                    let n = read(0, inBuf, 1024)
                    if n <= 0 { break }
                    _ = write(masterCopy, inBuf, n)
                }
            }

            while true {
                let n = read(amaster, buffer, bufferSize)
                if n <= 0 { break }

                let elapsed = Date().timeIntervalSince(startTime)
                let sec = Int32(elapsed)
                let usec = Int32((elapsed - Double(sec)) * 1_000_000)
                let len = Int32(n)

                // Write ttyrec header (3 × little-endian Int32)
                let header: [Int32] = [sec.littleEndian, usec.littleEndian, len.littleEndian]
                let headerData = header.withUnsafeBytes { Data($0) }
                try fileHandle.write(contentsOf: headerData)

                // Write payload
                let payload = Data(bytes: buffer, count: n)
                try fileHandle.write(contentsOf: payload)

                // Also pipe to stdout so user sees what's happening
                FileHandle.standardOutput.write(payload)
            }

            // Reap child
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)

            FileHandle.standardError.write(Data("\nRecording complete: \(output)\n".utf8))
        }
    }
}
