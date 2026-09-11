import AppKit
import UniformTypeIdentifiers
import VSBMNativeCore

/// Floating heads-up display drawn over the render view.
///
/// It is an ordinary AppKit view: the renderer is GPU-bound at tens of
/// milliseconds per frame, so a layer of text costs nothing measurable, and
/// keeping it out of the Metal pipeline means the HUD never perturbs the numbers
/// it reports.
final class StatsOverlay: NSVisualEffectView {

    private let line1 = NSTextField(labelWithString: "")
    private let line2 = NSTextField(labelWithString: "")
    private let line3 = NSTextField(labelWithString: "")
    private let line4 = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        appearance = NSAppearance(named: .darkAqua)

        let stack = NSStackView(views: [line1, line2, line3, line4])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for label in [line1, line2, line3, line4] {
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            label.lineBreakMode = .byClipping
        }
        line1.font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .bold)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("StatsOverlay is created programmatically")
    }

    func update(with snapshot: FrameStatsSnapshot) {
        let c = snapshot.context
        line1.stringValue = String(
            format: "%5.1f FPS   %5.1f ms GPU   %4.1f ms enc",
            snapshot.instantFPS, snapshot.medianGPUMs, snapshot.lastEncodeMs)
        line2.stringValue = String(
            format: "avg %5.1f   1%% low %5.1f   p99 %5.1f ms",
            snapshot.averageFPS, snapshot.onePercentLowFPS, snapshot.p99GPUMs)
        line3.stringValue = String(
            format: "%@  %@  %dx%d -> %dx%d  scale %.2f%@",
            c.preset, c.kernel,
            c.renderWidth, c.renderHeight, c.outputWidth, c.outputHeight,
            c.renderScale, c.autoScale ? " auto" : "")
        var flags = "\(c.backend)  \(c.fidelity)"
        if !c.boundingRadius.isNaN && c.boundingRadius > 0 {
            flags += String(format: "  sphere %.3f", c.boundingRadius)
        }
        if c.stepScale != 1.0 {
            flags += String(format: "  step %.2f", c.stepScale)
        }
        flags += "  thermal \(c.thermalState)"
        if snapshot.skippedFrames > 0 {
            flags += "  skipped \(snapshot.skippedFrames)"
        }
        line4.stringValue = flags
    }
}

/// Right-hand settings panel. Every value the renderer consumes is reachable
/// here, so nothing about the image is a hidden default.
final class ControlPanel: NSView {

    weak var renderView: RenderView?

    private let presetPopup = NSPopUpButton()
    private let kernelPopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let backendPopup = NSPopUpButton()
    private let targetPopup = NSPopUpButton()

    private let autoScaleCheckbox = NSButton(checkboxWithTitle: "Adaptive resolution", target: nil, action: nil)
    private let fastMathCheckbox = NSButton(checkboxWithTitle: "Fast math (breaks bit-fidelity)", target: nil, action: nil)
    private let sphereCheckbox = NSButton(checkboxWithTitle: "Bounding-sphere early-out", target: nil, action: nil)

    private let scaleSlider = NSSlider(value: 1.0, minValue: 0.1, maxValue: 1.0, target: nil, action: nil)
    private let stepSlider = NSSlider(value: 1.0, minValue: 1.0, maxValue: 4.0, target: nil, action: nil)
    private let scaleValue = NSTextField(labelWithString: "1.00")
    private let stepValue = NSTextField(labelWithString: "1.00")
    private let radiusValue = NSTextField(labelWithString: "not probed")

    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let resultLabel = NSTextField(labelWithString: "")

