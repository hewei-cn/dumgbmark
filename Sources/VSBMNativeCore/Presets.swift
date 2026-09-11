import Foundation

/// A named bundle of render settings. Presets are deliberately exhaustive: a
/// user can always see and override every value through `Custom`.
public struct Preset: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let detail: String
    public var options: RenderOptions
    public var resolution: RenderResolution
    public var cameraLen: Double
    /// Fixed render scale, used when `autoScale` is false.
    public var fixedScale: Double
    /// Let `AutoResolution` drive the render scale.
    public var autoScale: Bool
    public var targetFPS: Double
    public var rotationMode: Camera.RotationMode
    /// Run without presenting, for raw GPU throughput measurement.
    public var offscreen: Bool

    public init(
        id: String,
        name: String,
        detail: String,
        options: RenderOptions,
        resolution: RenderResolution,
        cameraLen: Double,
        fixedScale: Double,
        autoScale: Bool,
        targetFPS: Double,
        rotationMode: Camera.RotationMode,
        offscreen: Bool = false
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.options = options
        self.resolution = resolution
        self.cameraLen = cameraLen
        self.fixedScale = fixedScale
        self.autoScale = autoScale
        self.targetFPS = targetFPS
        self.rotationMode = rotationMode
        self.offscreen = offscreen
    }
}

public enum Presets {

    /// Pixel-for-pixel the original renderer. Scores from this preset are the
    /// only ones comparable with the web benchmark.
    public static let reference: Preset = {
        var o = RenderOptions()
        o.backend = .fragment
        o.fastMath = false
        o.stepScale = 1.0
        o.maxIter = RenderOptions.referenceMaxIter
        o.useBoundingSphere = false
        return Preset(
            id: "reference",
            name: "Reference",
            detail: "Bit-faithful port. 1024\u{00D7}1024 buffer, reference step and "
                + "iteration counts, safe math. Comparable with the web benchmark.",
            options: o,
            resolution: .square1024,
            cameraLen: 1.6,
            fixedScale: 1.0,
            autoScale: false,
            targetFPS: 60,
            rotationMode: .frameLocked
        )
    }()

    /// 1024p with the bit-exact optimisations on and resolution adapting to a
    /// 60 FPS budget.
    public static let balanced: Preset = {
        var o = RenderOptions()
        o.backend = .fragment
        o.fastMath = false
        o.stepScale = 1.0
        o.maxIter = RenderOptions.referenceMaxIter
        o.useBoundingSphere = true
        return Preset(
            id: "balanced",
            name: "Balanced",
            detail: "1024p, bit-exact optimisations, bounding-sphere early-out, "
                + "resolution adapting to 60 FPS.",
            options: o,
            resolution: .height1024,
            cameraLen: 1.6,
            fixedScale: 1.0,
            autoScale: true,
            targetFPS: 60,
            rotationMode: .timeBased
        )
    }()

    /// Everything on: native resolution base, fast math, early-out, and the
    /// display's own refresh rate as the target.
    public static let performance: Preset = {
        var o = RenderOptions()
        o.backend = .fragment
        o.fastMath = true
        o.stepScale = 1.0
        o.maxIter = RenderOptions.referenceMaxIter
        o.useBoundingSphere = true
        return Preset(
            id: "performance",
            name: "Performance",
            detail: "Native resolution base, fast math, bounding-sphere early-out, "
                + "resolution adapting to the display refresh rate. Not bit-faithful.",
            options: o,
            resolution: .native,
            cameraLen: 1.6,
            fixedScale: 1.0,
            autoScale: true,
            targetFPS: 120,
            rotationMode: .timeBased
        )
    }()

    /// Offscreen, unpresented, fixed frame count: raw GPU throughput.
    public static let rawBenchmark: Preset = {
        var o = RenderOptions()
        o.backend = .fragment
        o.fastMath = false
        o.stepScale = 1.0
        o.maxIter = RenderOptions.referenceMaxIter
        o.useBoundingSphere = false
        return Preset(
            id: "raw",
            name: "Raw GPU",
            detail: "Offscreen, never presented, fixed frame count. Reports raw "
                + "GPU throughput at the reference configuration.",
            options: o,
            resolution: .square1024,
            cameraLen: 1.6,
            fixedScale: 1.0,
            autoScale: false,
            targetFPS: 0,
            rotationMode: .timeBased,
            offscreen: true
        )
    }()

    public static let all: [Preset] = [reference, balanced, performance, rawBenchmark]

    public static func preset(id: String) -> Preset? {
        all.first { $0.id == id }
    }
}
