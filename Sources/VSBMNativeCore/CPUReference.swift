import Foundation
import Metal
import simd

/// A signed-field function usable by the CPU oracle.
public typealias SDFFunction = (SIMD3<Float>) -> Float

/// Scalar execution of the reference algorithm, used as the correctness oracle.
///
/// This is a **literal** transcription of the original GLSL `main()`, including
/// the redundant SDF evaluations that the GPU path removes. That asymmetry is
/// deliberate: comparing the GPU output against this oracle therefore validates
/// the port *and* the bit-exact rewrites at the same time.
///
/// It intentionally does not implement the bounding-sphere early-out — that
/// optimisation is validated separately by comparing GPU-against-GPU.
public enum CPUReference {

    /// Exact port of the reference Marcher.
    public static func march(
        origin: SIMD3<Float>,
        dir: SIMD3<Float>,
        localdir: SIMD3<Float>,
        right: SIMD3<Float>,
        up: SIMD3<Float>,
        forward: SIMD3<Float>,
        len: Float,
        sdf: SDFFunction
    ) -> SIMD3<Float> {
        let step: Float = 0.002
        var color = SIMD3<Float>(repeating: 0)
        var sign: Int32 = 0

        var v: Float = 0, v1: Float = 0, v2: Float = 0
        var r1: Float = 0, r2: Float = 0, r3: Float = 0, r4: Float = 0
        // The reference also carries an `m1` accumulator that is written and
        // never read; it is omitted here because it cannot influence a result.
        var m2: Float = 0, m3: Float = 0

        v1 = sdf(origin + dir * (step * len))
        v2 = sdf(origin)

        var k = 2
        while k < 1002 {
            let ver = origin + dir * (step * len * Float(k))
            v = sdf(ver)

            if v > 0 && v1 < 0 {
                r1 = step * len * Float(k - 1)
                r2 = step * len * Float(k)
                m2 = sdf(origin + dir * r2)
                for _ in 0..<8 {
                    r3 = r1 * 0.5 + r2 * 0.5
                    m3 = sdf(origin + dir * r3)
                    if m3 > 0 {
                        r2 = r3
                        m2 = m3
                    } else {
                        r1 = r3
                    }
                }
                if r3 < 2.0 * len {
                    sign = 1
                    break
                }
            }

            let m_l: Float = 0.3819660113
            let m_r: Float = 0.6180339887

            if v < v1 && v1 > v2 && v1 < 0 && (v1 * 2.0 > v || v1 * 2.0 > v2) {
                r1 = step * len * Float(k - 2)
                r2 = step * len * (Float(k) - 2.0 + 2.0 * m_l)
                r3 = step * len * (Float(k) - 2.0 + 2.0 * m_r)
                r4 = step * len * Float(k)
                m2 = sdf(origin + dir * r2)
                m3 = sdf(origin + dir * r3)
                for _ in 0..<8 {
                    if m2 > m3 {
                        r4 = r3
                        r3 = r2
                        r2 = r4 * m_l + r1 * m_r
                        m3 = m2
                        m2 = sdf(origin + dir * r2)
                    } else {
                        r1 = r2
                        r2 = r3
                        r3 = r4 * m_r + r1 * m_l
                        m2 = m3
                        m3 = sdf(origin + dir * r3)
                    }
                }
                if m2 > 0 {
                    r1 = step * len * Float(k - 2)
                    m2 = sdf(origin + dir * r2)
                    for _ in 0..<8 {
                        r3 = r1 * 0.5 + r2 * 0.5
                        m3 = sdf(origin + dir * r3)
                        if m3 > 0 {
                            r2 = r3
                            m2 = m3
                        } else {
                            r1 = r3
                        }
                    }
                    if r3 < 2.0 * len && r3 > step * len {
                        sign = 1
                        break
                    }
                } else if m3 > 0 {
                    r1 = step * len * Float(k - 2)
                    r2 = r3
                    m2 = sdf(origin + dir * r2)
                    for _ in 0..<8 {
                        r3 = r1 * 0.5 + r2 * 0.5
                        m3 = sdf(origin + dir * r3)
                        if m3 > 0 {
                            r2 = r3
                            m2 = m3
                        } else {
                            r1 = r3
                        }
                    }
                    if r3 < 2.0 * len && r3 > step * len {
                        sign = 1
                        break
                    }
                }
            }

            v2 = v1
            v1 = v
            k += 1
        }

        if sign == 1 {
            var ver = origin + dir * r3
            r1 = ver.x * ver.x + ver.y * ver.y + ver.z * ver.z
            let eps = r3 * 0.00025
            var n = SIMD3<Float>(0, 0, 0)
            n.x = sdf(ver - right * eps) - sdf(ver + right * eps)
            n.y = sdf(ver - up * eps) - sdf(ver + up * eps)
            n.z = sdf(ver + forward * eps) - sdf(ver - forward * eps)
            n = n * (1.0 / (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot())

            ver = localdir
            let ln = (ver.x * ver.x + ver.y * ver.y + ver.z * ver.z).squareRoot()
            ver = ver * (1.0 / ln)
            let reflect = n * (-2.0 * (ver.x * n.x + ver.y * n.y + ver.z * n.z)) + ver

            r3 = reflect.x * 0.276 + reflect.y * 0.920 + reflect.z * 0.276
            r4 = n.x * 0.276 + n.y * 0.920 + n.z * 0.276
            r3 = max(0.0, r3)
            r3 = r3 * r3 * r3 * r3
            r3 = r3 * 0.45 + r4 * 0.25 + 0.3

            n.x = sin(r1 * 10.0) * 0.5 + 0.5
            n.y = sin(r1 * 10.0 + 2.05) * 0.5 + 0.5
            n.z = sin(r1 * 10.0 - 2.05) * 0.5 + 0.5
            color = n * r3
        }
        return color
    }

    /// Renders a full frame on the CPU. `RGB`, row-major, top-left origin.
    public static func render(
        uniforms u: Uniforms,
        width: Int,
        height: Int,
        sdf: SDFFunction
    ) -> [Float] {
        var out = [Float](repeating: 0, count: width * height * 3)
        let w = Float(width), h = Float(height)
        for y in 0..<height {
            for x in 0..<width {
                // Fragment shader interpolation reaches the pixel centre.
                let px = (Float(x) + 0.5) / w * 2.0 - 1.0
                let py = 1.0 - (Float(y) + 0.5) / h * 2.0
                let dir = u.forward + u.right * (px * u.x) + u.up * (py * u.y)
                let localdir = SIMD3<Float>(px * u.x, py * u.y, -1.0)
                let c = march(
                    origin: u.origin,
                    dir: dir,
                    localdir: localdir,
                    right: u.right,
                    up: u.up,
                    forward: u.forward,
                    len: u.len,
                    sdf: sdf
                )
                let i = (y * width + x) * 3
                out[i] = c.x
                out[i + 1] = c.y
                out[i + 2] = c.z
            }
        }
        return out
    }

    // MARK: CPU kernel ports

    /// Swift port of the original Mandelbulb-8 kernel. `acos` is clamped, which
    /// only affects inputs the GLSL specification leaves undefined anyway.
    public static func mandelbulb8(_ ver: SIMD3<Float>) -> Float {
        var a = ver
        var b: Float = 0, c: Float = 0, d: Float = 0
        for _ in 0..<5 {
            b = simd_length(a)
            c = atan2(a.y, a.x) * 8.0
            d = acos(min(max(a.z / b, -1.0), 1.0)) * 8.0
            b = powf(b, 8.0)
            a = SIMD3<Float>(b * sin(d) * cos(c), b * sin(d) * sin(c), b * cos(d)) + ver
            if b > 6.0 { break }
        }
        return 4.0 - simd_dot(a, a)
    }

    public static let mandelbulb8Function: SDFFunction = { mandelbulb8($0) }
}
