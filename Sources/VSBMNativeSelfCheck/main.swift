import Foundation
import Metal
import simd
import VSBMNativeCore

// =============================================================================
// vsbm-selfcheck
//
// This package cannot use XCTest or swift-testing: this machine has Command Line
// Tools only, with no Xcode.app, so `XCTest.framework` is absent and
// `TestingMacros` cannot be loaded. Correctness is therefore verified by this
// plain executable, which exits non-zero on failure.
// =============================================================================

var checksRun = 0
var checksFailed = 0
let verbose = CommandLine.arguments.contains("--verbose")

func check(_ name: String, _ passed: Bool, detail: String = "") {
    checksRun += 1
    if passed {
        print("  PASS  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
    } else {
        checksFailed += 1
        print("  FAIL  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
    }
}

func section(_ title: String) {
    print("")
    print("== \(title)")
}

func argumentValue(_ flag: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: flag),
          i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

func since(_ start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
}

let fidelitySize = Int(argumentValue("--size") ?? "64") ?? 64
let skipFidelity = CommandLine.arguments.contains("--quick")

print("vsbm-selfcheck")
print("fidelity resolution: \(fidelitySize)x\(fidelitySize)")

// -----------------------------------------------------------------------------
section("1. Memory layout")

check(
    "Uniforms stride is 96 bytes",
    MemoryLayout<Uniforms>.stride == 96,
    detail: "got \(MemoryLayout<Uniforms>.stride)")
check(
    "ProbeParams stride is 16 bytes",
    MemoryLayout<ProbeParams>.stride == 16,
    detail: "got \(MemoryLayout<ProbeParams>.stride)")

// -----------------------------------------------------------------------------
section("2. Camera conformance against the JavaScript reference")

// Values computed at double precision directly from the reference expressions:
//   origin = (len*cos(a1)*cos(a2)+cenx, len*sin(a2)+ceny, len*sin(a1)*cos(a2)+cenz)
//   right  = (sin(a1), 0, -cos(a1))
//   up     = (-sin(a2)*cos(a1), cos(a2), -sin(a2)*sin(a1))
//   forward= (-cos(a1)*cos(a2), -sin(a2), -sin(a1)*cos(a2))
struct CameraVectorReference {
    let ang1: Double
    let ang2: Double
    let len: Double
    let origin: SIMD3<Double>
    let right: SIMD3<Double>
    let up: SIMD3<Double>
    let forward: SIMD3<Double>
}

let cameraReference: [CameraVectorReference] = [
    CameraVectorReference(
        ang1: 2.8, ang2: 0.4, len: 1.6,
        origin: SIMD3(-1.388550793, 0.623069348, 0.493671230),
        right: SIMD3(0.334988150, 0.000000000, 0.942222341),
        up: SIMD3(0.366918662, 0.921060994, -0.130450530),
        forward: SIMD3(0.867844246, -0.389418342, -0.308544519)),
    CameraVectorReference(
        ang1: 2.81, ang2: 0.4, len: 1.6,
        origin: SIMD3(-1.393417996, 0.623069348, 0.479761270),
        right: SIMD3(0.325549335, 0.000000000, 0.945525056),
        up: SIMD3(0.368204800, 0.921060994, -0.126774882),
        forward: SIMD3(0.870886248, -0.389418342, -0.299850794)),
    CameraVectorReference(
        ang1: 2.8, ang2: 0.4, len: 2.6,
        origin: SIMD3(-2.256395039, 1.012487690, 0.802215748),
        right: SIMD3(0.334988150, 0.000000000, 0.942222341),
        up: SIMD3(0.366918662, 0.921060994, -0.130450530),
        forward: SIMD3(0.867844246, -0.389418342, -0.308544519)),
]

let cameraTolerance = 1e-6
for ref in cameraReference {
    var cam = Camera()
    cam.ang1 = ref.ang1
    cam.ang2 = ref.ang2
    cam.len = ref.len
    let v = cam.vectors()
    let deltas = [
        abs(v.origin.x - ref.origin.x), abs(v.origin.y - ref.origin.y), abs(v.origin.z - ref.origin.z),
        abs(v.right.x - ref.right.x), abs(v.right.y - ref.right.y), abs(v.right.z - ref.right.z),
        abs(v.up.x - ref.up.x), abs(v.up.y - ref.up.y), abs(v.up.z - ref.up.z),
        abs(v.forward.x - ref.forward.x), abs(v.forward.y - ref.forward.y),
        abs(v.forward.z - ref.forward.z),
    ]
    let worst = deltas.max() ?? 0
    check(
        String(format: "camera a1=%.2f a2=%.2f len=%.1f", ref.ang1, ref.ang2, ref.len),
        worst <= cameraTolerance,
        detail: String(format: "max delta %.3e", worst))
}

// Aspect-derived x/y terms must sum to 2 and match 2w/(w+h).
do {
    var cam = Camera()
    cam.len = 1.6
    let u = Uniforms.make(camera: cam, renderWidth: 1024, renderHeight: 1024, options: RenderOptions())
    check("1024x1024 aspect x == 1", abs(u.x - 1.0) < 1e-6, detail: "\(u.x)")
    check("1024x1024 aspect y == 1", abs(u.y - 1.0) < 1e-6, detail: "\(u.y)")
    let wide = Uniforms.make(camera: cam, renderWidth: 1920, renderHeight: 1080, options: RenderOptions())
    check(
        "1920x1080 aspect terms sum to 2",
        abs((wide.x + wide.y) - 2.0) < 1e-5,
        detail: String(format: "x=%.4f y=%.4f", wide.x, wide.y))
}

// -----------------------------------------------------------------------------
section("3. Shader assembly and diagnostics")

do {
    let assembled = ShaderSource.assemble(kernel: BuiltInKernels.mandelbulb8)
    check("assembled source contains the kernel markers",
          assembled.contains(ShaderSource.kernelBeginMarker)
              && assembled.contains(ShaderSource.kernelEndMarker))
    // The user kernel must land exactly at preludeLineCount + 1.
    let lines = assembled.split(separator: "\n", omittingEmptySubsequences: false)
    let kernelFirstLine = ShaderSource.preludeLineCount
    let landed = lines.indices.contains(kernelFirstLine)
        && lines[kernelFirstLine].contains("Original cznull default kernel")
    let shown = lines.indices.contains(kernelFirstLine)
        ? String(lines[kernelFirstLine].prefix(48)) : "?"
    check("kernel begins at line preludeLineCount + 1", landed,
          detail: "line \(kernelFirstLine + 1) = \(shown)")

    let fake = """
    program_source:120:9: error: use of undeclared identifier 'foo'
    program_source:5:1: error: something in the prelude
    """
    let diagnostics = ShaderSource.parseDiagnostics(fromCompilerOutput: fake)
    let kernelDiag = diagnostics.first { $0.inKernel }
    check("diagnostics map into the kernel region",
          kernelDiag?.userLine == 120 - ShaderSource.preludeLineCount,
          detail: "userLine \(kernelDiag?.userLine.map(String.init) ?? "nil")")
    check("diagnostics outside the kernel are flagged",
          diagnostics.contains { !$0.inKernel })
    check("diagnostic message is stripped of 'error:'",
          kernelDiag?.message.contains("undeclared identifier") == true,
          detail: kernelDiag?.message ?? "")
}

// -----------------------------------------------------------------------------
section("4. Metal device and kernel compilation")

guard let device = MTLCreateSystemDefaultDevice() else {
    print("  FAIL  no Metal device available")
    exit(2)
}
print("  device: \(device.name)")

var renderer: MetalRenderer?
do {
    let reference = Presets.reference
    let r = try MetalRenderer(
        kernelSource: BuiltInKernels.mandelbulb8, options: reference.options)
    renderer = r
    check("reference kernel compiles at runtime", true)
    check("assembled source is available for the editor", !r.assembledSource.isEmpty)
} catch {
    check("reference kernel compiles at runtime", false, detail: "\(error.localizedDescription)")
}

for (name, source) in BuiltInKernels.all where name != "mandelbulb8" {
    do {
        _ = try MetalRenderer(kernelSource: source, options: RenderOptions())
        check("\(name) kernel compiles", true)
    } catch {
        check("\(name) kernel compiles", false, detail: "\(error.localizedDescription)")
    }
}

// A broken kernel must fail cleanly and must not replace the working pipeline.
if let r = renderer {
    let bad = """
    static inline float sdf(float3 p) {
        return undefined_function(p;
    }
    """
    let result = r.setKernel(bad)
    check("broken kernel fails to compile", !result.succeeded)
    check("broken kernel reports a kernel-region diagnostic",
          result.diagnostics.contains { $0.inKernel },
          detail: result.diagnostics.first?.display ?? "no diagnostics")
    let stillWorks = r.setKernel(BuiltInKernels.mandelbulb8)
    check("previous pipeline survives a failed compile", stillWorks.succeeded)
}

// -----------------------------------------------------------------------------
section("5. GPU against the CPU oracle (fidelity)")

if !skipFidelity, let r = renderer {
    var camera = Camera()
    camera.len = 1.6
    camera.ang1 = 2.8
    camera.ang2 = 0.4

    let options = Presets.reference.options
    let uniforms = Uniforms.make(
        camera: camera,
        renderWidth: fidelitySize,
        renderHeight: fidelitySize,
        options: options)

    let cpuStart = DispatchTime.now()
    let cpuRGB = CPUReference.render(
        uniforms: uniforms,
        width: fidelitySize,
        height: fidelitySize,
        sdf: CPUReference.mandelbulb8Function)
    let cpuMs = since(cpuStart)

    do {
        let gpuStart = DispatchTime.now()
        let gpuRGB = try r.renderToRGB(
            uniforms: uniforms, width: fidelitySize, height: fidelitySize)
        let gpuMs = since(gpuStart)

        let diff = MetalRenderer.difference(cpuRGB, gpuRGB)
        let pct = diff.fractionBeyond1Step * 100
        print(String(format: "        CPU oracle %.0f ms, GPU frame %.1f ms", cpuMs, gpuMs))
        print(String(format: "        mean |delta| %.6f  max |delta| %.6f  beyond 1/255 %.3f%%",
                     diff.meanAbsDelta, diff.maxAbsDelta, pct))

        // The oracle is a literal transcription while the GPU path removes
        // redundant evaluations, so agreement should be at rounding level. A
        // handful of silhouette pixels may still flip a branch, so the bound is
        // an image-wide mean plus near-total agreement rather than an absolute
        // per-pixel maximum.
        check("mean absolute delta <= 0.5/255", diff.meanAbsDelta <= 0.5 / 255.0,
              detail: String(format: "%.6f", diff.meanAbsDelta))
        check("at least 99.5% of pixels agree within 1/255",
              diff.fractionBeyond1Step <= 0.005,
              detail: String(format: "%.3f%% differ", pct))
        check("no catastrophic divergence", diff.maxAbsDelta <= 0.35,
              detail: String(format: "max %.4f", diff.maxAbsDelta))

        // Sanity: the frame must not be blank, or the comparison is vacuous.
        let lit = gpuRGB.filter { $0 > 0.02 }.count
        check("rendered frame is not blank",
              lit > (fidelitySize * fidelitySize * 3) / 100,
              detail: "\(lit) of \(gpuRGB.count) channels non-black")
    } catch {
        check("GPU offscreen render", false, detail: "\(error.localizedDescription)")
    }
} else if skipFidelity {
    print("  SKIP  fidelity checks (--quick)")
}

// -----------------------------------------------------------------------------
section("6. Bounding-sphere early-out")

if let r = renderer, !skipFidelity {
    var camera = Camera()
    camera.len = 1.6
    camera.ang1 = 2.8
    camera.ang2 = 0.4

    // The march spans maxIter * step * len; the probe must cover that volume.
    let extent = Double(RenderOptions.referenceMaxIter) * 0.002 * camera.len * 1.05

    do {
        let radius = try r.probeBoundingRadius(
            extent: extent, samples: 64, delta: 0.01, margin: 2.0)
        print(String(format: "        probed bounding radius %.4f (probe extent %.4f)", radius, extent))
        check("probed radius is finite and inside the march volume",
              radius.isFinite && radius > 0 && radius < extent,
              detail: String(format: "%.4f", radius))

        let size = 96
        let base = Uniforms.make(
            camera: camera, renderWidth: size, renderHeight: size,
            options: Presets.reference.options)
        var sphereUniforms = base
        sphereUniforms.flags = Uniforms.flagBoundingSphere
        sphereUniforms.boundR = Float(radius)

        let faithful = try r.renderToRGB(uniforms: base, width: size, height: size)
        let culled = try r.renderToRGB(uniforms: sphereUniforms, width: size, height: size)
        let diff = MetalRenderer.difference(faithful, culled)
        print(String(format: "        sphere vs faithful: mean %.6f  max %.6f  beyond 1/255 %.3f%%",
                     diff.meanAbsDelta, diff.maxAbsDelta, diff.fractionBeyond1Step * 100))
        check("bounding sphere keeps the image within tolerance",
              diff.meanAbsDelta <= 2.0 / 255.0 && diff.fractionBeyond1Step <= 0.02,
              detail: String(format: "mean %.6f, %.3f%% differ",
                             diff.meanAbsDelta, diff.fractionBeyond1Step * 100))

        // Throughput must strictly improve, otherwise the optimisation is pointless.
        let t0 = try r.measureRawThroughput(
            width: 512, height: 512, warmup: 2, frames: 5,
            uniformsForFrame: { _ in base })
        let t1 = try r.measureRawThroughput(
            width: 512, height: 512, warmup: 2, frames: 5,
            uniformsForFrame: { _ in sphereUniforms })
        print(String(format: "        512x512 faithful %.1f ms -> sphere-culled %.1f ms (%.2fx)",
                     t0.medianGPUMs, t1.medianGPUMs, t0.medianGPUMs / max(t1.medianGPUMs, 0.001)))
        check("bounding sphere is faster than the full march",
              t1.medianGPUMs < t0.medianGPUMs,
              detail: String(format: "%.1f -> %.1f ms", t0.medianGPUMs, t1.medianGPUMs))
    } catch {
        check("bounding sphere probe", false, detail: "\(error.localizedDescription)")
    }
} else {
    print("  SKIP  bounding sphere checks")
}

// -----------------------------------------------------------------------------
section("6b. Compute backend and the upscale pass")

if let r = renderer, !skipFidelity {
    var camera = Camera()
    camera.len = 1.6
    camera.ang1 = 2.8
    camera.ang2 = 0.4

    // ---- compute backend must match the fragment backend ----
    do {
        var fragmentOptions = Presets.reference.options
        fragmentOptions.backend = .fragment
        var computeOptions = fragmentOptions
        computeOptions.backend = .compute

        _ = r.setOptions(fragmentOptions)
        let mobile = 72
        let uf = Uniforms.make(camera: camera, renderWidth: mobile, renderHeight: mobile,
                               options: fragmentOptions)
        let uc = Uniforms.make(camera: camera, renderWidth: mobile, renderHeight: mobile,
                               options: computeOptions)
        let fragRGB = try r.renderToRGB(uniforms: uf, width: mobile, height: mobile)
        _ = r.setOptions(computeOptions)
        let compRGB = try r.renderToRGB(uniforms: uc, width: mobile, height: mobile)
        let diff = MetalRenderer.difference(fragRGB, compRGB)
        print(String(format: "        compute vs fragment: mean %.6f  max %.6f  beyond 1/255 %.3f%%",
                     diff.meanAbsDelta, diff.maxAbsDelta, diff.fractionBeyond1Step * 100))
        check("compute backend matches the fragment backend",
              diff.meanAbsDelta <= 0.5 / 255.0 && diff.fractionBeyond1Step <= 0.01,
              detail: String(format: "mean %.6f", diff.meanAbsDelta))
        check("compute backend is not blank",
              compRGB.filter { $0 > 0.02 }.count > (mobile * mobile * 3) / 100)
        _ = r.setOptions(Presets.reference.options)
    } catch {
        check("compute backend render", false, detail: "\(error.localizedDescription)")
    }

    // ---- upscale pass: correct orientation and a sane image ----
    do {
        let out = 128
        let small = 64
        let uniforms = Uniforms.make(
            camera: camera, renderWidth: out, renderHeight: out,
            options: Presets.reference.options)
        let direct = try r.renderToRGB(uniforms: uniforms, width: out, height: out)
        let upscaled = try r.renderToRGB(
            uniforms: uniforms, width: out, height: out,
            upscaleFrom: (width: small, height: small))

        check("upscale pass produces a non-blank image",
              upscaled.filter { $0 > 0.02 }.count > (out * out * 3) / 100)

        // If the vertical flip were wrong, the flipped comparison would win.
        var flipped = [Float](repeating: 0, count: upscaled.count)
        for y in 0..<out {
            for x in 0..<out {
                let src = ((out - 1 - y) * out + x) * 3
                let dst = (y * out + x) * 3
                flipped[dst] = upscaled[src]
                flipped[dst + 1] = upscaled[src + 1]
                flipped[dst + 2] = upscaled[src + 2]
            }
        }
        let upright = MetalRenderer.difference(direct, upscaled)
        let reversed = MetalRenderer.difference(direct, flipped)
        print(String(format: "        upscale orientation: mean %.5f upright vs %.5f flipped",
                     upright.meanAbsDelta, reversed.meanAbsDelta))
        check("upscale pass is not vertically flipped",
              upright.meanAbsDelta < reversed.meanAbsDelta * 0.6,
              detail: String(format: "%.5f vs %.5f", upright.meanAbsDelta, reversed.meanAbsDelta))
    } catch {
        check("upscale pass", false, detail: "\(error.localizedDescription)")
    }
} else {
    print("  SKIP  compute and upscale checks")
}

// -----------------------------------------------------------------------------
section("7. Adaptive resolution controller")

do {
    // Cost model measured on this M4 with the corrected uniform bindings:
    // 1024x1024 takes 138.6 ms with the reference kernel and safe math, and cost
    // tracks pixel count closely (512x512 measures 47.5 ms).
    let referencePixels = 1024.0 * 1024.0
    let referenceMs = 138.6
    let msPerPixel = referenceMs / referencePixels

    for target in [30.0, 60.0] {
        let controller = AutoResolution()
        controller.targetFPS = target
        controller.reset(to: 1.0)

        // Model the real feedback path: the controller never sees an
        // instantaneous measurement, only the median of the last
        // `measurementWindow` frames, most of which predate its last change.
        // Feeding it the instantaneous cost instead would hide oscillation
        // entirely, which is exactly what an earlier version of this test did.
        var scale = 1.0
        var window: [Double] = []
        var history: [Double] = []
        for _ in 0..<400 {
            let cost = referencePixels * scale * scale * msPerPixel
            window.append(cost)
            if window.count > AutoResolution.measurementWindow { window.removeFirst() }
            let sorted = window.sorted()
            let observed = sorted[sorted.count / 2]
            scale = controller.update(medianGPUMs: observed)
            history.append(1000.0 / cost)
        }
        let finalFPS = 1000.0 / (referencePixels * scale * scale * msPerPixel)
        let lastQuarter = Array(history.suffix(100))
        let lo = lastQuarter.min() ?? 0
        let hi = lastQuarter.max() ?? 0
        print(String(format: "        target %.0f -> scale %.3f, final %.1f FPS, "
                     + "last-100 spread %.1f..%.1f, %d changes",
                     target, scale, finalFPS, lo, hi, controller.changes))
        check(String(format: "target %.0f FPS converges within 10%%", target),
              abs(finalFPS - target) / target <= 0.10,
              detail: String(format: "%.1f FPS", finalFPS))
        check(String(format: "target %.0f FPS settles without oscillation", target),
              (hi - lo) <= target * 0.10,
              detail: String(format: "spread %.1f", hi - lo))
    }

    let controller = AutoResolution()
    controller.targetFPS = 60
    controller.reset(to: 1.0)
    controller.setThermalCap(0.4)
    check("thermal cap lowers the maximum scale", controller.maxScale == 0.4,
          detail: "\(controller.maxScale)")

    controller.reset(to: 1.0)
    controller.enabled = false
    let fresh = AutoResolution()
    fresh.targetFPS = 60
    fresh.reset(to: 1.0)
    fresh.enabled = false
    let held = fresh.update(medianGPUMs: 500)
    check("disabled controller holds its scale", held == 1.0, detail: "\(held)")
}

// -----------------------------------------------------------------------------
section("8. Frame statistics")

do {
    let stats = FrameStats()
    for i in 0..<200 {
        stats.record(gpuMs: Double(10 + (i % 5)), encodeMs: 0.2)
    }
    stats.recordSkippedFrame()
    let snap = stats.snapshot()
    check("frame count is tracked", snap.totalFrames == 200, detail: "\(snap.totalFrames)")
    check("skipped frames are tracked", snap.skippedFrames == 1)
    check("median GPU time is in range",
          snap.medianGPUMs >= 10 && snap.medianGPUMs <= 14,
          detail: String(format: "%.1f", snap.medianGPUMs))
    check("1% low is reported", snap.onePercentLowFPS >= 0,
          detail: String(format: "%.1f", snap.onePercentLowFPS))
    let csv = stats.exportFrameIntervalsCSV()
    check("CSV export has a header and rows",
          csv.hasPrefix("frame,interval_ms,gpu_ms") && csv.split(separator: "\n").count > 100)
    let json = stats.exportReportJSON(snap)
    check("JSON report is parseable",
          (try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil)
    stats.reset()
    check("reset clears counters", stats.snapshot().totalFrames == 0)
}

// -----------------------------------------------------------------------------
section("9. Presets and sizing")

do {
    check("Reference preset is bit-faithful", Presets.reference.options.isBitFaithful)
    check("Reference preset uses the 1024x1024 buffer",
          Presets.reference.resolution == .square1024)
    check("Reference preset is frame-locked like the original page",
          Presets.reference.rotationMode == .frameLocked)
    check("Balanced preset is not bit-faithful",
          !Presets.balanced.options.isBitFaithful
              && !Presets.balanced.options.fidelityDeviations.isEmpty)
    check("Performance preset enables fast math and the early-out",
          Presets.performance.options.fastMath && Presets.performance.options.useBoundingSphere)
    check("Raw GPU preset is offscreen and not FPS-bound",
          Presets.rawBenchmark.offscreen && Presets.rawBenchmark.targetFPS == 0)
    check("every preset has a unique id",
          Set(Presets.all.map(\.id)).count == Presets.all.count)

    let sizing = RenderSizing.renderSize(
        pointSize: CGSize(width: 1280, height: 800), backingScale: 2,
        resolution: .height1024, scale: 0.5)
    check("height1024 base keeps the aspect",
          sizing.height == 512 && sizing.width == 819,
          detail: "\(sizing.width)x\(sizing.height)")
    let native = RenderSizing.renderSize(
        pointSize: CGSize(width: 1280, height: 800), backingScale: 2,
        resolution: .native, scale: 1.0)
    check("native resolution uses backing pixels",
          native.width == 2560 && native.height == 1600,
          detail: "\(native.width)x\(native.height)")
}

// -----------------------------------------------------------------------------
// Reproducible performance matrix. Informational: timings are hardware
// dependent, so they are printed rather than asserted. Recorded output lives in
// docs/performance.md.
if CommandLine.arguments.contains("--bench") {
    section("10. Performance matrix (raw GPU, offscreen, unpresented)")

    func measure(
        label: String,
        kernel: String,
        options: RenderOptions,
        width: Int,
        height: Int,
        frames: Int = 9
    ) {
        do {
            let r = try MetalRenderer(kernelSource: kernel, options: options)
            var camera = Camera()
            camera.len = 1.6
            camera.ang1 = 2.8
            camera.ang2 = 0.4
            let result = try r.measureRawThroughput(
                width: width, height: height, warmup: 3, frames: frames,
                uniformsForFrame: { i in
                    var c = camera
                    c.ang1 += Double(i) * 0.01
                    return Uniforms.make(
                        camera: c, renderWidth: width, renderHeight: height, options: options)
                })
            print(String(format: "  %-34@ %4dx%-5d %8.2f ms %7.1f FPS  min %.2f max %.2f",
                         label as NSString, width, height,
                         result.medianGPUMs, result.fps,
                         result.minGPUMs, result.maxGPUMs))
        } catch {
            print("  \(label): FAILED - \(error.localizedDescription)")
        }
    }

    var safe = Presets.reference.options
    var fast = safe
    fast.fastMath = true
    var sphere = safe
    sphere.useBoundingSphere = true
    sphere.boundingRadius = 1.2859
    var sphereFast = sphere
    sphereFast.fastMath = true
    var compute = safe
    compute.backend = .compute

    let mb = BuiltInKernels.mandelbulb8
    measure(label: "fragment safe (reference)", kernel: mb, options: safe, width: 1024, height: 1024)
    measure(label: "fragment fast", kernel: mb, options: fast, width: 1024, height: 1024)
    measure(label: "fragment safe + sphere", kernel: mb, options: sphere, width: 1024, height: 1024)
    measure(label: "fragment fast + sphere", kernel: mb, options: sphereFast, width: 1024, height: 1024)
    measure(label: "compute  safe", kernel: mb, options: compute, width: 1024, height: 1024)
    print("")
    measure(label: "fragment safe (reference)", kernel: mb, options: safe, width: 512, height: 512)
    measure(label: "fragment safe + sphere", kernel: mb, options: sphere, width: 512, height: 512)
    measure(label: "fragment fast + sphere", kernel: mb, options: sphereFast, width: 512, height: 512)
    measure(label: "compute  safe", kernel: mb, options: compute, width: 512, height: 512)
    print("")
    measure(label: "box kernel (reference settings)", kernel: BuiltInKernels.box,
            options: safe, width: 1024, height: 1024)
    measure(label: "sphere kernel (reference settings)", kernel: BuiltInKernels.sphere,
            options: safe, width: 1024, height: 1024)
    measure(label: "menger kernel (reference settings)", kernel: BuiltInKernels.menger,
            options: safe, width: 1024, height: 1024)
}

// -----------------------------------------------------------------------------
print("")
print("=========================================")
print("checks run: \(checksRun)   failed: \(checksFailed)")
print("=========================================")
_ = verbose
exit(checksFailed == 0 ? 0 : 1)
