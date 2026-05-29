import AppKit
import CoreGraphics
import Metal
import MetalKit

/// C.2.0: Captures bitmap snapshots of a view at fixed interval during
/// replay. analyze() returns total samples + run-lengths of "mid-state
/// clusters" (consecutive frames where >20% of sampled pixels differ from
/// the immediate predecessor).
///
/// Why this exists: SwiftTerm renderer rewrite (C.2.1+) is 3-4 months of
/// systems programming. Without a measurable baseline metric, "less flicker"
/// is anecdotal. FrameSampler quantifies: "upstream shows N mid-state
/// frames > 16ms" — we compare against this number after each renderer change.
///
/// C.2 round 2: two capture paths, branched on whether the SwiftTerm view is
/// running the Metal renderer:
///   - CoreGraphics (default): `NSView.cacheDisplay(in:to:)` reads the view's
///     CG-drawn layer back into a bitmap. Works fine for the default path.
///   - Metal: the renderer draws into a child `MTKView`'s GPU drawable, which
///     `cacheDisplay` cannot read back. Instead we locate the MTKView subview,
///     flip its public `framebufferOnly` to false so the drawable texture is
///     CPU-readable, drive a synchronous `draw()` at sample time, and copy the
///     presented drawable texture's pixels with `getBytes`. Both paths feed the
///     SAME deterministic grid-diff metric, so the numbers are comparable.
@MainActor
final class FrameSampler {

    private var samples: [(timestamp: TimeInterval, image: CGImage)] = []
    private var timer: Timer?
    private weak var view: NSView?
    private let startTime = Date()

    // Metal capture state. Non-nil only when the view is running Metal.
    private weak var metalView: MTKView?
    private var readbackBuffer: [UInt8] = []

    init(view: NSView) { self.view = view }

    /// Locate the MTKView subview created by `setUseMetal(true)` and prepare it
    /// for CPU readback. Call AFTER `setUseMetal(true)`. Returns true if a
    /// Metal view was found and configured.
    @discardableResult
    func enableMetalCapture() -> Bool {
        guard let view, let mtk = Self.findMTKView(in: view) else { return false }
        // Public MTKView property — flipping it lets us getBytes from the
        // drawable texture. Set from the replay tool; no fork edit required.
        mtk.framebufferOnly = false
        metalView = mtk
        return true
    }

    private static func findMTKView(in view: NSView) -> MTKView? {
        if let mtk = view as? MTKView { return mtk }
        for sub in view.subviews {
            if let found = findMTKView(in: sub) { return found }
        }
        return nil
    }

