import Foundation
import Metal
import simd

/// Mirrors `struct ProbeParams` in the shader.
public struct ProbeParams: Equatable, Sendable {
    public var extent: Float = 0
    public var n: Int32 = 0
    public var delta: Float = 0
    public var pad0: Float = 0

    public init(extent: Float, n: Int32, delta: Float, pad0: Float) {
        self.extent = extent
        self.n = n
        self.delta = delta
        self.pad0 = pad0
    }
}

/// Outcome of a kernel (re)compilation.
public struct KernelCompileResult: Sendable {
    public var succeeded: Bool
    public var diagnostics: [ShaderSource.Diagnostic]
    public var compileMilliseconds: Double

    public static func ok(_ ms: Double) -> KernelCompileResult {
        KernelCompileResult(succeeded: true, diagnostics: [], compileMilliseconds: ms)
    }
}

/// Raw, unpresented GPU throughput.
public struct RawThroughputResult: Sendable {
    public var frames: Int
    public var width: Int
    public var height: Int
    public var medianGPUMs: Double
    public var minGPUMs: Double
    public var maxGPUMs: Double
    public var meanGPUMs: Double
    /// Frames per second implied purely by GPU execution time.
    public var fps: Double
}

/// Comparison between two rendered frames.
public struct FrameDifference: Sendable {
    public var pixels: Int
    /// Fraction of pixels whose largest channel delta exceeds 1/255.
    public var fractionBeyond1Step: Double
    public var meanAbsDelta: Double
    public var maxAbsDelta: Double
}

/// Owns the Metal device, pipelines and transient textures.
///
/// Threading: encode on one thread at a time. The renderer keeps mutable
/// pipeline and texture caches, so it is not safe for concurrent encoding.
public final class MetalRenderer {

    public enum RendererError: LocalizedError {
        case noMetalDevice
        case shaderCompilationFailed([ShaderSource.Diagnostic])
        case pipelineCreationFailed(String)
        case allocationFailed(String)
        case commandBufferFailed(String)
        case textureReadbackFailed

        public var errorDescription: String? {
            switch self {
            case .noMetalDevice:
                return "No Metal device is available on this system."
            case .shaderCompilationFailed(let d):
                return d.map(\.display).joined(separator: "\n")
            case .pipelineCreationFailed(let s):
                return s
            case .allocationFailed(let s):
                return s
            case .commandBufferFailed(let s):
                return s
            case .textureReadbackFailed:
                return "Could not read back the rendered texture."
            }
        }
    }

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let deviceName: String
    public let recommendedMaxWorkingSetSize: UInt64

    public private(set) var kernelSource: String
    public private(set) var options: RenderOptions

    /// The MSL currently compiled, kept for diagnostics and for the UI editor.
    public private(set) var assembledSource: String = ""

