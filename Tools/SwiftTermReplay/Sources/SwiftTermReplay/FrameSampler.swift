import AppKit
import CoreGraphics

/// C.2.0: Captures bitmap snapshots of a view at fixed interval during
/// replay. analyze() returns total samples + run-lengths of "mid-state
/// clusters" (consecutive frames where >20% of sampled pixels differ from
/// the immediate predecessor).
///
/// Why this exists: SwiftTerm renderer rewrite (C.2.1+) is 3-4 months of
/// systems programming. Without a measurable baseline metric, "less flicker"
/// is anecdotal. FrameSampler quantifies: "upstream shows N mid-state
/// frames > 16ms" — we compare against this number after each renderer change.
@MainActor
final class FrameSampler {

    private var samples: [(timestamp: TimeInterval, image: CGImage)] = []
    private var timer: Timer?
    private weak var view: NSView?
    private let startTime = Date()

    init(view: NSView) { self.view = view }

    /// Default 8ms = 120Hz oversampling vs 60Hz display refresh, so we
    /// catch in-between-vsync states.
    func start(intervalSeconds: TimeInterval = 0.008) {
        timer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let view = self.view else { return }
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                if let cgImage = rep.cgImage {
                    self.samples.append((Date().timeIntervalSince(self.startTime), cgImage))
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Total samples + durations of mid-state clusters (in seconds).
    /// A "mid-state cluster" is a run of consecutive frames where each
    /// differs from its predecessor by > pixelChangeThreshold (0.0 to 1.0).
    func analyze(pixelChangeThreshold: Double = 0.2) -> (total: Int, midStateClusters: [TimeInterval]) {
        guard samples.count >= 2 else { return (samples.count, []) }
        var clusters: [TimeInterval] = []
        var clusterStart: TimeInterval?
        var prevImage = samples[0].image
        for i in 1..<samples.count {
            let curr = samples[i].image
            let changed = Self.pixelChangeRatio(prevImage, curr)
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
        // close final open cluster
        if let start = clusterStart {
            clusters.append(samples.last!.timestamp - start)
        }
        return (samples.count, clusters)
    }

    /// Crude: sample 200 random pixels from both images via direct pixel
    /// access, count how many differ. Returns ratio 0.0-1.0.
    ///
    /// Acceptable approximation for "detect rapid full-area redraw" use case.
    /// Perfect frame diff via PNG comparison is too slow for the 8ms sampling
    /// loop; this gets us a usable signal in microseconds.
    private static func pixelChangeRatio(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1.0 }
        let w = a.width
        let h = a.height
        guard w > 0, h > 0 else { return 0 }

        // Sample 200 random points
        let samplePoints = 200
        var diffs = 0
        for _ in 0..<samplePoints {
            let x = Int.random(in: 0..<w)
            let y = Int.random(in: 0..<h)
            if let aPixel = pixelAt(image: a, x: x, y: y),
               let bPixel = pixelAt(image: b, x: x, y: y) {
                // Tolerate small per-channel differences (antialiasing noise)
                let delta = abs(Int(aPixel.r) - Int(bPixel.r))
                    + abs(Int(aPixel.g) - Int(bPixel.g))
                    + abs(Int(aPixel.b) - Int(bPixel.b))
                if delta > 30 { diffs += 1 }
            }
        }
        return Double(diffs) / Double(samplePoints)
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
