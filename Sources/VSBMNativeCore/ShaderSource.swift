import Foundation

/// Runtime-assembled Metal Shading Language source.
///
/// This machine has no `metal` compiler (Command Line Tools only, no Xcode.app),
/// so shaders are compiled from source at runtime with
/// `MTLDevice.makeLibrary(source:options:)`. That also makes kernel hot-reload
/// possible: swapping the kernel body costs one compile, measured at ~35 ms on
/// an M4.
///
/// The assembled file is:
///
///     <head>            includes, constants, Uniforms, markers
///     <user kernel>     a function `static inline float sdf(float3 p)`
///     <tail>            vertex/fragment/compute/upscale/probe entry points
///
/// Because the user's kernel occupies known lines, a compile error reported at
/// `program_source:L:C` can be mapped back to a line in the user's own text.
public enum ShaderSource {

    public static let kernelBeginMarker = "// ==== KERNEL BEGIN ===="
    public static let kernelEndMarker = "// ==== KERNEL END ===="

    /// The kernel function name. It cannot be `kernel`: that is a reserved word
    /// in MSL (it qualifies compute entry points), which is exactly why the
    /// original JavaScript benchmark's fork renamed it to `kernal`.
    public static let kernelFunctionName = "sdf"

    // MARK: - Head

    static let head: String = """
    #include <metal_stdlib>
    using namespace metal;

    // ---------------------------------------------------------------------------
    // Fixed prelude. Mirrors the reference shader's header exactly.
    // ---------------------------------------------------------------------------
    constant float M_L = 0.3819660113f;
    constant float M_R = 0.6180339887f;
    constant int   SOLVER = 8;
    constant int   MAXR = 8;

    struct Uniforms {
        float3 right;
        float3 up;
        float3 forward;
        float3 origin;
        float  x;
        float  y;
        float  len;
        float  stepScale;
        int    maxIter;
        int    flags;
        float  boundR;
        float  pad2;
    };

    struct ProbeParams {
        float extent;
        int   n;
        float delta;
        float pad0;
    };

    constant int kFlagBoundingSphere = 1;

    // ==== KERNEL BEGIN ====

    """

    // MARK: - Tail