    private var library: MTLLibrary?
    private var computePipeline: MTLComputePipelineState?
    private var probePipeline: MTLComputePipelineState?
    private var marchPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var upscalePipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]

    private var reusableSampler: MTLSamplerState?

    // MARK: - Construction

    public init(kernelSource: String, options: RenderOptions) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RendererError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.allocationFailed("Could not create a Metal command queue.")
        }
        self.device = device
        self.commandQueue = queue
        self.deviceName = device.name
        self.recommendedMaxWorkingSetSize = device.recommendedMaxWorkingSetSize
        self.kernelSource = kernelSource
        self.options = options

        // The default in-flight limit (64) is far above the 3 we actually use.


        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw RendererError.allocationFailed("Could not create a sampler state.")
        }
        self.reusableSampler = sampler

        let result = compilePipeline()
        if !result.succeeded {
            throw RendererError.shaderCompilationFailed(result.diagnostics)
        }
    }

    public var supportsBoundingSphere: Bool { probePipeline != nil }

    // MARK: - Shader compilation

    private func compileOptions() -> MTLCompileOptions {
        let opts = MTLCompileOptions()
        if #available(macOS 26.0, *) {
            opts.mathMode = options.fastMath ? .fast : .safe
        } else {
            opts.fastMathEnabled = options.fastMath
        }
        return opts
    }

    /// Compiles the current kernel and rebuilds the pipelines.
    private func compilePipeline() -> KernelCompileResult {
        let source = ShaderSource.assemble(kernel: kernelSource)
        let start = DispatchTime.now()
        do {
            let opts = compileOptions()
            let lib = try device.makeLibrary(source: source, options: opts)
            guard let vs = lib.makeFunction(name: "vs_main"),
                  let fs = lib.makeFunction(name: "fs_main"),
                  let uv = lib.makeFunction(name: "upscale_vs"),
                  let uf = lib.makeFunction(name: "upscale_fs")
            else {
                return KernelCompileResult(
                    succeeded: false,
                    diagnostics: [ShaderSource.Diagnostic(
                        userLine: nil, column: nil,
                        message: "The shader compiled but a required entry point is missing.",
                        inKernel: false)],
                    compileMilliseconds: elapsedMS(since: start)
                )
            }

            let compute: MTLComputePipelineState?
            if let cs = lib.makeFunction(name: "cs_main") {
                compute = try device.makeComputePipelineState(function: cs)
            } else {
                compute = nil
            }

            let probe: MTLComputePipelineState?
            if let pk = lib.makeFunction(name: "probe_r") {
                probe = try device.makeComputePipelineState(function: pk)
            } else {
                probe = nil
            }

            // Validate the march pipeline against a format we will certainly use.
            _ = try makeMarchPipeline(vs: vs, fs: fs, format: .bgra8Unorm)
            _ = try makeUpscalePipeline(vs: uv, fs: uf, format: .bgra8Unorm)

            self.library = lib
            self.computePipeline = compute
            self.probePipeline = probe
            self.assembledSource = source
            return KernelCompileResult.ok(elapsedMS(since: start))
        } catch {
            return KernelCompileResult(
                succeeded: false,
                diagnostics: ShaderSource.parseDiagnostics(from: error),
                compileMilliseconds: elapsedMS(since: start)
            )
        }
    }

    private func makeMarchPipeline(
        vs: MTLFunction, fs: MTLFunction, format: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        if let cached = marchPipelines[format] { return cached }
        let d = MTLRenderPipelineDescriptor()
        d.label = "vsbm.march"
        d.vertexFunction = vs
        d.fragmentFunction = fs
        d.colorAttachments[0].pixelFormat = format
        let pso = try device.makeRenderPipelineState(descriptor: d)
        marchPipelines[format] = pso
        return pso
    }

    private func makeUpscalePipeline(
        vs: MTLFunction, fs: MTLFunction, format: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        if let cached = upscalePipelines[format] { return cached }
        let d = MTLRenderPipelineDescriptor()
        d.label = "vsbm.upscale"
        d.vertexFunction = vs
        d.fragmentFunction = fs
        d.colorAttachments[0].pixelFormat = format
        let pso = try device.makeRenderPipelineState(descriptor: d)
        upscalePipelines[format] = pso
        return pso
    }

    private func pipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let cached = marchPipelines[format] { return cached }
        guard let lib = library,
              let vs = lib.makeFunction(name: "vs_main"),
              let fs = lib.makeFunction(name: "fs_main")
        else {
            throw RendererError.pipelineCreationFailed("Shader library is not loaded.")
        }
        return try makeMarchPipeline(vs: vs, fs: fs, format: format)
    }

    private func upscalePipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let cached = upscalePipelines[format] { return cached }
        guard let lib = library,
              let vs = lib.makeFunction(name: "upscale_vs"),
              let fs = lib.makeFunction(name: "upscale_fs")
        else {
            throw RendererError.pipelineCreationFailed("Shader library is not loaded.")
        }
        return try makeUpscalePipeline(vs: vs, fs: fs, format: format)
    }

    /// Replaces the kernel body. On failure the previously working pipeline is
    /// kept, so a typo in the editor never blanks the screen.
    @discardableResult
    public func setKernel(_ source: String) -> KernelCompileResult {
        let previousSource = kernelSource
        let previousLibrary = library
        let previousMarch = marchPipelines
        let previousUpscale = upscalePipelines
        let previousCompute = computePipeline
        let previousProbe = probePipeline
        let previousAssembled = assembledSource

        kernelSource = source
        let result = compilePipeline()
        if !result.succeeded {
            kernelSource = previousSource
            library = previousLibrary
            marchPipelines = previousMarch
            upscalePipelines = previousUpscale
            computePipeline = previousCompute
            probePipeline = previousProbe
            assembledSource = previousAssembled
        }
        return result
    }

    /// Applies new options. Only a change of `fastMath` requires a recompile;
    /// everything else is a uniform, so it takes effect on the next frame.
    @discardableResult
    public func setOptions(_ newOptions: RenderOptions) -> KernelCompileResult? {
        let needsRecompile = newOptions.fastMath != options.fastMath
        options = newOptions
        guard needsRecompile else { return nil }
        let result = compilePipeline()
        return result
    }

    // MARK: - Textures

    public func makeIntermediateTexture(width: Int, height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: max(width, 1), height: max(height, 1), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let tex = device.makeTexture(descriptor: d) else {
            throw RendererError.allocationFailed("Could not allocate a \(width)x\(height) render target.")
        }
        tex.label = "vsbm.intermediate"
        return tex
    }

    // MARK: - Encoding

    /// Encodes one frame.
    ///
    /// - When `intermediate` is nil the marcher writes straight into
    ///   `destination`.
    /// - Otherwise it writes into `intermediate` and a full-screen linear quad
    ///   upscales into `destination`.
    ///
    /// Both passes use `loadAction = .dontCare`: the marcher writes every pixel
    /// unconditionally, so a clear would be pure bandwidth waste.
    public func encode(
        into commandBuffer: MTLCommandBuffer,
        destination: MTLTexture,
        uniforms: Uniforms,
        intermediate: MTLTexture?
    ) throws {
        var u = uniforms
        let target = intermediate ?? destination
        try encodeMarch(into: commandBuffer, target: target, uniforms: &u)

        guard let intermediate else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RendererError.commandBufferFailed("Could not create the upscale encoder.")
        }
        encoder.label = "vsbm.upscale"
        encoder.setRenderPipelineState(try upscalePipeline(for: destination.pixelFormat))
        encoder.setFragmentTexture(intermediate, index: 0)
        if let sampler = reusableSampler {
            encoder.setFragmentSamplerState(sampler, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    private func encodeMarch(
        into commandBuffer: MTLCommandBuffer, target: MTLTexture, uniforms: inout Uniforms
    ) throws {
        switch options.backend {
        case .fragment:
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw RendererError.commandBufferFailed("Could not create the march encoder.")
            }
            encoder.label = "vsbm.march"
            encoder.setRenderPipelineState(try pipeline(for: target.pixelFormat))
            // The vertex stage builds the ray direction from the same uniform
            // block the fragment stage marches with, so both bindings are needed.
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()

        case .compute:
            guard let pso = computePipeline else {
                throw RendererError.pipelineCreationFailed("Compute pipeline is unavailable.")
            }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw RendererError.commandBufferFailed("Could not create the compute encoder.")
            }
            encoder.label = "vsbm.march.compute"
            encoder.setComputePipelineState(pso)
            encoder.setTexture(target, index: 0)
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            let threads = MTLSize(width: 16, height: 16, depth: 1)
            let grid = MTLSize(width: target.width, height: target.height, depth: 1)
            encoder.dispatchThreads(grid, threadsPerThreadgroup: threads)
            encoder.endEncoding()
        }
    }

    // MARK: - Offscreen rendering and readback

    /// Renders one frame offscreen and returns linear RGB floats, row-major,
    /// top-left origin.
    ///
    /// - Parameter upscaleFrom: when non-nil the marcher renders at that smaller
    ///   size and the full-screen linear quad upscales into `width`x`height`,
    ///   exercising the same path the window uses below full render scale.
    public func renderToRGB(
        uniforms: Uniforms,
        width: Int,
        height: Int,
        upscaleFrom: (width: Int, height: Int)? = nil
    ) throws -> [Float] {
        let src = try makeIntermediateTexture(width: width, height: height)
        let intermediate: MTLTexture?
        if let from = upscaleFrom {
            intermediate = try makeIntermediateTexture(width: from.width, height: from.height)
        } else {
            intermediate = nil
        }

        let ds = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: max(width, 1), height: max(height, 1), mipmapped: false)
        ds.usage = [.shaderRead]
        ds.storageMode = .shared
        guard let readback = device.makeTexture(descriptor: ds) else {
            throw RendererError.allocationFailed("Could not allocate a readback texture.")
        }

        guard let cb = commandQueue.makeCommandBuffer() else {
            throw RendererError.commandBufferFailed("Could not create a command buffer.")
        }
        cb.label = "vsbm.offscreen"
        try encode(into: cb, destination: src, uniforms: uniforms, intermediate: intermediate)

        guard let blit = cb.makeBlitCommandEncoder() else {
            throw RendererError.commandBufferFailed("Could not create a blit encoder.")
        }
        blit.copy(from: src, to: readback)
        blit.endEncoding()

        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error {
            throw RendererError.commandBufferFailed(error.localizedDescription)
        }

        let bytesPerRow = width * 4
        var bgra = [UInt8](repeating: 0, count: bytesPerRow * height)
        bgra.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                readback.getBytes(
                    base,
                    bytesPerRow: bytesPerRow,
                    from: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0)
            }
        }

        var out = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            let b = Float(bgra[i * 4 + 0]) / 255.0
            let g = Float(bgra[i * 4 + 1]) / 255.0
            let r = Float(bgra[i * 4 + 2]) / 255.0
            out[i * 3 + 0] = r
            out[i * 3 + 1] = g
            out[i * 3 + 2] = b
        }
        return out
    }

    // MARK: - Bounding-sphere probe

    /// Samples the SDF on an `n^3` lattice and returns the largest radius at
    /// which any sample still satisfies `sdf > -delta`, plus a safety margin of
    /// `margin` lattice spacings.
    ///
    /// The result is a *heuristic* bound: it is only guaranteed over the lattice,
    /// not over the continuum. The app therefore reports the pixel difference
    /// between the early-out and the faithful path rather than claiming the two
    /// are identical.
    public func probeBoundingRadius(
        extent: Double,
        samples n: Int,
        delta: Double,
        margin: Double
    ) throws -> Double {
        guard let pso = probePipeline else {
            throw RendererError.pipelineCreationFailed("The probe kernel is unavailable.")
        }
        let count = n * n * n
        guard let buffer = device.makeBuffer(
            length: count * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        else {
            throw RendererError.allocationFailed("Could not allocate the probe buffer.")
        }
        memset(buffer.contents(), 0, buffer.length)

        var params = ProbeParams(extent: Float(extent), n: Int32(n), delta: Float(delta), pad0: 0)

        guard let cb = commandQueue.makeCommandBuffer(),
              let encoder = cb.makeComputeCommandEncoder() else {
            throw RendererError.commandBufferFailed("Could not create the probe encoder.")
        }
        encoder.label = "vsbm.probe"
        encoder.setComputePipelineState(pso)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<ProbeParams>.stride, index: 1)
        let tg = MTLSize(width: 8, height: 8, depth: 8)
        encoder.dispatchThreads(MTLSize(width: n, height: n, depth: n), threadsPerThreadgroup: tg)
        encoder.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error {
            throw RendererError.commandBufferFailed(error.localizedDescription)
        }

        let values = buffer.contents().bindMemory(to: UInt32.self, capacity: count)
        var maxSq: UInt32 = 0
        for i in 0..<count where values[i] > maxSq {
            maxSq = values[i]
        }
        let found = Double(Float(bitPattern: maxSq).squareRoot())
        let lattice = 2.0 * extent / Double(n)
        return found + margin * lattice
    }

    // MARK: - Raw throughput

    /// Runs the marcher into an offscreen texture with no presentation, which
    /// removes the compositor from the loop and reports pure GPU throughput.
    public func measureRawThroughput(
        width: Int,
        height: Int,
        warmup: Int,
        frames: Int,
        uniformsForFrame: (Int) -> Uniforms
    ) throws -> RawThroughputResult {
        let texture = try makeIntermediateTexture(width: width, height: height)
        var samples: [Double] = []
        samples.reserveCapacity(frames)

        for i in 0..<(warmup + frames) {
            guard let cb = commandQueue.makeCommandBuffer() else {
                throw RendererError.commandBufferFailed("Could not create a command buffer.")
            }
            cb.label = "vsbm.raw[\(i)]"
            try encode(
                into: cb, destination: texture, uniforms: uniformsForFrame(i), intermediate: nil)
            cb.commit()
            cb.waitUntilCompleted()
            if let error = cb.error {
                throw RendererError.commandBufferFailed(error.localizedDescription)
            }
            if i >= warmup {
                samples.append((cb.gpuEndTime - cb.gpuStartTime) * 1000.0)
            }
        }

        let sorted = samples.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
        return RawThroughputResult(
            frames: frames,
            width: width,
            height: height,
            medianGPUMs: median,
            minGPUMs: sorted.first ?? 0,
            maxGPUMs: sorted.last ?? 0,
            meanGPUMs: mean,
            fps: median > 0 ? 1000.0 / median : 0
        )
    }

    // MARK: - Comparison

    /// Compares two RGB float buffers.
    public static func difference(_ a: [Float], _ b: [Float]) -> FrameDifference {
        let n = min(a.count, b.count)
        guard n > 0 else {
            return FrameDifference(pixels: 0, fractionBeyond1Step: 0, meanAbsDelta: 0, maxAbsDelta: 0)
        }
        var sum = 0.0
        var maxDelta = 0.0
        var beyond = 0
        var px = 0
        let oneStep = 1.0 / 255.0
        for i in stride(from: 0, to: n - 2, by: 3) {
            let d = max(abs(a[i] - b[i]), max(abs(a[i + 1] - b[i + 1]), abs(a[i + 2] - b[i + 2])))
            let dd = Double(d)
            sum += dd
            maxDelta = max(maxDelta, dd)
            if dd > oneStep { beyond += 1 }
            px += 1
        }
        return FrameDifference(
            pixels: px,
            fractionBeyond1Step: px > 0 ? Double(beyond) / Double(px) : 0,
            meanAbsDelta: px > 0 ? sum / Double(px) : 0,
            maxAbsDelta: maxDelta
        )
    }
}

// MARK: - Helpers

@inline(__always)
func elapsedMS(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
}
