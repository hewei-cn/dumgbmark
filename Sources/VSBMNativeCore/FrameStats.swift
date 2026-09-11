import Foundation
import os

/// Timing and configuration reported in the HUD and in exports.
public struct StatsContext: Sendable, Equatable {
    public var preset: String = "-"
    public var kernel: String = "-"
    public var backend: String = "-"
    public var fidelity: String = "faithful"
    public var renderWidth: Int = 0
    public var renderHeight: Int = 0
    public var outputWidth: Int = 0
    public var outputHeight: Int = 0
    public var renderScale: Double = 1
    public var autoScale: Bool = false
    public var targetFPS: Double = 0
    public var stepScale: Double = 1
    public var thermalState: String = "-"
    public var boundingRadius: Double = 0
    public var deviceName: String = "-"

    public init() {}
}

/// A consistent view of the counters, safe to hand to the UI thread.
public struct FrameStatsSnapshot: Sendable {
    public var instantFPS: Double = 0
    public var averageFPS: Double = 0
    /// 1% low computed over the last 600 frame intervals, exactly as the
    /// reference renderer reports it.
    public var onePercentLowFPS: Double = 0
    public var medianGPUMs: Double = 0
    public var p99GPUMs: Double = 0
    public var minGPUMs: Double = 0
    public var maxGPUMs: Double = 0
    public var lastGPUMs: Double = 0
    public var lastEncodeMs: Double = 0
    public var totalFrames: UInt64 = 0
    public var elapsedSeconds: Double = 0
    public var skippedFrames: UInt64 = 0
    public var context = StatsContext()

    public init() {}

    /// Estimated headroom at the current settings: how many times the current
    /// GPU frame time fits into one second.
    public var gpuBoundFPS: Double { medianGPUMs > 0 ? 1000.0 / medianGPUMs : 0 }
}

/// Lock-protected frame timing accumulator.
///
/// The render loop feeds it; the UI thread reads consistent snapshots. Keeping
/// the lock scope tiny means the render loop never blocks on the UI.
public final class FrameStats {

    /// The reference keeps 600 frame intervals for its 1% low.
    public static let frameWindow = 600
    /// The reference refreshes its FPS counter twice a second.
    public static let fpsUpdateInterval = 0.5
    /// GPU time window used for the median that drives adaptive resolution.
    public static let gpuWindow = 120

    private var lock = os_unfair_lock_s()

    private var frameTimes = [Double](repeating: 0, count: frameWindow)
    private var frameTimeCount = 0
    private var frameTimeHead = 0

    private var gpuTimes = [Double](repeating: 0, count: gpuWindow)
    private var gpuTimeCount = 0
    private var gpuTimeHead = 0

    private var lastEncodeMs: Double = 0
    private var lastGPUMs: Double = 0

    private var displayWindowStart: Double = 0
    private var displayWindowFrames: UInt64 = 0
    private var instantFPS: Double = 0

    private var totalFrames: UInt64 = 0
    private var startTime: Double = 0
    private var lastFrameTime: Double = 0
    private var elapsedBeforeReset: Double = 0
    private var skippedFrames: UInt64 = 0
    private var context = StatsContext()

    /// Raw frame intervals in milliseconds, newest last. For CSV export.
    private var exportedIntervals: [Double] = []
    private var exportedGPUTimes: [Double] = []
    private var exportLimit = 60_000

    public init() {
        let now = FrameStats.now()
        startTime = now
        lastFrameTime = now
        displayWindowStart = now
    }

