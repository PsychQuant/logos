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

        @Option(
            name: .long,
            help: "Sample frames every N ms during replay and print mid-state cluster analysis at exit (C.2.0 baseline metric)"
        )
        var sampleFrames: Double?

        @Flag(
            name: .long,
            help: "Render through the SwiftTerm Metal GPU path (setUseMetal(true) + perRowPersistent) instead of the default CoreGraphics path. MEASUREMENT ONLY — the shipped Logos app never enables Metal."
        )
        var metal: Bool = false

        @Option(
            name: .long,
            help: "Write a few sampled frames as PNGs to this directory (self-check that the capture path saw real pixels)."
        )
        var dumpFrames: String?

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

            // ArgumentParser invokes run() on the main thread, but the call is
            // nonisolated. All AppKit / window / Metal / sampler work must be
            // main-actor isolated; hop onto the main actor explicitly so Swift 6
            // strict concurrency is satisfied without warnings.
            let useMetal = metal
            try MainActor.assumeIsolated {
                try Self.runOnMain(chunks: chunks,
                                   inputURL: inputURL,
                                   speed: speed,
                                   sampleFrames: sampleFrames,
                                   useMetal: useMetal,
                                   dumpDir: dumpFrames)
            }
        }

        @MainActor
        static func runOnMain(chunks: [Chunk],
                              inputURL: URL,
                              speed: Double,
                              sampleFrames: Double?,
                              useMetal: Bool,
                              dumpDir: String?) throws {
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

            // C.2 DE-RISK: optionally switch the replay view to the Metal GPU
            // renderer. Must be done AFTER the view is attached to a window
            // (SwiftTerm API requirement) so the MTKView subview can be created.
            // This is MEASUREMENT-ONLY: nothing under Sources/Logos enables Metal.
            if useMetal {
                view.metalBufferingMode = .perRowPersistent
                do {
                    try view.setUseMetal(true)
                } catch {
                    throw ValidationError("setUseMetal(true) failed: \(error)")
                }
                FileHandle.standardError.write(
                    Data("Renderer: Metal (perRowPersistent), isUsingMetalRenderer=\(view.isUsingMetalRenderer)\n".utf8)
                )
            } else {
                FileHandle.standardError.write(Data("Renderer: CoreGraphics (default)\n".utf8))
            }

            // C.2.0: start frame sampler if requested.
            // Holder class so we can capture across the global DispatchQueue
            // closure without tripping Swift 6 sending-data-race diagnostics.
            final class SamplerHolder: @unchecked Sendable {
                var sampler: FrameSampler?
            }
            let holder = SamplerHolder()
            if let intervalMs = sampleFrames {
                let s = FrameSampler(view: view)
                if useMetal {
                    // Switch the sampler to GPU-texture readback. Without this
                    // the Metal drawable is unreadable via cacheDisplay.
                    let ok = s.enableMetalCapture()
                    FileHandle.standardError.write(
                        Data("Metal capture (texture readback) enabled: \(ok)\n".utf8)
                    )
                }
                s.start(intervalSeconds: intervalMs / 1000.0)
                holder.sampler = s
            }

            // Schedule chunk feeds
            DispatchQueue.global().async {
                var lastTime: Double = 0
                for chunk in chunks {
                    let delay = (chunk.timestamp - lastTime) / max(speed, 0.001)
                    if speed > 0 && delay > 0 {
                        Thread.sleep(forTimeInterval: delay)
                    }
                    let payload = chunk.payload
                    DispatchQueue.main.async {
                        view.feed(byteArray: ArraySlice(payload))
                    }
                    lastTime = chunk.timestamp
                }
                FileHandle.standardError.write(Data("Replay complete.\n".utf8))

                // C.2.0: print sampler results then exit cleanly
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    MainActor.assumeIsolated {
                        guard let s = holder.sampler else { return }
                        s.stop()
                        if let dumpDir {
                            s.dumpFrames(to: URL(fileURLWithPath: dumpDir))
                        }
                        let r = s.analyze()
                        let longClusters = r.midStateClusters.filter { $0 > 0.016 }
                        print("--- C.2 Renderer Metric (\(useMetal ? "Metal" : "CoreGraphics")) ---")
                        print("Total frames sampled: \(r.total)")
                        print("Mid-state blank frames (transient clear-without-reprint): \(r.midStateFrames)")
                        print("Mid-state clusters (any duration): \(r.midStateClusters.count)")
                        print("Mid-state clusters > 16ms (visually perceptible): \(longClusters.count)")
                        print(String(format: "Max inter-frame change ratio: %.3f", r.maxChangeRatio))
                        if let longest = r.midStateClusters.max() {
                            print(String(format: "Longest cluster: %.0fms", longest * 1000))
                        }
                        // Self-check: if NOTHING ever changed, the capture path
                        // did not observe real pixels.
                        if r.maxChangeRatio < 0.001 {
                            print("WARNING: max change ratio ~0 — the sampler never observed any pixel change.")
                            if useMetal {
                                print("         The Metal texture-readback path did not produce pixel changes;")
                                print("         check that framebufferOnly was flipped and the MTKView was found.")
                            }
                        }
                        NSApp.terminate(nil)
                    }
                }
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
