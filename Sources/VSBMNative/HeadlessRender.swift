import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VSBMNativeCore

/// Headless single-frame renderer.
///
/// `VSBMNative --render out.png [--size 1024x1024] [--preset reference]
///  [--kernel path.metal] [--angle1 2.8] [--angle2 0.4] [--len 1.6]`
///
/// This drives exactly the same renderer the window does, so a captured frame is
/// a faithful regression artifact and does not need a display or screen
/// recording permission.
enum HeadlessRender {

    static func run(arguments: [String]) throws {
        let path = value(after: "--render", in: arguments) ?? "vsbm.png"
        let presetID = value(after: "--preset", in: arguments) ?? "reference"
        let preset = Presets.preset(id: presetID) ?? Presets.reference

        var kernelName = "mandelbulb8"
        var kernelSource = BuiltInKernels.mandelbulb8
        if let kernelPath = value(after: "--kernel", in: arguments) {
            let expanded = (kernelPath as NSString).expandingTildeInPath
            kernelSource = try String(contentsOfFile: expanded, encoding: .utf8)
            kernelName = (expanded as NSString).lastPathComponent
        }

        let size = parseSize(value(after: "--size", in: arguments)) ?? (1024, 1024)

        var camera = Camera()
        camera.len = preset.cameraLen
        if let text = value(after: "--angle1", in: arguments), let v = Double(text) { camera.ang1 = v }
        if let text = value(after: "--angle2", in: arguments), let v = Double(text) { camera.ang2 = v }
        if let text = value(after: "--len", in: arguments), let v = Double(text) { camera.len = v }
        if let text = value(after: "--panx", in: arguments), let v = Double(text) { camera.cenx = v }
        if let text = value(after: "--pany", in: arguments), let v = Double(text) { camera.ceny = v }
        if let text = value(after: "--panz", in: arguments), let v = Double(text) { camera.cenz = v }

        var options = preset.options
        if let text = value(after: "--max-iter", in: arguments), let v = Int32(text) { options.maxIter = v }
        if let text = value(after: "--step-scale", in: arguments), let v = Double(text) { options.stepScale = v }
        if arguments.contains("--fast-math") { options.fastMath = true }
        if arguments.contains("--compute") { options.backend = .compute }
        if arguments.contains("--sphere") {
            options.useBoundingSphere = true
            if let text = value(after: "--sphere-radius", in: arguments), let v = Double(text) {
                options.boundingRadius = v
            }
        }

        let renderer = try MetalRenderer(kernelSource: kernelSource, options: options)

        if options.useBoundingSphere && options.boundingRadius <= 0 {
            let extent = Double(options.maxIter) * RenderOptions.referenceStep * camera.len * 1.05
            options.boundingRadius = try renderer.probeBoundingRadius(
                extent: extent, samples: 96,
                delta: options.boundingDelta, margin: options.boundingMargin)
        }

        let uniforms = Uniforms.make(
            camera: camera, renderWidth: size.0, renderHeight: size.1, options: options)

        let start = DispatchTime.now()
        let rgb = try renderer.renderToRGB(uniforms: uniforms, width: size.0, height: size.1)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try PNGWriter.write(rgb: rgb, width: size.0, height: size.1, to: url)

        let lit = rgb.filter { $0 > 0.02 }.count
        print("device      \(renderer.deviceName)")
        print("preset      \(preset.name)   kernel \(kernelName)")
        print("resolution  \(size.0)x\(size.1)")
        print("options     backend \(options.backend.label), fastMath \(options.fastMath), "
              + "stepScale \(options.stepScale), maxIter \(options.maxIter), "
              + "sphere \(options.useBoundingSphere ? String(format: "r=%.4f", options.boundingRadius) : "off")")
        print("fidelity    \(options.isBitFaithful ? "bit-faithful" : options.fidelityDeviations.joined(separator: ", "))")
        print(String(format: "frame       %.1f ms wall (includes readback)", ms))
        print("non-black   \(lit) of \(rgb.count) channels")
        print("wrote       \(url.path)")
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    private static func parseSize(_ text: String?) -> (Int, Int)? {
        guard let text else { return nil }
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return (max(w, 1), max(h, 1))
    }
}

enum PNGWriter {
    enum Failure: LocalizedError {
        case imageCreation
        case destinationCreation(String)

        var errorDescription: String? {
            switch self {
            case .imageCreation: return "Could not build a CGImage from the rendered pixels."
            case .destinationCreation(let p): return "Could not create a PNG at \(p)."
            }
        }
    }

    /// Writes linear-ish RGB floats (already 0...1 display values) as an 8-bit
    /// sRGB PNG.
    static func write(rgb: [Float], width: Int, height: Int, to url: URL) throws {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            for c in 0..<3 {
                let v = rgb[i * 3 + c]
                let scaled = (v.isFinite ? v : 0) * 255.0
                bytes[i * 4 + c] = UInt8(min(max(scaled.rounded(), 0), 255))
            }
            bytes[i * 4 + 3] = 255
        }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw Failure.imageCreation
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else {
            throw Failure.imageCreation
        }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw Failure.destinationCreation(url.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.destinationCreation(url.path)
        }
    }
}
