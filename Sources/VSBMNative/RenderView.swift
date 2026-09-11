import AppKit
import Metal
import QuartzCore
import simd
import VSBMNativeCore

/// Notified when the render view produces something the UI should show.
protocol RenderViewDelegate: AnyObject {
    /// A kernel compile finished, successfully or not.
    func renderView(_ view: RenderView, didCompile result: KernelCompileResult)
    /// A raw offscreen throughput measurement finished.
    func renderView(_ view: RenderView, didMeasure result: RawThroughputResult)
    /// A fidelity comparison against the reference configuration finished.
    func renderView(_ view: RenderView, didCompare diff: FrameDifference, at size: String)
}

/// Hosts a `CAMetalLayer` and owns the frame loop.
///
/// Rendering is driven by `NSView.displayLink(target:selector:)`, the modern
/// replacement for `CVDisplayLink`. `MTKView` is deliberately not used: it caps
/// the frame rate through its own internal pacing and does not expose
/// `maximumDrawableCount`, `displaySyncEnabled` or the drawable timeout.
final class RenderView: NSView {

    weak var delegate: RenderViewDelegate?

    // MARK: State

    let renderer: MetalRenderer
    let stats = FrameStats()
    let autoResolution = AutoResolution()

    var camera = Camera()
    private(set) var preset: Preset
    private(set) var kernelName: String
    private(set) var kernelSource: String

    /// Auto-rotation pauses while the user drags, matching the reference.
    private var isDragging = false

    // MARK: Metal plumbing

    /// The backing layer is created by `makeBackingLayer()` and is a CAMetalLayer.
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private var displayLink: CADisplayLink?
    private var intermediateTexture: MTLTexture?
    private var intermediateSize: (width: Int, height: Int) = (0, 0)
    private let inFlight = DispatchSemaphore(value: 3)
    private var lastFrameTimestamp: Double = 0
    private var isSuspendedForOcclusion = false
    private let benchmarkQueue = DispatchQueue(label: "vsbm.benchmark", qos: .userInitiated)

    /// The size the marcher actually renders at, after the render scale.
    private(set) var currentRenderSize: (width: Int, height: Int) = (0, 0)

    // MARK: Init

    init(renderer: MetalRenderer, preset: Preset, kernelName: String, kernelSource: String) {
        self.renderer = renderer
        self.preset = preset
        self.kernelName = kernelName
        self.kernelSource = kernelSource
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        self.wantsLayer = true
        self.camera.len = preset.cameraLen
        // Applying the preset here matters: AutoResolution defaults to enabled
        // with a 60 FPS target, so without this even the bit-faithful Reference
        // preset would start adapting its resolution.
        applyPresetState(preset)
    }

    /// Pushes the preset's pacing and resolution policy into the controller, and
    /// makes sure the early-out has a usable radius before it is switched on.
    private func applyPresetState(_ newPreset: Preset) {
        autoResolution.targetFPS = newPreset.targetFPS
        autoResolution.enabled = newPreset.autoScale
        autoResolution.baseMaxScale = 1.0
        autoResolution.reset(to: newPreset.fixedScale)
        ensureBoundingRadius()
    }