    static let tail: String = """

    // ==== KERNEL END ====

    // ---------------------------------------------------------------------------
    // Matcher. A direct port of the reference `main()` with three bit-exact
    // rewrites (see docs/algorithm.md):
    //   * m1 in the sign-change branch is exactly the previous sample v1
    //   * m1 in both golden-section tails is exactly v2
    //   * m2 in the `m3 > 0` tail is exactly m3
    // These remove up to six SDF evaluations per ray hit and cannot change a
    // single bit of the result.
    // ---------------------------------------------------------------------------
    static inline float3 march(float3 o, float3 dir, float3 localdir, constant Uniforms& u) {
        const float step = 0.002f;
        float len = u.len;
        // stepScale is exactly 1.0 for the reference preset, and multiplying by
        // exactly 1.0 is exact, so `dstep` is bit-identical to `step * len`.
        float dstep = step * len * u.stepScale;

        float v = 0.0f, v1 = 0.0f, v2 = 0.0f;
        float r1 = 0.0f, r2 = 0.0f, r3 = 0.0f, r4 = 0.0f;
        // The reference carries an `m1` accumulator that is written and never
        // read; it is omitted because it cannot influence a result.
        float m2 = 0.0f, m3 = 0.0f;
        bool hit = false;

        int kStart = 2;
        int kEnd = u.maxIter;

        if ((u.flags & kFlagBoundingSphere) != 0) {
            // Sample positions are P(k) = o + (dir * dstep) * k, so the sphere
            // |P| = boundR gives a quadratic in k. Rays that never enter the
            // sphere cannot produce a sign change or a qualifying local
            // minimum, so the whole march is skipped.
            float3 a = dir * dstep;
            float d2 = dot(a, a);
            if (d2 > 0.0f) {
                float bh = dot(a, o);
                float c = dot(o, o) - u.boundR * u.boundR;
                float disc = bh * bh - d2 * c;
                if (disc < 0.0f) {
                    return float3(0.0f);
                }
                float sq = sqrt(disc);
                kStart = max(2, int(floor((-bh - sq) / d2)) - 1);
                kEnd = min(u.maxIter, int(ceil((-bh + sq) / d2)) + 1);
                if (kStart > kEnd) {
                    return float3(0.0f);
                }
            }
        }

        // Reference initialisation: v1 is the sample at k-1, v2 the sample at
        // k-2. At kStart == 2 that is the sample at k=1 and the camera origin.
        v1 = sdf(o + dir * (dstep * float(kStart - 1)));
        v2 = sdf(o + dir * (dstep * float(kStart - 2)));

        for (int k = kStart; k <= kEnd; k++) {
            float3 ver = o + dir * (dstep * float(k));
            v = sdf(ver);

            if (v > 0.0f && v1 < 0.0f) {
                r1 = dstep * float(k - 1);
                r2 = dstep * float(k);
                // Bit-exact: sdf(o + dir*r2) == v (the r1 sample is v1).
                m2 = v;
                for (int l = 0; l < SOLVER; l++) {
                    r3 = r1 * 0.5f + r2 * 0.5f;
                    m3 = sdf(o + dir * r3);
                    if (m3 > 0.0f) {
                        r2 = r3;
                        m2 = m3;
                    } else {
                        r1 = r3;
                    }
                }
                if (r3 < 2.0f * len) {
                    hit = true;
                    break;
                }
            }

            if (v < v1 && v1 > v2 && v1 < 0.0f && (v1 * 2.0f > v || v1 * 2.0f > v2)) {
                r1 = dstep * float(k - 2);
                r2 = dstep * (float(k) - 2.0f + 2.0f * M_L);
                r3 = dstep * (float(k) - 2.0f + 2.0f * M_R);
                r4 = dstep * float(k);
                m2 = sdf(o + dir * r2);
                m3 = sdf(o + dir * r3);
                for (int l = 0; l < MAXR; l++) {
                    if (m2 > m3) {
                        r4 = r3;
                        r3 = r2;
                        r2 = r4 * M_L + r1 * M_R;
                        m3 = m2;
                        m2 = sdf(o + dir * r2);
                    } else {
                        r1 = r2;
                        r2 = r3;
                        r3 = r4 * M_R + r1 * M_L;
                        m2 = m3;
                        m3 = sdf(o + dir * r3);
                    }
                }
                if (m2 > 0.0f) {
                    r1 = dstep * float(k - 2);
                    // r2 and m2 are untouched since the golden loop, so m2 is
                    // already sdf(o + dir*r2) and needs no recomputation.
                    for (int l = 0; l < SOLVER; l++) {
                        r3 = r1 * 0.5f + r2 * 0.5f;
                        m3 = sdf(o + dir * r3);
                        if (m3 > 0.0f) {
                            r2 = r3;
                            m2 = m3;
                        } else {
                            r1 = r3;
                        }
                    }
                    if (r3 < 2.0f * len && r3 > step * len) {
                        hit = true;
                        break;
                    }
                } else if (m3 > 0.0f) {
                    r1 = dstep * float(k - 2);
                    r2 = r3;
                    // Bit-exact: m2 is sdf(o + dir*r3), which the golden loop
                    // already produced as m3, so it needs no recomputation.
                    m2 = m3;
                    for (int l = 0; l < SOLVER; l++) {
                        r3 = r1 * 0.5f + r2 * 0.5f;
                        m3 = sdf(o + dir * r3);
                        if (m3 > 0.0f) {
                            r2 = r3;
                            m2 = m3;
                        } else {
                            r1 = r3;
                        }
                    }
                    if (r3 < 2.0f * len && r3 > step * len) {
                        hit = true;
                        break;
                    }
                }
            }

            v2 = v1;
            v1 = v;
        }

        if (!hit) {
            return float3(0.0f);
        }

        // ---------------------------------------------------------------------
        // Shading. Identical to the reference: central-difference normal, the
        // *unnormalised* object-space local direction used for the reflection,
        // and a radius-driven sine colour ramp (the "rainbow" of the mushroom).
        // ---------------------------------------------------------------------
        float3 ver = o + dir * r3;
        r1 = dot(ver, ver);

        float eps = r3 * 0.00025f;
        float3 n;
        n.x = sdf(ver - u.right * eps) - sdf(ver + u.right * eps);
        n.y = sdf(ver - u.up * eps) - sdf(ver + u.up * eps);
        n.z = sdf(ver + u.forward * eps) - sdf(ver - u.forward * eps);
        n = n * (1.0f / sqrt(dot(n, n)));

        float3 ld = localdir * (1.0f / sqrt(dot(localdir, localdir)));
        float3 refl = n * (-2.0f * dot(ld, n)) + ld;

        r3 = refl.x * 0.276f + refl.y * 0.920f + refl.z * 0.276f;
        r4 = n.x * 0.276f + n.y * 0.920f + n.z * 0.276f;
        r3 = max(0.0f, r3);
        r3 = r3 * r3 * r3 * r3;
        r3 = r3 * 0.45f + r4 * 0.25f + 0.3f;

        float3 color;
        color.x = sin(r1 * 10.0f) * 0.5f + 0.5f;
        color.y = sin(r1 * 10.0f + 2.05f) * 0.5f + 0.5f;
        color.z = sin(r1 * 10.0f - 2.05f) * 0.5f + 0.5f;
        return color * r3;
    }

    // ---------------------------------------------------------------------------
    // Entry points
    // ---------------------------------------------------------------------------
    struct VSOut {
        float4 position [[position]];
        float3 dir;
        float3 localdir;
    };

    constant float2 kQuad[6] = {
        float2(-1.0f, -1.0f), float2(1.0f, -1.0f), float2(1.0f, 1.0f),
        float2(-1.0f, -1.0f), float2(1.0f, 1.0f), float2(-1.0f, 1.0f)
    };

    vertex VSOut vs_main(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
        float2 p = kQuad[vid];
        VSOut o;
        o.position = float4(p, 0.0f, 1.0f);
        o.dir = u.forward + u.right * p.x * u.x + u.up * p.y * u.y;
        o.localdir = float3(p.x * u.x, p.y * u.y, -1.0f);
        return o;
    }

    fragment float4 fs_main(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        return float4(march(u.origin, in.dir, in.localdir, u), 1.0f);
    }

    // A/B backend; kept because the ranking may differ on other Apple GPUs.
    kernel void cs_main(texture2d<float, access::write> dst [[texture(0)]],
                        constant Uniforms& u [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
        uint w = dst.get_width();
        uint h = dst.get_height();
        if (gid.x >= w || gid.y >= h) {
            return;
        }
        // Texture row 0 is the top of the target and NDC y = +1 is also the top,
        // so y has to be flipped here. The rasteriser does that implicitly for
        // the fragment path; a compute dispatch has to do it by hand.
        float2 p = float2(
            (float(gid.x) + 0.5f) / float(w) * 2.0f - 1.0f,
            1.0f - (float(gid.y) + 0.5f) / float(h) * 2.0f);
        float3 dir = u.forward + u.right * p.x * u.x + u.up * p.y * u.y;
        float3 localdir = float3(p.x * u.x, p.y * u.y, -1.0f);
        dst.write(float4(march(u.origin, dir, localdir, u), 1.0f), gid);
    }

    struct UpOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex UpOut upscale_vs(uint vid [[vertex_id]]) {
        float2 p = kQuad[vid];
        UpOut o;
        o.position = float4(p, 0.0f, 1.0f);
        // Metal render targets and textures share a top-left origin, so NDC
        // y = +1 (top) maps to uv.y = 0.
        o.uv = float2(p.x * 0.5f + 0.5f, 0.5f - p.y * 0.5f);
        return o;
    }

    fragment float4 upscale_fs(UpOut in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               sampler smp [[sampler(0)]]) {
        return float4(src.sample(smp, in.uv).rgb, 1.0f);
    }

    // Samples the SDF on a lattice so the CPU can derive a bounding sphere.
    // Each thread writes the squared distance of a qualifying sample, or zero.
    kernel void probe_r(device uint* outSq [[buffer(0)]],
                        constant ProbeParams& pp [[buffer(1)]],
                        uint3 gid [[thread_position_in_grid]]) {
        uint n = uint(pp.n);
        if (gid.x >= n || gid.y >= n || gid.z >= n) {
            return;
        }
        float3 t = (float3(gid) + 0.5f) / float(n);
        float3 p = (t * 2.0f - 1.0f) * pp.extent;
        float v = sdf(p);
        uint idx = gid.x + gid.y * n + gid.z * n * n;
        outSq[idx] = (v > -pp.delta) ? as_type<uint>(dot(p, p)) : 0u;
    }
    """

