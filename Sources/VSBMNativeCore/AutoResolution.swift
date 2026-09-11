import CoreGraphics
import Foundation

/// Chooses the internal render resolution.
///
/// Measured on an M4, the marcher's cost is linear in pixel count (1024² = 95.3 ms,
/// 512² = 24.3 ms, a ratio of 3.9). Resolution is therefore the first-order
/// lever for frame rate, and this controller is what turns a bit-faithful but
/// slow renderer into a high-frame-rate one.
public final class AutoResolution {

    /// Target frames per second. 0 disables adaptation.
    public var targetFPS: Double = 60
    public var enabled: Bool = true
    public var minScale: Double = 0.15
    /// Upper bound, lowered further when the machine is thermally limited.
    public var baseMaxScale: Double = 1.0

    /// Frames to wait after a change before adapting again.
    ///
    /// This must be at least as long as the window `measurementWindow` is
    /// averaged over, otherwise the controller reacts to timings that still
    /// describe the previous resolution and oscillates around the target instead
    /// of converging. A 20% scale step is a 44% step in cost (cost is quadratic
    /// in scale), which is far larger than the dead band, so stale samples are
    /// not a small error.
    public var settleFrames: Int = 24

    /// How many recent GPU samples the controller averages. Kept in sync with
    /// the value passed to `FrameStats.medianGPUMs(recent:)`.
    public static let measurementWindow = 24
    /// Do nothing while the measured budget ratio is inside this dead band.
    ///
    /// Cost is quadratic in scale, so a step factor `s` shifts the ratio by
    /// `s^2`. The dead band must be wide enough to absorb that plus measurement
    /// noise, otherwise the controller always overshoots and hunts.
    public var deadBand: Double = 0.12
    /// Step limits while far from the budget: converge quickly.
    public var maxStepUp: Double = 1.25
    public var maxStepDown: Double = 0.80
    /// Step limits once near the budget: settle without overshooting.
    public var fineStepUp: Double = 1.05
    public var fineStepDown: Double = 0.94
    /// Ratio error beyond which the coarse step limits apply.
    public var coarseThreshold: Double = 0.40

    public private(set) var scale: Double = 1.0
    public private(set) var changes: Int = 0
    public private(set) var lastReason: String = "initial"

    private var framesSinceChange: Int = 0
    private var thermalCap: Double = 1.0

    public init() {}

    public var maxScale: Double { min(baseMaxScale, thermalCap) }

    public func reset(to value: Double) {
        scale = min(max(value, minScale), maxScale)
        framesSinceChange = 0
        changes = 0
        lastReason = "reset"
    }

    /// Applies a thermal cap. Returns true when the cap changed.
    @discardableResult
    public func setThermalCap(_ cap: Double) -> Bool {
        let clamped = min(max(cap, minScale), 1.0)
        guard clamped != thermalCap else { return false }
        thermalCap = clamped
        if scale > maxScale {
            scale = maxScale
            framesSinceChange = 0
            lastReason = "thermal clamp"
        }
        return true
    }

    /// Feeds the rolling median GPU time and returns the scale to use next.
    @discardableResult
    public func update(medianGPUMs: Double) -> Double {
        guard enabled, targetFPS > 0, medianGPUMs > 0 else { return scale }

        framesSinceChange += 1
        guard framesSinceChange >= settleFrames else { return scale }

        let budget = 1000.0 / targetFPS
        let ratio = budget / medianGPUMs
        if abs(ratio - 1.0) <= deadBand {
            lastReason = String(format: "in band (%.2f)", ratio)
            return scale
        }

        // Cost is proportional to pixels, so the ideal scale scales with
        // sqrt(budget / measured). Far from the budget take big steps; close to
        // it, small ones, so convergence is fast but the controller does not
        // oscillate around the target.
        let ideal = scale * ratio.squareRoot()
        let coarse = abs(ratio - 1.0) > coarseThreshold
        let stepDown = coarse ? maxStepDown : fineStepDown
        let stepUp = coarse ? maxStepUp : fineStepUp
        let lower = max(scale * stepDown, minScale)
        let upper = min(scale * stepUp, maxScale)
        let clamped = min(max(ideal, lower), upper)

        guard abs(clamped - scale) > 0.005 else {
            lastReason = String(format: "step too small (%.3f)", clamped)
            return scale
        }

        let direction = clamped < scale ? "down" : "up"
        scale = clamped
        framesSinceChange = 0
        changes += 1
        lastReason = String(format: "%@ to %.3f (budget ratio %.2f)", direction, clamped, ratio)
        return scale
    }
}

/// Maps a preset resolution and a scale onto concrete pixel dimensions.
public enum RenderSizing {

    public static let maxDimension = 4096
    public static let minDimension = 64

    public static func renderSize(
        pointSize: CGSize,
        backingScale: CGFloat,
        resolution: RenderResolution,
        scale: Double
    ) -> (width: Int, height: Int) {
        let base = resolution.baseSize(pointSize: pointSize, backingScale: backingScale)
        let w = Int((Double(base.width) * scale).rounded())
        let h = Int((Double(base.height) * scale).rounded())
        return (
            width: min(max(w, minDimension), maxDimension),
            height: min(max(h, minDimension), maxDimension)
        )
    }

    /// True when the marcher can write straight into the drawable.
    public static func canRenderDirectly(
        render: (width: Int, height: Int), output: (width: Int, height: Int)
    ) -> Bool {
        render.width == output.width && render.height == output.height
    }
}