    private var editorWindow: NSWindow?
    private var editorTextView: NSTextView?
    private var editorDiagnostics: NSTextField?
    private var watchedKernelPath: URL?
    private var watchedKernelModification: Date?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        appearance = NSAppearance(named: .darkAqua)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("ControlPanel is created programmatically")
    }

    private func build() {
        presetPopup.addItems(withTitles: Presets.all.map(\.name))
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)

        kernelPopup.addItems(withTitles: BuiltInKernels.all.map(\.name) + ["custom"])
        kernelPopup.target = self
        kernelPopup.action = #selector(kernelChanged)

        resolutionPopup.addItems(withTitles: RenderResolution.allCases.map(\.label))
        resolutionPopup.target = self
        resolutionPopup.action = #selector(resolutionChanged)

        backendPopup.addItems(withTitles: RenderOptions.Backend.allCases.map(\.label))
        backendPopup.target = self
        backendPopup.action = #selector(backendChanged)

        targetPopup.addItems(withTitles: ["30 FPS", "60 FPS", "120 FPS"])
        targetPopup.target = self
        targetPopup.action = #selector(targetChanged)

        for cb in [autoScaleCheckbox, fastMathCheckbox, sphereCheckbox] {
            cb.target = self
            cb.action = #selector(checkboxChanged)
        }

        scaleSlider.target = self
        scaleSlider.action = #selector(scaleChanged)
        stepSlider.target = self
        stepSlider.action = #selector(stepChanged)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 4
        statusLabel.lineBreakMode = .byWordWrapping
        resultLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.maximumNumberOfLines = 6
        resultLabel.lineBreakMode = .byWordWrapping

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(header("Preset"))
        stack.addArrangedSubview(presetPopup)
        stack.addArrangedSubview(hint(Presets.reference.detail))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(header("Kernel"))
        stack.addArrangedSubview(kernelPopup)
        stack.addArrangedSubview(button("Edit kernel\u{2026}", #selector(openEditor)))
        stack.addArrangedSubview(button("Load kernel from file\u{2026}", #selector(loadKernelFromFile)))
        stack.addArrangedSubview(autoReloadCheckbox)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(header("Resolution"))
        stack.addArrangedSubview(resolutionPopup)
        stack.addArrangedSubview(autoScaleCheckbox)
        stack.addArrangedSubview(sliderRow("Scale", scaleSlider, scaleValue))
        stack.addArrangedSubview(targetRow())

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(header("Quality and speed"))
        stack.addArrangedSubview(backendRow())
        stack.addArrangedSubview(fastMathCheckbox)
        stack.addArrangedSubview(sphereCheckbox)
        stack.addArrangedSubview(radiusRow())
        stack.addArrangedSubview(sliderRow("Step", stepSlider, stepValue))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(header("Verification"))
        stack.addArrangedSubview(button("Compare with faithful reference", #selector(compareFidelity)))
        stack.addArrangedSubview(button("Run raw GPU benchmark", #selector(runRawBenchmark)))
        stack.addArrangedSubview(button("Reset statistics", #selector(resetStats)))
        stack.addArrangedSubview(button("Export report\u{2026}", #selector(exportReport)))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(resultLabel)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack

        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }

    private let autoReloadCheckbox = NSButton(
        checkboxWithTitle: "Reload file on change", target: nil, action: nil)

    // MARK: Small builders

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = .tertiaryLabelColor
        label.preferredMaxLayoutWidth = 280
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    private func sliderRow(_ name: String, _ slider: NSSlider, _ value: NSTextField) -> NSStackView {
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let title = NSTextField(labelWithString: name)
        title.font = NSFont.systemFont(ofSize: 11)
        title.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let row = NSStackView(views: [title, slider, value])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return row
    }

    private func targetRow() -> NSStackView {
        let title = NSTextField(labelWithString: "Target")
        title.font = NSFont.systemFont(ofSize: 11)
        title.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let row = NSStackView(views: [title, targetPopup])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    private func backendRow() -> NSStackView {
        let title = NSTextField(labelWithString: "Backend")
        title.font = NSFont.systemFont(ofSize: 11)
        title.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let row = NSStackView(views: [title, backendPopup])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    private func radiusRow() -> NSStackView {
        let probe = button("Probe", #selector(probeRadius))
        radiusValue.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        radiusValue.textColor = .secondaryLabelColor
        let row = NSStackView(views: [probe, radiusValue])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    // MARK: Sync from the render view

    func refresh() {
        guard let view = renderView else { return }
        let options = view.renderer.options

        presetPopup.selectItem(withTitle: view.preset.name)
        if let idx = BuiltInKernels.all.firstIndex(where: { $0.name == view.kernelName }) {
            kernelPopup.selectItem(at: idx)
        } else if kernelPopup.itemTitles.contains("custom") {
            kernelPopup.selectItem(withTitle: "custom")
        }
        resolutionPopup.selectItem(withTitle: view.preset.resolution.label)
        backendPopup.selectItem(withTitle: options.backend.label)

        autoScaleCheckbox.state = view.autoResolution.enabled ? .on : .off
        fastMathCheckbox.state = options.fastMath ? .on : .off
        sphereCheckbox.state = options.useBoundingSphere ? .on : .off

        scaleSlider.doubleValue = view.autoResolution.scale
        scaleValue.stringValue = String(format: "%.2f", view.autoResolution.scale)
        stepSlider.doubleValue = options.stepScale
        stepValue.stringValue = String(format: "%.2f", options.stepScale)
        radiusValue.stringValue = options.boundingRadius > 0
            ? String(format: "%.3f", options.boundingRadius)
            : "not probed"

        let target = view.autoResolution.targetFPS
        targetPopup.selectItem(withTitle: "\(Int(target)) FPS")

        let deviations = options.fidelityDeviations
        statusLabel.stringValue = deviations.isEmpty
            ? "Bit-faithful to the reference renderer."
            : "Deviates from reference: " + deviations.joined(separator: ", ")
    }

    /// Called from the app's 2 Hz UI timer to implement the optional file watch.
    func pollWatchedFile() {
        guard autoReloadCheckbox.state == .on,
              let url = watchedKernelPath,
              let view = renderView else { return }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        guard let modified, modified != watchedKernelModification else { return }
        watchedKernelModification = modified
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            view.setKernel(name: "custom", source: source)
            statusLabel.stringValue = "Reloaded \(url.lastPathComponent) from disk."
        } catch {
            statusLabel.stringValue = "Reload failed: \(error.localizedDescription)"
        }
    }

    // MARK: Actions

    @objc private func presetChanged() {
        guard let view = renderView,
              let preset = Presets.all.first(where: { $0.name == presetPopup.titleOfSelectedItem })
        else { return }
        view.applyPreset(preset, kernelName: view.kernelName, kernelSource: view.kernelSource)
        if preset.offscreen {
            view.runRawBenchmark()
            statusLabel.stringValue = "Measuring raw GPU throughput offscreen\u{2026}"
        }
        refresh()
    }

    @objc private func kernelChanged() {
        guard let view = renderView, let title = kernelPopup.titleOfSelectedItem else { return }
        guard let source = BuiltInKernels.source(named: title) else { return }
        view.setKernel(name: title, source: source)
        refresh()
    }

    @objc private func resolutionChanged() {
        guard let view = renderView,
              let resolution = RenderResolution.allCases.first(
                where: { $0.label == resolutionPopup.titleOfSelectedItem })
        else { return }
        var preset = view.preset
        preset.resolution = resolution
        view.applyPreset(preset, kernelName: view.kernelName, kernelSource: view.kernelSource)
        refresh()
    }

    @objc private func backendChanged() {
        guard let view = renderView,
              let backend = RenderOptions.Backend.allCases.first(
                where: { $0.label == backendPopup.titleOfSelectedItem })
        else { return }
        view.updateOptions { $0.backend = backend }
        refresh()
    }

    @objc private func targetChanged() {
        guard let view = renderView,
              let title = targetPopup.titleOfSelectedItem,
              let fps = Double(title.replacingOccurrences(of: " FPS", with: ""))
        else { return }
        view.setAutoScale(enabled: autoScaleCheckbox.state == .on, targetFPS: fps)
        refresh()
    }

    @objc private func checkboxChanged() {
        guard let view = renderView else { return }
        view.setAutoScale(
            enabled: autoScaleCheckbox.state == .on,
            targetFPS: view.autoResolution.targetFPS)
        view.updateOptions {
            $0.fastMath = fastMathCheckbox.state == .on
            $0.useBoundingSphere = sphereCheckbox.state == .on
        }
        refresh()
    }

    @objc private func scaleChanged() {
        guard let view = renderView else { return }
        view.setRenderScale(scaleSlider.doubleValue)
        scaleValue.stringValue = String(format: "%.2f", scaleSlider.doubleValue)
    }

    @objc private func stepChanged() {
        guard let view = renderView else { return }
        let value = stepSlider.doubleValue
        view.updateOptions { $0.stepScale = value }
        stepValue.stringValue = String(format: "%.2f", value)
        refresh()
    }

    @objc private func probeRadius() {
        guard let view = renderView else { return }
        let extent = Double(view.renderer.options.maxIter) * RenderOptions.referenceStep * view.camera.len * 1.05
        let options = view.renderer.options
        statusLabel.stringValue = "Probing the signed field\u{2026}"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let radius = try view.renderer.probeBoundingRadius(
                    extent: extent, samples: 96,
                    delta: options.boundingDelta, margin: options.boundingMargin)
                DispatchQueue.main.async {
                    view.updateOptions { $0.boundingRadius = radius }
                    self?.statusLabel.stringValue = String(
                        format: "Probed radius %.4f (grid extent %.3f).", radius, extent)
                    self?.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.statusLabel.stringValue =
                        "Probe failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func compareFidelity() {
        guard let view = renderView else { return }
        statusLabel.stringValue = "Comparing against the faithful reference\u{2026}"
        view.runFidelityComparison()
    }

    @objc private func runRawBenchmark() {
        guard let view = renderView else { return }
        statusLabel.stringValue = "Measuring raw GPU throughput\u{2026}"
        view.runRawBenchmark()
    }

    @objc private func resetStats() {
        renderView?.stats.reset()
        resultLabel.stringValue = ""
    }

    @objc private func exportReport() {
        guard let view = renderView else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vsbm-report.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = view.stats.snapshot()
        do {
            try view.stats.exportReportJSON(snapshot).write(to: url, atomically: true, encoding: .utf8)
            let csvURL = url.deletingPathExtension().appendingPathExtension("csv")
            try view.stats.exportFrameIntervalsCSV().write(to: csvURL, atomically: true, encoding: .utf8)
            statusLabel.stringValue = "Wrote \(url.lastPathComponent) and \(csvURL.lastPathComponent)."
        } catch {
            statusLabel.stringValue = "Export failed: \(error.localizedDescription)"
        }
    }

    @objc private func loadKernelFromFile() {
        guard let view = renderView else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .sourceCode]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            view.setKernel(name: "custom", source: source)
            watchedKernelPath = url
            watchedKernelModification = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            statusLabel.stringValue = "Loaded \(url.lastPathComponent)."
        } catch {
            statusLabel.stringValue = "Load failed: \(error.localizedDescription)"
        }
        refresh()
    }

    @objc private func openEditor() {
        guard let view = renderView else { return }
        if let window = editorWindow {
            window.makeKeyAndOrderFront(nil)
            editorTextView?.string = view.kernelSource
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Kernel editor \u{2014} define sdf(float3 p), positive inside"

        let textView = NSTextView()
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.string = view.kernelSource

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let diagnostics = NSTextField(wrappingLabelWithString: "")
        diagnostics.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnostics.textColor = .systemRed
        diagnostics.translatesAutoresizingMaskIntoConstraints = false

        let apply = NSButton(title: "Apply", target: self, action: #selector(applyEditorKernel))
        apply.bezelStyle = .rounded
        let revert = NSButton(title: "Revert", target: self, action: #selector(revertEditorKernel))
        revert.bezelStyle = .rounded
        let buttons = NSStackView(views: [apply, revert])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(diagnostics)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: diagnostics.topAnchor, constant: -8),
            diagnostics.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            diagnostics.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            diagnostics.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -6),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window.contentView = content
        window.center()

        editorWindow = window
        editorTextView = textView
        editorDiagnostics = diagnostics
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func applyEditorKernel() {
        guard let view = renderView, let textView = editorTextView else { return }
        let result = view.setKernel(name: "custom", source: textView.string)
        if result.succeeded {
            editorDiagnostics?.textColor = .systemGreen
            editorDiagnostics?.stringValue = String(
                format: "Compiled in %.0f ms.", result.compileMilliseconds)
        } else {
            editorDiagnostics?.textColor = .systemRed
            editorDiagnostics?.stringValue = result.diagnostics
                .map { $0.display }
                .joined(separator: "\n")
        }
        refresh()
    }

    @objc private func revertEditorKernel() {
        guard let view = renderView else { return }
        editorTextView?.string = view.kernelSource
        editorDiagnostics?.stringValue = ""
    }

    // MARK: Results routed from the app

    func show(compileResult: KernelCompileResult) {
        if compileResult.succeeded {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = String(format: "Kernel compiled in %.0f ms.",
                                             compileResult.compileMilliseconds)
        } else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Kernel failed to compile; previous pipeline kept.\n"
                + compileResult.diagnostics.map(\.display).joined(separator: "\n")
            if editorWindow?.isVisible == true {
                editorDiagnostics?.textColor = .systemRed
                editorDiagnostics?.stringValue =
                    compileResult.diagnostics.map(\.display).joined(separator: "\n")
            }
        }
    }

    func show(rawResult: RawThroughputResult) {
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.stringValue = String(
            format: "raw GPU: %.1f FPS  median %.2f ms  min %.2f  max %.2f  (%dx%d, %d frames)",
            rawResult.fps, rawResult.medianGPUMs, rawResult.minGPUMs, rawResult.maxGPUMs,
            rawResult.width, rawResult.height, rawResult.frames)
        statusLabel.stringValue = "Raw offscreen measurement complete."
    }

    func show(diff: FrameDifference, at size: String) {
        let percent = diff.fractionBeyond1Step * 100
        resultLabel.textColor = (diff.meanAbsDelta <= 1.0 / 255.0) ? .systemGreen : .systemOrange
        resultLabel.stringValue = String(
            format: "vs faithful @%@: mean |d| %.5f, max %.4f, %.3f%% of pixels differ",
            size, diff.meanAbsDelta, diff.maxAbsDelta, percent)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = diff.meanAbsDelta <= 1.0 / 255.0
            ? "Current settings are visually equivalent to the reference."
            : "Current settings visibly differ from the reference."
    }
}