    // MARK: - Assembly

    /// Full Metal source with `kernel` spliced in.
    public static func assemble(kernel: String) -> String {
        head + normalise(kernel) + tail
    }

    /// Number of source lines that precede the user kernel in the assembled
    /// file. A diagnostic at compiled line `L` refers to user line
    /// `L - preludeLineCount`.
    public static var preludeLineCount: Int {
        head.reduce(into: 0) { count, ch in if ch == "\n" { count += 1 } }
    }

    /// Ensures the kernel body is separated from the markers by newlines.
    private static func normalise(_ kernel: String) -> String {
        var k = kernel
        if k.hasPrefix("\n") { k.removeFirst() }
        if !k.hasSuffix("\n") { k += "\n" }
        return k
    }

    // MARK: - Diagnostics

    /// A single compiler diagnostic mapped back to the user's kernel text.
    public struct Diagnostic: Equatable, Sendable {
        /// 1-based line in the user's kernel, or nil when the message does not
        /// point into the kernel region.
        public let userLine: Int?
        /// 1-based column as reported by the compiler.
        public let column: Int?
        public let message: String
        public let inKernel: Bool

        public var display: String {
            if let l = userLine, let c = column {
                return "line \(l):\(c): \(message)"
            }
            if let l = userLine {
                return "line \(l): \(message)"
            }
            return message
        }
    }

