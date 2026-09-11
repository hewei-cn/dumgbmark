import Foundation

/// Everything that changes what the marcher computes, besides the camera.
///
/// Every field is exposed in the UI so there are no hidden defaults; the values
/// used by the *Reference* preset are exactly the ones in the original
/// JavaScript renderer.
public struct RenderOptions: Equatable, Sendable {

    /// Which Metal stage runs the marcher.
    ///
    /// Measured on an Apple M4 (8-core GPU), 1024x1024, original Mandelbulb-8
    /// kernel, offscreen:
    ///
    ///     fragment, mathMode .safe   95.3 ms   <- default
    ///     compute,  mathMode .safe  151.0 ms
    ///     fragment, mathMode .fast   78.7 ms
    ///     compute,  mathMode .fast  120.9 ms
    ///
    /// The fragment stage is 1.58x faster, so it is the default. The compute
    /// path is retained for A/B measurement on future Apple GPUs.
    public enum Backend: String, CaseIterable, Sendable {
        case fragment
        case compute
        public var label: String {
            switch self {
            case .fragment: return "Fragment"
            case .compute: return "Compute"
            }
        }
    }

    public var backend: Backend = .fragment

    /// `MTLMathMode.safe` (false) or `.fast` (true). Measured 1.21x on the M4
    /// but reassociates floating point, which can break the reference's
    /// `1e-7` epsilon and the golden-section comparison chain. Off by default.
    public var fastMath: Bool = false

    /// Multiplier on the reference march step (`0.002`). 1.0 is faithful;
    /// larger values march the same sample count over a longer distance and can
    /// tunnel through thin features.
    public var stepScale: Double = 1.0

    /// Last value of the march counter `k`. Reference: `k < 1002` => 1001.
    public var maxIter: Int32 = 1001

    /// Skip march samples that lie outside a sphere known to contain the whole
    /// shape. Not bit-exact — see `docs/algorithm.md` — so it is reported
    /// against the faithful path with a pixel-difference metric.
    public var useBoundingSphere: Bool = false

    /// Radius of that sphere. Produced by `MetalRenderer.probeBoundingRadius`.
    public var boundingRadius: Double = 0

    /// A probe sample counts towards the bound when `sdf(p) > -delta`.
    /// Larger values grow the sphere (safer, slower).
    public var boundingDelta: Double = 0.01

    /// Extra safety margin, in probe lattice spacings, added to the probed radius.
    public var boundingMargin: Double = 2.0

    /// March step used by the reference shader, in scene units.
    public static let referenceStep: Double = 0.002
    /// Last march index used by the reference shader.
    public static let referenceMaxIter: Int32 = 1001
    /// Bisection refinement count (`SOLVER` in the reference).
    public static let referenceSolverIterations: Int32 = 8
    /// Golden-section refinement count (`MAXR` in the reference).
    public static let referenceGoldenIterations: Int32 = 8

    public init() {}

    /// True when every setting matches the original JavaScript renderer.
    public var isBitFaithful: Bool {
        backend == .fragment
            && !fastMath
            && stepScale == 1.0
            && maxIter == RenderOptions.referenceMaxIter
            && !useBoundingSphere
    }

    /// Non-nil descriptions of every setting that deviates from the reference.
    public var fidelityDeviations: [String] {
        var out: [String] = []
        if backend != .fragment { out.append("compute backend") }
        if fastMath { out.append("fast math (reassociation)") }
        if stepScale != 1.0 { out.append(String(format: "step x%.2f", stepScale)) }
        if maxIter != RenderOptions.referenceMaxIter {
            out.append("maxIter \(maxIter) (reference \(RenderOptions.referenceMaxIter))")
        }
        if useBoundingSphere { out.append(String(format: "bounding sphere r=%.3f", boundingRadius)) }
        return out
    }
}

/// How the internal render target is sized before the render scale is applied.
public enum RenderResolution: String, CaseIterable, Sendable {
    /// The original page: a fixed 1024x1024 buffer stretched over the window.
    case square1024
    /// The `Raymarcher.js` fork: height 1024, width derived from the aspect.
    case height1024
    /// Match the display's backing pixels (Retina 2x included).
    case native

    public var label: String {
        switch self {
        case .square1024: return "1024\u{00D7}1024 (reference)"
        case .height1024: return "1024p"
        case .native: return "Native"
        }
    }

    /// Base size in pixels before `renderScale` is applied.
    public func baseSize(pointSize: CGSize, backingScale: CGFloat) -> (width: Int, height: Int) {
        let w = max(Double(pointSize.width), 1)
        let h = max(Double(pointSize.height), 1)
        let aspect = w / h
        switch self {
        case .square1024:
            return (1024, 1024)
        case .height1024:
            return (Int((1024.0 * aspect).rounded()), 1024)
        case .native:
            let s = Double(max(backingScale, 1))
            return (Int((w * s).rounded()), Int((h * s).rounded()))
        }
    }
}