    /// Default 8ms = 120Hz oversampling vs 60Hz display refresh, so we
    /// catch in-between-vsync states.
    func start(intervalSeconds: TimeInterval = 0.008) {
        timer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.metalView != nil {
                    self.sampleMetal()
                } else {
                    self.sampleCoreGraphics()
                }
            }
        }
    }

    private func sampleCoreGraphics() {
        guard let view = self.view else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let cgImage = rep.cgImage {
            self.samples.append((Date().timeIntervalSince(self.startTime), cgImage))
        }
    }

    /// Drive a synchronous Metal draw, then read the presented drawable's
    /// texture back into a CGImage. The MTKView is paused + draw-on-demand, so
    /// `draw()` runs the renderer's `draw(in:)` and presents into
    /// `currentDrawable`; with `framebufferOnly = false` that texture is
    /// CPU-readable via `getBytes`.
    private func sampleMetal() {
        guard let mtk = metalView else { return }
        // Force the renderer to produce a fresh frame for the current terminal
        // state. With isPaused + enableSetNeedsDisplay, draw() invokes the
        // delegate's draw(in:) synchronously on this (main) thread.
        mtk.draw()
        guard let texture = mtk.currentDrawable?.texture else { return }
        if let cgImage = Self.cgImage(from: texture, scratch: &readbackBuffer) {
            self.samples.append((Date().timeIntervalSince(self.startTime), cgImage))
        }
    }

    /// Copy a BGRA8 MTLTexture into a CGImage (BGRA -> the metric only needs
    /// magnitude, so channel order is irrelevant as long as it is consistent).
    private static func cgImage(from texture: MTLTexture, scratch: inout [UInt8]) -> CGImage? {
        let width = texture.width
        let height = texture.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let byteCount = bytesPerRow * height
        if scratch.count != byteCount { scratch = [UInt8](repeating: 0, count: byteCount) }
        let region = MTLRegionMake2D(0, 0, width, height)
        scratch.withUnsafeMutableBytes { ptr in
            texture.getBytes(ptr.baseAddress!,
                             bytesPerRow: bytesPerRow,
                             from: region,
                             mipmapLevel: 0)
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        // bgra8Unorm: bytes are B,G,R,A. Use byteOrder32Little + premultiplied
        // first so CoreGraphics interprets the BGRA byte layout correctly.
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: &scratch,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: cs,
                                  bitmapInfo: bitmapInfo.rawValue) else { return nil }
        return ctx.makeImage()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Number of frames captured so far. Used by the CLI to report whether the
    /// sampler observed any non-empty content (a Metal subview renders into a
    /// GPU drawable that `cacheDisplay` cannot read back, so this stays useful
    /// as a self-check that the chosen capture path actually sees pixels).
    var sampleCount: Int { samples.count }

    /// Debug aid: write up to `limit` evenly-spaced sampled frames to PNGs under
    /// `dir`. Lets a human eyeball whether the capture path produced real
    /// terminal pixels (CG) or blank GPU-drawable frames (Metal subview).
    func dumpFrames(to dir: URL, limit: Int = 6) {
        guard !samples.isEmpty else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let step = max(1, samples.count / limit)
        var written = 0
        var i = 0
        while i < samples.count && written < limit {
            let rep = NSBitmapImageRep(cgImage: samples[i].image)
            if let png = rep.representation(using: .png, properties: [:]) {
                let url = dir.appendingPathComponent(String(format: "frame-%03d.png", i))
                try? png.write(to: url)
                written += 1
            }
            i += step
        }
    }

    /// Aggregate statistics emitted by `analyze()`.
    ///
    /// - total: number of frames sampled.
    /// - midStateClusters: durations (seconds) of runs of consecutive frames
    ///   where each differs from its predecessor by > pixelChangeThreshold.
    /// - midStateFrames: count of individual frames classified as a transient
    ///   "mid-state" — a frame that is substantially BLANKER than both its
    ///   immediate neighbours. This is the Edit-tool tearing signature: a
    ///   region was cleared (frame goes mostly background) but the reprint
    ///   has not yet landed, so the frame is a transient blank between two
    ///   filled frames.
    /// - maxChangeRatio: the largest single inter-frame change ratio observed.
    struct Stats {
        var total: Int
        var midStateClusters: [TimeInterval]
        var midStateFrames: Int
        var maxChangeRatio: Double
    }

    /// Total samples + durations of mid-state clusters + count of transient
    /// blank frames. Deterministic: uses a fixed pixel grid (no RNG), so a
    /// given sample sequence always yields the same numbers.
    ///
    /// - Parameters:
    ///   - pixelChangeThreshold: fraction of grid points that must differ from
    ///     the previous frame for the frame to count as "changed" (cluster).
    ///   - blankDropThreshold: how much LESS foreground a frame must have than
    ///     both neighbours to be flagged a transient blank mid-state frame.
    func analyze(pixelChangeThreshold: Double = 0.2,
                 blankDropThreshold: Double = 0.15) -> Stats {
        guard samples.count >= 2 else {
            return Stats(total: samples.count, midStateClusters: [],
                         midStateFrames: 0, maxChangeRatio: 0)
        }

        // Precompute foreground coverage per frame (fraction of grid points
        // that are NOT background). The background is taken to be the very
        // first sampled frame's dominant colour (terminal default bg).
        let bg = Self.dominantColor(samples[0].image)
        let coverage = samples.map { Self.foregroundCoverage($0.image, background: bg) }

        if ProcessInfo.processInfo.environment["FRAMESAMPLER_TRACE"] != nil {
            let line = coverage.enumerated()
                .map { String(format: "%d:%.2f", $0.offset, $0.element) }
                .joined(separator: " ")
            FileHandle.standardError.write(Data(("COVERAGE " + line + "\n").utf8))
        }

        var clusters: [TimeInterval] = []
        var clusterStart: TimeInterval?
        var midStateFrames = 0
        var maxChange = 0.0

        var prevImage = samples[0].image
        for i in 1..<samples.count {
            let curr = samples[i].image
            let changed = Self.pixelChangeRatio(prevImage, curr)
            maxChange = max(maxChange, changed)
            if changed > pixelChangeThreshold {
                if clusterStart == nil {
                    clusterStart = samples[i-1].timestamp
                }
            } else if let start = clusterStart {
                let end = samples[i].timestamp
                clusters.append(end - start)
                clusterStart = nil
            }
            prevImage = curr
        }
        if let start = clusterStart {
            clusters.append(samples.last!.timestamp - start)
        }

        // Detect transient blank mid-state frames. The Edit-tool tearing
        // signature is a region that gets CLEARED (coverage drops toward the
        // background) and stays blank for a run of frames before the reprint
        // lands — i.e. a "valley" of low coverage bracketed by filled frames
        // on both sides. We classify a frame as a mid-state blank frame when:
        //   (a) its coverage is blankDropThreshold below the run's filled
        //       baseline (the max coverage seen), AND
        //   (b) it lies between a filled frame earlier and a filled frame later
        //       (so it is a transient valley, not a trailing fade-to-black).
        let baseline = coverage.max() ?? 0
        let blankCeiling = baseline - blankDropThreshold
        if baseline > blankDropThreshold {
            // Index of last filled frame at or before i, and first filled
            // frame at or after i, computed via simple scans.
            for i in 0..<samples.count where coverage[i] < blankCeiling {
                let filledBefore = (0..<i).contains { coverage[$0] >= blankCeiling }
                let filledAfter = ((i+1)..<samples.count).contains { coverage[$0] >= blankCeiling }
                if filledBefore && filledAfter {
                    midStateFrames += 1
                }
            }
        }

        return Stats(total: samples.count,
                     midStateClusters: clusters,
                     midStateFrames: midStateFrames,
                     maxChangeRatio: maxChange)
    }

    /// Deterministic full-frame diff over a fixed stride grid (no RNG, so the
    /// run-length clustering is reproducible). Returns ratio 0.0-1.0 of grid
    /// points whose summed RGB delta exceeds the antialiasing tolerance.
    ///
    /// Perfect per-pixel diff would be too slow for the 8ms sampling loop; a
    /// ~32x24 grid (768 points) is a stable signal computed in microseconds.
    private static func pixelChangeRatio(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1.0 }
        let w = a.width, h = a.height
        guard w > 0, h > 0 else { return 0 }

        let cols = min(32, w)
        let rows = min(24, h)
        var diffs = 0
        var seen = 0
        for gy in 0..<rows {
            let y = (gy * h) / rows + (h / rows) / 2
            for gx in 0..<cols {
                let x = (gx * w) / cols + (w / cols) / 2
                guard let ap = pixelAt(image: a, x: x, y: y),
                      let bp = pixelAt(image: b, x: x, y: y) else { continue }
                seen += 1
                let delta = abs(Int(ap.r) - Int(bp.r))
                    + abs(Int(ap.g) - Int(bp.g))
                    + abs(Int(ap.b) - Int(bp.b))
                if delta > 30 { diffs += 1 }
            }
        }
        return seen > 0 ? Double(diffs) / Double(seen) : 0
    }

    /// Fraction of the fixed grid whose pixels differ from `background` by more
    /// than the antialiasing tolerance — i.e. how much foreground ("ink") the
    /// frame currently shows. A cleared region drops this toward 0.
    private static func foregroundCoverage(_ img: CGImage,
                                           background: (r: UInt8, g: UInt8, b: UInt8)) -> Double {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return 0 }
        let cols = min(32, w)
        let rows = min(24, h)
        var fg = 0
        var seen = 0
        for gy in 0..<rows {
            let y = (gy * h) / rows + (h / rows) / 2
            for gx in 0..<cols {
                let x = (gx * w) / cols + (w / cols) / 2
                guard let p = pixelAt(image: img, x: x, y: y) else { continue }
                seen += 1
                let delta = abs(Int(p.r) - Int(background.r))
                    + abs(Int(p.g) - Int(background.g))
                    + abs(Int(p.b) - Int(background.b))
                if delta > 30 { fg += 1 }
            }
        }
        return seen > 0 ? Double(fg) / Double(seen) : 0
    }

    /// Coarse dominant colour: most common pixel on the fixed grid. Used as the
    /// background reference for foreground-coverage / blankness detection.
    private static func dominantColor(_ img: CGImage) -> (r: UInt8, g: UInt8, b: UInt8) {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return (0, 0, 0) }
        let cols = min(32, w)
        let rows = min(24, h)
        var counts: [UInt32: Int] = [:]
        for gy in 0..<rows {
            let y = (gy * h) / rows + (h / rows) / 2
            for gx in 0..<cols {
                let x = (gx * w) / cols + (w / cols) / 2
                guard let p = pixelAt(image: img, x: x, y: y) else { continue }
                // Quantize to 5 bits/channel to bucket antialiasing noise.
                let key = (UInt32(p.r >> 3) << 10) | (UInt32(p.g >> 3) << 5) | UInt32(p.b >> 3)
                counts[key, default: 0] += 1
            }
        }
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return (0, 0, 0) }
        let r = UInt8(((best >> 10) & 0x1F) << 3)
        let g = UInt8(((best >> 5) & 0x1F) << 3)
        let b = UInt8((best & 0x1F) << 3)
        return (r, g, b)
    }

    private static func pixelAt(image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let bpr = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8  // typically 4 (RGBA)
        guard bpp >= 3 else { return nil }
        let offset = y * bpr + x * bpp
        // Channel order varies; assume BGRA for macOS bitmap reps (default).
        // We only care about diff magnitude so exact ordering doesn't matter
        // as long as it's consistent between the two samples.
        return (r: bytes[offset], g: bytes[offset + 1], b: bytes[offset + 2])
    }
}
