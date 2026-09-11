import Foundation
import simd

/// The four camera vectors fed to the shader, in the same basis the reference
/// JavaScript renderer builds them.
///
/// Computed in `Double` (matching JS `Number`) and narrowed to `Float` only at
/// the uniform boundary.
public struct CameraVectors: Equatable, Sendable {
    public var origin: SIMD3<Double>
    public var right: SIMD3<Double>
    public var up: SIMD3<Double>
    public var forward: SIMD3<Double>

    public init(origin: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>, forward: SIMD3<Double>) {
        self.origin = origin
        self.right = right
        self.up = up
        self.forward = forward
    }
}

/// Orbiting camera, an exact port of the reference renderer's camera state and
/// update rules.
///
/// Reference sources:
///   - `Hotment/volumeshader-simulator/js/Raymarcher.js`
///   - `livcm/volumeshader-bm/vsbm.js`
public struct Camera: Equatable, Sendable {
    /// Distance from the centre of the scene. The original page uses 1.6, the
    /// `Raymarcher.js` fork uses 2.6 — both are exposed as presets.
    public var len: Double = 1.6
    /// Azimuth, radians.
    public var ang1: Double = 2.8
    /// Elevation, radians.
    public var ang2: Double = 0.4
    public var cenx: Double = 0.0
    public var ceny: Double = 0.0
    public var cenz: Double = 0.0

    public init() {}

    // MARK: Reference constants

    /// `ang1 += rotationSpeed / 5000` in the JS fork, `ang1 += 0.01` in the original.
    public static let rotationSpeedPerFrame: Double = 0.01
    /// Pixels -> radians for drag-to-rotate.
    public static let rotateSensitivity: Double = 0.002
    /// `len *= exp(0.001 * deltaY)` for wheel zoom.
    public static let zoomSensitivity: Double = 0.001
    public static let minLen: Double = 0.05
    public static let maxLen: Double = 50.0

    /// How the per-frame azimuth increment is applied.
    public enum RotationMode: String, CaseIterable, Sendable {
        /// Faithful to the reference: one increment per rendered frame. A faster
        /// GPU therefore spins the scene faster — this is intrinsic to the
        /// original benchmark and must be kept for comparable scores.
        case frameLocked
        /// One increment per 1/60 s of wall clock, so the scene spins at a
        /// constant rate regardless of frame rate.
        case timeBased

        public static let referencePeriod: Double = 1.0 / 60.0
    }

    public mutating func advance(rotationMode: RotationMode, elapsed: Double, speed: Double) {
        switch rotationMode {
        case .frameLocked:
            ang1 += Camera.rotationSpeedPerFrame * speed
        case .timeBased:
            ang1 += Camera.rotationSpeedPerFrame * speed * (elapsed / RotationMode.referencePeriod)
        }
    }

    // MARK: Vector construction

    /// Direct transcription of the JS `draw()` camera block.
    public func vectors() -> CameraVectors {
        let c1 = cos(ang1), s1 = sin(ang1)
        let c2 = cos(ang2), s2 = sin(ang2)
        return CameraVectors(
            origin: SIMD3<Double>(
                len * c1 * c2 + cenx,
                len * s2 + ceny,
                len * s1 * c2 + cenz
            ),
            right: SIMD3<Double>(s1, 0.0, -c1),
            up: SIMD3<Double>(-s2 * c1, c2, -s2 * s1),
            forward: SIMD3<Double>(-c1 * c2, -s2, -s1 * c2)
        )
    }

    // MARK: Interaction

    /// Drag to orbit. `dx`/`dy` are point-space deltas.
    public mutating func rotate(dx: Double, dy: Double) {
        ang1 += dx * Camera.rotateSensitivity
        ang2 += dy * Camera.rotateSensitivity
    }

    /// Drag with the right button to pan. `w`/`h` are the point-space view size,
    /// exactly as the reference derives them from `clientWidth`/`clientHeight`.
    public mutating func pan(dx: Double, dy: Double, viewWidth w: Double, viewHeight h: Double) {
        guard w + h > 0 else { return }
        let l = len * 4.0 / (w + h)
        cenx += l * (-dx * sin(ang1) - dy * sin(ang2) * cos(ang1))
        ceny += l * (dy * cos(ang2))
        cenz += l * (dx * cos(ang1) - dy * sin(ang2) * sin(ang1))
    }