    private static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
    }

    // MARK: Recording

    /// - Parameters:
    ///   - gpuMs: GPU execution time of the frame, from `gpuStartTime`/`gpuEndTime`.
    ///   - encodeMs: CPU time spent encoding the frame.
    public func record(gpuMs: Double, encodeMs: Double) {
        let now = FrameStats.now()
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if lastFrameTime > 0 {
            let intervalMs = (now - lastFrameTime) * 1000.0
            frameTimes[frameTimeHead] = intervalMs
            frameTimeHead = (frameTimeHead + 1) % FrameStats.frameWindow
            frameTimeCount = min(frameTimeCount + 1, FrameStats.frameWindow)
            if exportedIntervals.count < exportLimit {
                exportedIntervals.append(intervalMs)
            }
        }
        lastFrameTime = now

        if gpuMs > 0 {
            gpuTimes[gpuTimeHead] = gpuMs
            gpuTimeHead = (gpuTimeHead + 1) % FrameStats.gpuWindow
            gpuTimeCount = min(gpuTimeCount + 1, FrameStats.gpuWindow)
            if exportedGPUTimes.count < exportLimit {
                exportedGPUTimes.append(gpuMs)
            }
        }

        lastGPUMs = gpuMs
        lastEncodeMs = encodeMs
        totalFrames += 1
        displayWindowFrames += 1

        let windowElapsed = now - displayWindowStart
        if windowElapsed >= FrameStats.fpsUpdateInterval {
            instantFPS = Double(displayWindowFrames) / windowElapsed
            displayWindowStart = now
            displayWindowFrames = 0
        }
    }

    public func recordSkippedFrame() {
        os_unfair_lock_lock(&lock)
        skippedFrames += 1
        os_unfair_lock_unlock(&lock)
    }

    public func updateContext(_ mutate: (inout StatsContext) -> Void) {
        os_unfair_lock_lock(&lock)
        mutate(&context)
        os_unfair_lock_unlock(&lock)
    }

    public func reset() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        frameTimeCount = 0
        frameTimeHead = 0
        gpuTimeCount = 0
        gpuTimeHead = 0
        totalFrames = 0
        skippedFrames = 0
        instantFPS = 0
        displayWindowFrames = 0
        let now = FrameStats.now()
        startTime = now
        displayWindowStart = now
        lastFrameTime = now
        exportedIntervals.removeAll(keepingCapacity: true)
        exportedGPUTimes.removeAll(keepingCapacity: true)
    }

    // MARK: Snapshot

    public func snapshot() -> FrameStatsSnapshot {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        var s = FrameStatsSnapshot()
        s.context = context
        s.instantFPS = instantFPS
        s.totalFrames = totalFrames
        s.skippedFrames = skippedFrames
        s.elapsedSeconds = FrameStats.now() - startTime
        s.lastEncodeMs = lastEncodeMs
        s.lastGPUMs = lastGPUMs
        s.averageFPS = s.elapsedSeconds > 0 ? Double(totalFrames) / s.elapsedSeconds : 0

        if frameTimeCount > 0 {
            let intervals = newestFirstIntervals()
            let count = intervals.count
            // Reference: sorted descending, index floor(n * 0.01).
            let idx = min(Int(Double(count) * 0.01), count - 1)
            let worst = intervals[idx]
            s.onePercentLowFPS = worst > 0 ? 1000.0 / worst : 0
        }

        if gpuTimeCount > 0 {
            let values = gpuValues().sorted()
            s.medianGPUMs = values[values.count / 2]
            s.minGPUMs = values.first ?? 0
            s.maxGPUMs = values.last ?? 0
            let p99 = min(Int(Double(values.count) * 0.99), values.count - 1)
            s.p99GPUMs = values[p99]
        }
        return s
    }

    /// Rolling median of recent GPU times — the signal adaptive resolution uses.
    public func medianGPUMs() -> Double {
        medianGPUMs(recent: FrameStats.gpuWindow)
    }

    /// Median of only the most recent `recent` GPU samples.
    ///
    /// The controller must measure a window that has completely turned over
    /// since its last change; using the full 120-sample window after a change
    /// means reacting to stale timings and oscillating.
    public func medianGPUMs(recent: Int) -> Double {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard gpuTimeCount > 0 else { return 0 }
        let take = min(max(recent, 1), gpuTimeCount)
        var values: [Double] = []
        values.reserveCapacity(take)
        for i in (gpuTimeCount - take)..<gpuTimeCount {
            let idx = (gpuTimeHead - gpuTimeCount + i + FrameStats.gpuWindow * 2) % FrameStats.gpuWindow
            values.append(gpuTimes[idx])
        }
        values.sort()
        return values[values.count / 2]
    }

    private func gpuValues() -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(gpuTimeCount)
        for i in 0..<gpuTimeCount {
            let idx = (gpuTimeHead - gpuTimeCount + i + FrameStats.gpuWindow * 2) % FrameStats.gpuWindow
            out.append(gpuTimes[idx])
        }
        return out
    }

    /// Frame intervals, longest first — the reference's 1% low ordering.
    private func newestFirstIntervals() -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(frameTimeCount)
        for i in 0..<frameTimeCount {
            let idx = (frameTimeHead - frameTimeCount + i + FrameStats.frameWindow * 2) % FrameStats.frameWindow
            out.append(frameTimes[idx])
        }
        out.sort(by: >)
        return out
    }

    // MARK: Export

    public func exportFrameIntervalsCSV() -> String {
        os_unfair_lock_lock(&lock)
        let intervals = exportedIntervals
        let gpu = exportedGPUTimes
        os_unfair_lock_unlock(&lock)

        var out = "frame,interval_ms,gpu_ms\n"
        let n = max(intervals.count, gpu.count)
        out.reserveCapacity(n * 32)
        for i in 0..<n {
            let iv = i < intervals.count ? String(format: "%.4f", intervals[i]) : ""
            let gv = i < gpu.count ? String(format: "%.4f", gpu[i]) : ""
            out += "\(i),\(iv),\(gv)\n"
        }
        return out
    }

    public func exportReportJSON(_ snapshot: FrameStatsSnapshot) -> String {
        let c = snapshot.context
        let number = { (v: Double) -> String in String(format: "%.4f", v) }
        var out = "{\n"
        out += "  \"generatedAt\": \"\(ISO8601DateFormatter().string(from: Date()))\",\n"
        out += "  \"device\": \"\(escape(c.deviceName))\",\n"
        out += "  \"preset\": \"\(escape(c.preset))\",\n"
        out += "  \"kernel\": \"\(escape(c.kernel))\",\n"
        out += "  \"backend\": \"\(escape(c.backend))\",\n"
        out += "  \"fidelity\": \"\(escape(c.fidelity))\",\n"
        out += "  \"renderWidth\": \(c.renderWidth),\n"
        out += "  \"renderHeight\": \(c.renderHeight),\n"
        out += "  \"outputWidth\": \(c.outputWidth),\n"
        out += "  \"outputHeight\": \(c.outputHeight),\n"
        out += "  \"renderScale\": \(number(c.renderScale)),\n"
        out += "  \"autoScale\": \(c.autoScale),\n"
        out += "  \"targetFPS\": \(number(c.targetFPS)),\n"
        out += "  \"stepScale\": \(number(c.stepScale)),\n"
        out += "  \"boundingRadius\": \(number(c.boundingRadius)),\n"
        out += "  \"thermalState\": \"\(escape(c.thermalState))\",\n"
        out += "  \"totalFrames\": \(snapshot.totalFrames),\n"
        out += "  \"skippedFrames\": \(snapshot.skippedFrames),\n"
        out += "  \"elapsedSeconds\": \(number(snapshot.elapsedSeconds)),\n"
        out += "  \"instantFPS\": \(number(snapshot.instantFPS)),\n"
        out += "  \"averageFPS\": \(number(snapshot.averageFPS)),\n"
        out += "  \"onePercentLowFPS\": \(number(snapshot.onePercentLowFPS)),\n"
        out += "  \"gpuMedianMs\": \(number(snapshot.medianGPUMs)),\n"
        out += "  \"gpuP99Ms\": \(number(snapshot.p99GPUMs)),\n"
        out += "  \"gpuMinMs\": \(number(snapshot.minGPUMs)),\n"
        out += "  \"gpuMaxMs\": \(number(snapshot.maxGPUMs)),\n"
        out += "  \"encodeMs\": \(number(snapshot.lastEncodeMs))\n"
        out += "}\n"
        return out
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