    /// The bounding radius is a property of the kernel, not of the preset, so it
    /// is probed on demand the first time a preset asks for the early-out.
    private func ensureBoundingRadius() {
        let options = renderer.options
        guard options.useBoundingSphere, options.boundingRadius <= 0 else { return }
        let extent = Double(options.maxIter) * RenderOptions.referenceStep * camera.len * 1.05
        do {
            let radius = try renderer.probeBoundingRadius(
                extent: extent, samples: 96,
                delta: options.boundingDelta, margin: options.boundingMargin)
            updateOptions { $0.boundingRadius = radius }
        } catch {
            NSLog("vsbm: bounding radius probe failed (\(error.localizedDescription)); "
                  + "disabling the early-out")
            updateOptions { $0.useBoundingSphere = false }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("RenderView is created programmatically")
    }

    override func makeBackingLayer() -> CALayer {
        let metal = CAMetalLayer()
        metal.device = renderer.device
        metal.pixelFormat = .bgra8Unorm
        // The drawable is never sampled or read back, so let the compositor
        // optimise it.
        metal.framebufferOnly = true
        // Three drawables keeps the GPU fed without adding a whole frame of
        // latency.
        metal.maximumDrawableCount = 3
        metal.presentsWithTransaction = false
        metal.isOpaque = true
        if let space = CGColorSpace(name: CGColorSpace.sRGB) {
            metal.colorspace = space
        }
        return metal
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            NotificationCenter.default.addObserver(
                self, selector: #selector(occlusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(
                self, selector: #selector(backingChanged),
                name: NSWindow.didChangeBackingPropertiesNotification, object: window)
            start()
        } else {
            NotificationCenter.default.removeObserver(self)
            stop()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func updateLayerGeometry() {
        let backing = window?.backingScaleFactor ?? 2.0
        let pixelWidth = max(Int((bounds.width * backing).rounded()), 1)
        let pixelHeight = max(Int((bounds.height * backing).rounded()), 1)
        metalLayer.contentsScale = backing
        metalLayer.drawableSize = CGSize(width: pixelWidth, height: pixelHeight)
    }

    /// An occluded or miniaturised window stops rendering entirely, which is the
    /// single largest power saving available to an app that is otherwise
    /// GPU-bound.
    @objc private func occlusionChanged() {
        updateLayerGeometry()
        let visible = window?.occlusionState.contains(.visible) ?? false
        guard let window, !window.isMiniaturized, visible else {
            isSuspendedForOcclusion = true
            stop()
            return
        }
        isSuspendedForOcclusion = false
        start()
    }

    @objc private func backingChanged() {
        updateLayerGeometry()
        intermediateTexture = nil
        intermediateSize = (0, 0)
    }

    func start() {
        guard !isSuspendedForOcclusion else { return }
        updateLayerGeometry()
        guard displayLink == nil else { return }
        let link = self.displayLink(target: self, selector: #selector(step))
        let preferred = preset.targetFPS > 0 ? preset.targetFPS : 120
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30, maximum: 120, preferred: Float(preferred))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastFrameTimestamp = CACurrentMediaTime()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: Configuration

    func applyPreset(_ newPreset: Preset, kernelName name: String, kernelSource source: String) {
        preset = newPreset
        if kernelName != name || kernelSource != source {
            kernelName = name
            kernelSource = source
            let result = renderer.setKernel(source)
            delegate?.renderView(self, didCompile: result)
        }
        if let result = renderer.setOptions(newPreset.options) {
            delegate?.renderView(self, didCompile: result)
        }
        camera.len = newPreset.cameraLen
        applyPresetState(newPreset)
        intermediateTexture = nil
        intermediateSize = (0, 0)
        // Re-apply the pacing to match the new target.
        stop()
        start()
    }

    func updateOptions(_ mutate: (inout RenderOptions) -> Void) {
        var options = renderer.options
        mutate(&options)
        if let result = renderer.setOptions(options) {
            delegate?.renderView(self, didCompile: result)
        }
    }

    @discardableResult
    func setKernel(name: String, source: String) -> KernelCompileResult {
        kernelName = name
        kernelSource = source
        let result = renderer.setKernel(source)
        delegate?.renderView(self, didCompile: result)
        return result
    }

    func setRenderScale(_ scale: Double) {
        autoResolution.reset(to: scale)
    }

    func setAutoScale(enabled: Bool, targetFPS: Double) {
        autoResolution.enabled = enabled
        autoResolution.targetFPS = targetFPS
    }

    var isOffscreenPreset: Bool { preset.offscreen }

    // MARK: Frame loop

    @objc private func step() {
        guard !isOffscreenPreset, !isSuspendedForOcclusion, window != nil else { return }
        let now = CACurrentMediaTime()
        let elapsed = max(now - lastFrameTimestamp, 0)
        lastFrameTimestamp = now

        if !isDragging {
            camera.advance(rotationMode: preset.rotationMode, elapsed: elapsed, speed: 1.0)
        }
        renderFrame()
        updateContext()
    }

    private func updateContext() {
        let backing = window?.backingScaleFactor ?? 2.0
        let output = (
            width: max(Int((bounds.width * backing).rounded()), 1),
            height: max(Int((bounds.height * backing).rounded()), 1)
        )
        let options = renderer.options
        let scale = autoResolution.scale
        let fidelity = options.isBitFaithful
            ? "faithful"
            : options.fidelityDeviations.joined(separator: ", ")
        let thermal = RenderView.thermalLabel(ProcessInfo.processInfo.thermalState)
        let size = currentRenderSize
        let deviceName = renderer.deviceName
        let presetName = preset.name
        let kernel = kernelName
        let backend = options.backend.label
        let autoOn = autoResolution.enabled
        let target = autoResolution.targetFPS
        let stepScale = options.stepScale
        let radius = options.boundingRadius
        stats.updateContext { c in
            c.preset = presetName
            c.kernel = kernel
            c.backend = backend
            c.fidelity = fidelity
            c.renderWidth = size.width
            c.renderHeight = size.height
            c.outputWidth = output.width
            c.outputHeight = output.height
            c.renderScale = scale
            c.autoScale = autoOn
            c.targetFPS = target
            c.stepScale = stepScale
            c.thermalState = thermal
            c.boundingRadius = radius
            c.deviceName = deviceName
        }
    }

    private func renderFrame() {
        // Adaptive resolution is stepped exactly once per frame, on the main
        // thread, from a window of samples that has fully turned over since the
        // last change. That single-threaded, once-per-frame discipline is what
        // keeps the controller from oscillating.
        if autoResolution.enabled {
            let median = stats.medianGPUMs(recent: AutoResolution.measurementWindow)
            if median > 0 {
                autoResolution.update(medianGPUMs: median)
            }
        }

        let backing = window?.backingScaleFactor ?? 2.0
        let outputWidth = max(Int((bounds.width * backing).rounded()), 1)
        let outputHeight = max(Int((bounds.height * backing).rounded()), 1)

        let renderSize = RenderSizing.renderSize(
            pointSize: bounds.size,
            backingScale: backing,
            resolution: preset.resolution,
            scale: autoResolution.scale)
        currentRenderSize = renderSize

        let direct = RenderSizing.canRenderDirectly(
            render: renderSize, output: (outputWidth, outputHeight))

        // Never block the main thread waiting for GPU progress. Blocking here
        // stalls the run loop, so the display link misses its vsync and every
        // frame silently costs an extra refresh interval. Skipping the tick
        // instead lets the next vsync pace the loop correctly.
        guard inFlight.wait(timeout: .now()) == .success else {
            stats.recordSkippedFrame()
            return
        }

        guard let drawable = metalLayer.nextDrawable() else {
            inFlight.signal()
            stats.recordSkippedFrame()
            return
        }

        let uniforms = Uniforms.make(
            camera: camera,
            renderWidth: renderSize.width,
            renderHeight: renderSize.height,
            options: renderer.options)

        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            stats.recordSkippedFrame()
            return
        }
        commandBuffer.label = "vsbm.frame"

        let encodeStart = DispatchTime.now()
        do {
            let intermediate = direct ? nil : try texture(for: renderSize)
            try renderer.encode(
                into: commandBuffer,
                destination: drawable.texture,
                uniforms: uniforms,
                intermediate: intermediate)
        } catch {
            inFlight.signal()
            stats.recordSkippedFrame()
            NSLog("vsbm: frame encode failed: \(error.localizedDescription)")
            return
        }
        let encodeMs = RenderView.since(encodeStart)

        commandBuffer.addCompletedHandler { [weak self] cb in
            guard let self else { return }
            self.inFlight.signal()
            let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000.0
            // FrameStats is lock-protected, so recording from this thread is safe.
            // AutoResolution is NOT, so it is only ever touched on the main
            // thread, in renderFrame().
            self.stats.record(gpuMs: gpuMs, encodeMs: encodeMs)
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func texture(for size: (width: Int, height: Int)) throws -> MTLTexture {
        if let existing = intermediateTexture,
           intermediateSize.width == size.width,
           intermediateSize.height == size.height {
            return existing
        }
        let texture = try renderer.makeIntermediateTexture(width: size.width, height: size.height)
        intermediateTexture = texture
        intermediateSize = size
        return texture
    }

    static func since(_ start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
    }

    static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: Actions used by the control panel

    /// Renders the current configuration and the bit-faithful reference
    /// configuration at a small size and reports the pixel difference. This is
    /// how the app stays honest about what each optimisation costs.
    func runFidelityComparison(size: Int = 160) {
        let currentOptions = renderer.options
        var referenceOptions = currentOptions
        referenceOptions.backend = .fragment
        referenceOptions.fastMath = false
        referenceOptions.stepScale = 1.0
        referenceOptions.maxIter = RenderOptions.referenceMaxIter
        referenceOptions.useBoundingSphere = false

        let cam = camera
        let currentUniforms = Uniforms.make(
            camera: cam, renderWidth: size, renderHeight: size, options: currentOptions)
        let referenceUniforms = Uniforms.make(
            camera: cam, renderWidth: size, renderHeight: size, options: referenceOptions)

        benchmarkQueue.async { [weak self] in
            guard let self else { return }
            let savedOptions = self.renderer.options
            defer { _ = self.renderer.setOptions(savedOptions) }
            do {
                _ = self.renderer.setOptions(referenceOptions)
                let referenceRGB = try self.renderer.renderToRGB(
                    uniforms: referenceUniforms, width: size, height: size)
                _ = self.renderer.setOptions(savedOptions)
                let currentRGB = try self.renderer.renderToRGB(
                    uniforms: currentUniforms, width: size, height: size)
                let diff = MetalRenderer.difference(referenceRGB, currentRGB)
                DispatchQueue.main.async {
                    self.delegate?.renderView(self, didCompare: diff, at: "\(size)\u{00D7}\(size)")
                }
            } catch {
                NSLog("vsbm: fidelity comparison failed: \(error.localizedDescription)")
            }
        }
    }

    /// Runs an unpresented offscreen measurement of raw GPU throughput.
    func runRawBenchmark(frames: Int = 30, warmup: Int = 5) {
        let backing = window?.backingScaleFactor ?? 2.0
        let size = RenderSizing.renderSize(
            pointSize: bounds.size, backingScale: backing,
            resolution: preset.resolution, scale: 1.0)
        let options = renderer.options
        let startCamera = camera
        let rotationMode = preset.rotationMode
        let framePeriod = Camera.RotationMode.referencePeriod
        let width = size.width, height = size.height

        benchmarkQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.renderer.measureRawThroughput(
                    width: width, height: height, warmup: warmup, frames: frames,
                    uniformsForFrame: { i in
                        var cam = startCamera
                        cam.advance(
                            rotationMode: rotationMode,
                            elapsed: framePeriod * Double(i),
                            speed: 1.0)
                        return Uniforms.make(
                            camera: cam, renderWidth: width, renderHeight: height, options: options)
                    })
                DispatchQueue.main.async {
                    self.delegate?.renderView(self, didMeasure: result)
                }
            } catch {
                NSLog("vsbm: raw benchmark failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isDragging = true
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        camera.rotate(dx: Double(event.deltaX), dy: Double(event.deltaY))
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func rightMouseDragged(with event: NSEvent) {
        camera.pan(
            dx: Double(event.deltaX), dy: Double(event.deltaY),
            viewWidth: Double(bounds.width), viewHeight: Double(bounds.height))
    }

    override func scrollWheel(with event: NSEvent) {
        // `deltaY` follows the DOM convention (positive scrolls down); macOS
        // scrollingDeltaY is inverted relative to it.
        let dy = event.hasPreciseScrollingDeltas
            ? Double(event.scrollingDeltaY)
            : Double(event.deltaY) * 10.0
        camera.zoom(deltaY: -dy)
    }

    override func magnify(with event: NSEvent) {
        camera.scaleLen(by: 1.0 / (1.0 + Double(event.magnification)))
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "r", "R":
            camera = Camera()
            camera.len = preset.cameraLen
        default:
            super.keyDown(with: event)
        }
    }
}
