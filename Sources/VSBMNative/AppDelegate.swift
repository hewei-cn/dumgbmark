import AppKit
import VSBMNativeCore

/// Owns the window, the render view, the settings panel and the HUD.
final class AppDelegate: NSObject, NSApplicationDelegate, RenderViewDelegate {

    private var window: NSWindow!
    private var renderView: RenderView!
    private var controlPanel: ControlPanel!
    private var overlay: StatsOverlay!
    private var container: NSView!
    private var renderTrailingToPanel: NSLayoutConstraint!
    private var renderTrailingToContainer: NSLayoutConstraint!
    private var uiTimer: Timer?
    private var activityToken: NSObjectProtocol?

    private let panelWidth: CGFloat = 330

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        // ---- Renderer -----------------------------------------------------
        let (preset, kernelName, kernelSource) = resolveLaunchConfiguration()
        let renderer: MetalRenderer
        do {
            renderer = try MetalRenderer(kernelSource: kernelSource, options: preset.options)
        } catch {
            presentFatal("Metal renderer could not start", error.localizedDescription)
            return
        }

        // ---- Window -------------------------------------------------------
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "VSBM Native"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 480)
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()

        container = NSView(frame: frame)
        container.wantsLayer = true

        renderView = RenderView(
            renderer: renderer, preset: preset,
            kernelName: kernelName, kernelSource: kernelSource)
        renderView.translatesAutoresizingMaskIntoConstraints = false
        renderView.delegate = self

        controlPanel = ControlPanel()
        controlPanel.translatesAutoresizingMaskIntoConstraints = false
        controlPanel.renderView = renderView

        overlay = StatsOverlay()
        overlay.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(renderView)
        container.addSubview(controlPanel)
        container.addSubview(overlay)

        renderTrailingToPanel = renderView.trailingAnchor.constraint(
            equalTo: controlPanel.leadingAnchor)
        renderTrailingToContainer = renderView.trailingAnchor.constraint(
            equalTo: container.trailingAnchor)

        NSLayoutConstraint.activate([
            renderView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            renderView.topAnchor.constraint(equalTo: container.topAnchor),
            renderView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            renderTrailingToPanel,

            controlPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controlPanel.topAnchor.constraint(equalTo: container.topAnchor),
            controlPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            controlPanel.widthAnchor.constraint(equalToConstant: panelWidth),

            overlay.leadingAnchor.constraint(equalTo: renderView.leadingAnchor, constant: 16),
            overlay.topAnchor.constraint(equalTo: renderView.topAnchor, constant: 16),
        ])

        window.contentView = container

        // Drawable memory is the dominant runtime cost, and it scales with the
        // window's *pixel* area (points x backing scale, so 4x on Retina). This
        // flag exists so that relationship can be measured rather than assumed.
        if let text = argumentValue("--window-size"), let size = Self.parseSize(text) {
            window.setContentSize(NSSize(width: size.width, height: size.height))
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        controlPanel.refresh()
        startUITimer()
        installThermalObserver()
        preventAppNap()
        scheduleSoakIfRequested()
    }

    /// `--soak <seconds>`: run the real windowed pipeline for the given number of
    /// seconds, print what it measured, and exit. This exercises the drawable,
    /// the display link, the upscale pass and the statistics path, so it verifies
    /// the windowed renderer rather than assuming it works.
    private func scheduleSoakIfRequested() {
        guard let text = argumentValue("--soak"), let seconds = Double(text), seconds > 0 else {
            return
        }
        NSLog("vsbm: soak for \(Int(seconds))s")
        print("launch args       \(CommandLine.arguments.dropFirst().joined(separator: " "))")
        print("launch kernel     \(renderView.kernelName)")
        print("launch preset     \(renderView.preset.name)  autoScale \(renderView.preset.autoScale)  target \(Int(renderView.preset.targetFPS))")
        print("launch options    sphere \(renderer_options_summary(renderView.renderer.options))")
        fflush(stdout)
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, let view = self.renderView else { return }
            let snap = view.stats.snapshot()
            let c = snap.context
            let pipeline = view.autoResolution.enabled ? "adaptive" : "fixed"
            print("---- soak result ----")
            print("preset            \(c.preset)  (\(c.kernel), \(c.backend), \(pipeline))")
            print("fidelity          \(c.fidelity)")
            print("output            \(c.outputWidth)x\(c.outputHeight)")
            print("render            \(c.renderWidth)x\(c.renderHeight)  scale \(String(format: "%.3f", c.renderScale))")
            print("frames            \(snap.totalFrames) in \(String(format: "%.1f", snap.elapsedSeconds))s, skipped \(snap.skippedFrames)")
            print(String(format: "instant FPS       %.1f", snap.instantFPS))
            print(String(format: "average FPS       %.1f", snap.averageFPS))
            print(String(format: "1%% low FPS        %.1f", snap.onePercentLowFPS))
            print(String(format: "GPU median ms     %.2f  (p99 %.2f, min %.2f, max %.2f)",
                         snap.medianGPUMs, snap.p99GPUMs, snap.minGPUMs, snap.maxGPUMs))
            print(String(format: "encode ms         %.3f", snap.lastEncodeMs))
            print(String(format: "thermal           %@", c.thermalState))
            let backing = view.window?.backingScaleFactor ?? 0
            let base = view.preset.resolution.baseSize(
                pointSize: view.bounds.size, backingScale: backing)
            print("view bounds       \(Int(view.bounds.width))x\(Int(view.bounds.height)) pt, backing \(backing)x")
            print("resolution mode   \(view.preset.resolution.label)  base \(base.width)x\(base.height)")
            print("scale controller  enabled \(view.autoResolution.enabled), changes \(view.autoResolution.changes), last: \(view.autoResolution.lastReason)")
            print("---------------------")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        uiTimer?.invalidate()
        renderView?.stop()
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
    }

    // MARK: Launch configuration

    private func resolveLaunchConfiguration() -> (Preset, String, String) {
        // Double-clicking the icon should land on the preset that runs at the
        // display's refresh rate. The bit-faithful Reference preset is one
        // keypress away (Cmd-1) and is still what benchmark scores come from.
        var preset = Presets.balanced
        if let id = argumentValue("--preset"), let chosen = Presets.preset(id: id) {
            preset = chosen
        }
        var name = "mandelbulb8"
        var source = BuiltInKernels.mandelbulb8
        if let path = argumentValue("--kernel") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                name = "custom"
                source = text
            } else {
                NSLog("vsbm: could not read kernel at \(url.path), using the built-in kernel")
            }
        }
        return (preset, name, source)
    }

    static func parseSize(_ text: String) -> (width: Int, height: Int)? {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else {
            return nil
        }
        return (w, h)
    }

    private func argumentValue(_ flag: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: flag),
              i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    // MARK: Power and thermals

    /// App Nap would otherwise throttle the frame loop as soon as the window is
    /// not frontmost, which would corrupt every measurement.
    private func preventAppNap() {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Rendering a GPU-bound benchmark; frame pacing must stay accurate.")
    }

    private func installThermalObserver() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        thermalStateChanged()
    }

    @objc private func thermalStateChanged() {
        guard let view = renderView else { return }
        let cap: Double
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: cap = 1.0
        case .serious: cap = 0.75
        case .critical: cap = 0.5
        @unknown default: cap = 1.0
        }
        view.autoResolution.setThermalCap(cap)
    }

    // MARK: UI timer

    /// The HUD refreshes twice a second, exactly like the reference renderer's
    /// counter. Nothing on the render path formats strings.
    private func startUITimer() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let view = self.renderView else { return }
            self.overlay.update(with: view.stats.snapshot())
            self.controlPanel.pollWatchedFile()
        }
        RunLoop.main.add(timer, forMode: .common)
        uiTimer = timer
    }

    // MARK: Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About VSBM Native",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide VSBM Native",
            action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit VSBM Native",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(
            withTitle: "Toggle Settings Panel",
            action: #selector(togglePanel), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        for (index, preset) in Presets.all.enumerated() {
            let item = NSMenuItem(
                title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "\(index + 1)")
            item.target = self
            item.tag = index
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: "Reset Camera",
            action: #selector(resetCamera), keyEquivalent: "r")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func togglePanel() {
        let hidden = !controlPanel.isHidden
        controlPanel.isHidden = hidden
        // Exactly one trailing constraint may be active at a time.
        renderTrailingToPanel.isActive = !hidden
        renderTrailingToContainer.isActive = hidden
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let view = renderView,
              sender.tag >= 0, sender.tag < Presets.all.count else { return }
        let preset = Presets.all[sender.tag]
        view.applyPreset(preset, kernelName: view.kernelName, kernelSource: view.kernelSource)
        if preset.offscreen { view.runRawBenchmark() }
        controlPanel.refresh()
    }

    @objc private func resetCamera() {
        guard let view = renderView else { return }
        var camera = Camera()
        camera.len = view.preset.cameraLen
        view.camera = camera
    }

    private func presentFatal(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: RenderViewDelegate

    func renderView(_ view: RenderView, didCompile result: KernelCompileResult) {
        controlPanel.show(compileResult: result)
    }

    func renderView(_ view: RenderView, didMeasure result: RawThroughputResult) {
        controlPanel.show(rawResult: result)
    }

    func renderView(_ view: RenderView, didCompare diff: FrameDifference, at size: String) {
        controlPanel.show(diff: diff, at: size)
    }
}

/// One-line description of the option block, used by `--soak` diagnostics.
func renderer_options_summary(_ options: RenderOptions) -> String {
    "backend \(options.backend.label), fastMath \(options.fastMath), "
        + "sphere \(options.useBoundingSphere ? String(format: "r=%.4f", options.boundingRadius) : "off")"
}