    /// Wheel zoom. `deltaY` follows the DOM convention (positive scrolls down).
    public mutating func zoom(deltaY: Double) {
        len *= exp(Camera.zoomSensitivity * deltaY)
        len = min(max(len, Camera.minLen), Camera.maxLen)
    }

    /// Magnify by a raw factor, clamped.
    public mutating func scaleLen(by factor: Double) {
        len *= factor
        len = min(max(len, Camera.minLen), Camera.maxLen)
    }
}

/// The uniform block handed to the vertex and fragment shaders.
///
/// Layout must stay in lockstep with `struct Uniforms` in `ShaderSource.swift`:
///
///     float3 right; float3 up; float3 forward; float3 origin;   // 0..63
///     float  x; float y; float len; float stepScale;            // 64..79
///     int    maxIter; int flags; float boundR; float pad2;      // 80..95
///
/// `SIMD3<Float>` has stride 16 / alignment 16 in Swift, matching MSL `float3`
/// inside a `constant` buffer, so the block is 96 bytes on both sides.
public struct Uniforms: Equatable, Sendable {
    public var right = SIMD3<Float>(0, 0, 0)
    public var up = SIMD3<Float>(0, 0, 0)
    public var forward = SIMD3<Float>(0, 0, 0)
    public var origin = SIMD3<Float>(0, 0, 0)
    public var x: Float = 0
    public var y: Float = 0
    public var len: Float = 0
    /// Multiplies the reference march step. 1.0 is the faithful value.
    public var stepScale: Float = 1
    /// Last value of the march counter `k`. The reference loops `k < 1002`,
    /// i.e. `k` runs 2...1001.
    public var maxIter: Int32 = 1001
    /// Bit 0: enable the bounding-sphere early-out.
    public var flags: Int32 = 0
    /// Radius of the bounding sphere used by the early-out.
    public var boundR: Float = 0
    public var pad2: Float = 0

    public static let flagBoundingSphere: Int32 = 1

    public static let referenceMaxIter: Int32 = 1001
    public static let referenceStep: Float = 0.002

    public init() {}

    /// Builds the uniform block from a camera and the render target's aspect.
    ///
    /// `x`/`y` are `2w/(w+h)` and `2h/(w+h)` — aspect terms, **not** pixel
    /// coordinates. The reference derives them from the CSS client size; using
    /// the render-target size is equivalent because the fork sizes the buffer
    /// from the same aspect ratio.
    public static func make(
        camera: Camera,
        renderWidth: Int,
        renderHeight: Int,
        options: RenderOptions
    ) -> Uniforms {
        var u = Uniforms()
        let v = camera.vectors()
        u.right = SIMD3<Float>(Float(v.right.x), Float(v.right.y), Float(v.right.z))
        u.up = SIMD3<Float>(Float(v.up.x), Float(v.up.y), Float(v.up.z))
        u.forward = SIMD3<Float>(Float(v.forward.x), Float(v.forward.y), Float(v.forward.z))
        u.origin = SIMD3<Float>(Float(v.origin.x), Float(v.origin.y), Float(v.origin.z))

        let w = Double(renderWidth), h = Double(renderHeight)
        u.x = Float(w * 2.0 / (w + h))
        u.y = Float(h * 2.0 / (w + h))
        u.len = Float(camera.len)

        u.stepScale = Float(options.stepScale)
        u.maxIter = options.maxIter
        // A zero or negative radius collapses the early-out sphere to a point and
        // would reject every ray, so the flag is dropped rather than trusted.
        // This is the single funnel every encode path goes through.
        let sphereUsable = options.useBoundingSphere && options.boundingRadius > 0
        u.flags = sphereUsable ? Uniforms.flagBoundingSphere : 0
        u.boundR = sphereUsable ? Float(options.boundingRadius) : 0
        return u
    }
}