    /// Parses `program_source:L:C: error: message` lines out of a Metal compile
    /// error and maps them onto the user's kernel.
    public static func parseDiagnostics(from error: Error) -> [Diagnostic] {
        let ns = error as NSError
        var raw: [String] = []
        if let localized = ns.userInfo["NSLocalizedDescription"] as? String {
            raw.append(localized)
        }
        for key in ["NSLocalizedFailureReason", "NSLocalizedRecoverySuggestion"] {
            if let s = ns.userInfo[key] as? String { raw.append(s) }
        }
        // MTLCompileErrors carry the full front-end output in a separate key.
        for (key, value) in ns.userInfo where key.contains("Description") || key.contains("Output") {
            if let s = value as? String, !raw.contains(s) { raw.append(s) }
        }
        let text = raw.joined(separator: "\n")
        return parseDiagnostics(fromCompilerOutput: text)
    }

    /// The `program_source:12:5: error: ...` shape, isolated for testability.
    public static func parseDiagnostics(fromCompilerOutput text: String) -> [Diagnostic] {
        let prelude = preludeLineCount
        var out: [Diagnostic] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let range = line.range(of: "program_source:") else { continue }
            let rest = line[range.upperBound...]
            let parts = rest.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count >= 2,
                  let compiled = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let column = Int(parts[1].trimmingCharacters(in: .whitespaces))
            var message = parts.count >= 4 ? String(parts[3]) : line
            if message.hasPrefix(" error:") { message.removeFirst(" error:".count) }
            if message.hasPrefix("error:") { message.removeFirst("error:".count) }
            message = message.trimmingCharacters(in: .whitespaces)

            let userLine = compiled - prelude
            let inKernel = userLine >= 1
            out.append(Diagnostic(
                userLine: inKernel ? userLine : nil,
                column: column,
                message: message,
                inKernel: inKernel
            ))
        }
        if out.isEmpty {
            out.append(Diagnostic(
                userLine: nil,
                column: nil,
                message: text.trimmingCharacters(in: .whitespacesAndNewlines),
                inKernel: false
            ))
        }
        return out
    }
}

// MARK: - Built-in kernels

/// The kernel library. `mandelbulb8` is the original: transcribed verbatim from
/// `livcm/volumeshader-bm/vsbm.js`, which is cznull's default kernel.
public enum BuiltInKernels {

    public static let mandelbulb8 = """
    // Original cznull default kernel: 8th-power Mandelbulb, 5 iterations.
    // The "poison mushroom". Positive inside (|a| < 2), negative outside.
    static inline float sdf(float3 ver) {
        float3 a;
        float b, c, d;
        a = ver;
        for (int i = 0; i < 5; i++) {
            b = length(a);
            c = atan2(a.y, a.x) * 8.0f;
            d = acos(clamp(a.z / b, -1.0f, 1.0f)) * 8.0f;
            b = pow(b, 8.0f);
            a = float3(b * sin(d) * cos(c), b * sin(d) * sin(c), b * cos(d)) + ver;
            if (b > 6.0f) {
                break;
            }
        }
        return 4.0f - dot(a, a);
    }
    """

    public static let box = """
    // Default kernel of the volumeshader-simulator fork.
    static inline float sdf(float3 p) {
        float3 d = abs(p) - float3(1.0f);
        return 0.0000001f - length(max(d, 0.0f));
    }
    """

    public static let sphere = """
    static inline float sdf(float3 p) {
        return 1.0f - length(p);
    }
    """

    public static let menger = """
    // Menger sponge, the classic "many thin features" stress case.
    static inline float sdf(float3 p) {
        float d = max(max(abs(p.x), abs(p.y)), abs(p.z)) - 1.0f;
        float s = 1.0f;
        for (int i = 0; i < 4; i++) {
            float3 a = fmod(abs(p) * s + 1.0f, 2.0f) - 1.0f;
            s *= 3.0f;
            float3 r = abs(1.0f - 3.0f * abs(a));
            float da = max(r.x, r.y);
            float db = max(r.y, r.z);
            float dc = max(r.z, r.x);
            float c = (min(da, min(db, dc)) - 1.0f) / s;
            d = max(d, c);
        }
        return -d;
    }
    """

    public static let all: [(name: String, source: String)] = [
        ("mandelbulb8", mandelbulb8),
        ("box", box),
        ("sphere", sphere),
        ("menger", menger),
    ]

    public static func source(named name: String) -> String? {
        all.first { $0.name == name }?.source
    }
}
