import ArgumentParser
import Foundation
import AppKit
import SwiftTerm

extension SwiftTermReplay {

    struct Replay: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Replay a ttyrec file through a SwiftTerm view."
        )

        @Option(name: .shortAndLong, help: "Input ttyrec file")
        var input: String

        @Option(name: .shortAndLong, help: "Speed multiplier (1.0 = real-time, 0 = instant)")
        var speed: Double = 1.0

        mutating func run() throws {
            let inputURL = URL(fileURLWithPath: input)
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                throw ValidationError("Input file not found: \(input)")
            }

            // Read entire file (small enough for now; stream for >100MB later)
            let data = try Data(contentsOf: inputURL)
            let chunks = try Self.parseTtyrec(data: data)
            FileHandle.standardError.write(
                Data("Loaded \(chunks.count) chunks from \(input)\n".utf8)
            )

            // Set up minimal NSApp window with SwiftTerm
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)

            let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            let window = NSWindow(
                contentRect: view.frame,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SwiftTermReplay: \(inputURL.lastPathComponent)"
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)

            // Schedule chunk feeds
            let speedCopy = speed
            DispatchQueue.global().async {
                var lastTime: Double = 0
                for chunk in chunks {
                    let delay = (chunk.timestamp - lastTime) / max(speedCopy, 0.001)
                    if speedCopy > 0 && delay > 0 {
                        Thread.sleep(forTimeInterval: delay)
                    }
                    let payload = chunk.payload
                    DispatchQueue.main.async {
                        view.feed(byteArray: ArraySlice(payload))
                    }
                    lastTime = chunk.timestamp
                }
                FileHandle.standardError.write(Data("Replay complete.\n".utf8))
            }

            app.run()
        }

        struct Chunk {
            let timestamp: Double  // sec + usec/1e6
            let payload: [UInt8]
        }

        /// Read a little-endian Int32 from `data` at `offset` without requiring
        /// pointer alignment. Required because Data slices may begin at any byte
        /// boundary; `load(as:)` traps on misaligned reads.
        static func readLEInt32(_ data: Data, at offset: Int) -> Int32 {
            let b0 = UInt32(data[data.startIndex + offset])
            let b1 = UInt32(data[data.startIndex + offset + 1])
            let b2 = UInt32(data[data.startIndex + offset + 2])
            let b3 = UInt32(data[data.startIndex + offset + 3])
            let u = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
            return Int32(bitPattern: u)
        }

        static func parseTtyrec(data: Data) throws -> [Chunk] {
            var chunks: [Chunk] = []
            var index = 0
            while index + 12 <= data.count {
                let sec = readLEInt32(data, at: index)
                let usec = readLEInt32(data, at: index + 4)
                let lenRaw = readLEInt32(data, at: index + 8)
                let len = Int(lenRaw)
                index += 12
                guard len >= 0 && index + len <= data.count else {
                    throw ValidationError("Truncated ttyrec at offset \(index) (len=\(len), remaining=\(data.count - index))")
                }
                let payload = Array(data[(data.startIndex + index)..<(data.startIndex + index + len)])
                let timestamp = Double(sec) + Double(usec) / 1_000_000
                chunks.append(Chunk(timestamp: timestamp, payload: payload))
                index += len
            }
            return chunks
        }
    }
}
