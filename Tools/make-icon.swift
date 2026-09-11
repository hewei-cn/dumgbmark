// make-icon.swift — builds Resources/AppIcon.icns from a frame rendered by the
// app itself, so the icon can never drift from what the renderer actually produces.
//
// Usage:
//   swift Tools/make-icon.swift <source.png> <out.iconset> [zoom]
//
// The composition follows the macOS convention: the artwork sits in a rounded
// square inset inside the full canvas, with a corner radius of roughly 22.4 % of
// the tile, and everything outside the tile stays transparent.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(
        Data("usage: make-icon.swift <source.png> <out.iconset> [zoom]\n".utf8))
    exit(2)
}

let sourcePath = arguments[1]
let iconsetPath = arguments[2]
// Fraction of the source frame to keep. Below 1.0 crops in, so the subject fills
// more of the tile and stays legible at 32 px.
let zoom = arguments.count >= 4 ? (Double(arguments[3]) ?? 0.88) : 0.88

let canvasSize = 1024
let tileInset = 100.0
let tileSize = Double(canvasSize) - 2 * tileInset
let cornerRadius = tileSize * 0.2237

func loadImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

guard let source = loadImage(sourcePath) else {
    FileHandle.standardError.write(Data("cannot read \(sourcePath)\n".utf8))
    exit(1)
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: canvasSize,
    height: canvasSize,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
    FileHandle.standardError.write(Data("cannot create a bitmap context\n".utf8))
    exit(1)
}

context.setShouldAntialias(true)
context.interpolationQuality = .high

let tile = CGRect(x: tileInset, y: tileInset, width: tileSize, height: tileSize)
context.saveGState()
context.addPath(CGPath(roundedRect: tile, cornerWidth: cornerRadius,
                       cornerHeight: cornerRadius, transform: nil))
context.clip()

// Crop the centre of the source, then cover the tile.
let sw = Double(source.width), sh = Double(source.height)
let cropW = sw * zoom, cropH = sh * zoom
let crop = CGRect(x: (sw - cropW) / 2, y: (sh - cropH) / 2, width: cropW, height: cropH)
var cropped: CGImage? = source
if let sub = source.cropping(to: crop) { cropped = sub }
if let image = cropped {
    context.draw(image, in: tile)
}
context.restoreGState()

// A hairline inner edge keeps the tile from disappearing against a dark desktop.
context.saveGState()
context.addPath(CGPath(roundedRect: tile.insetBy(dx: 1, dy: 1),
                       cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
context.setLineWidth(2)
context.strokePath()
context.restoreGState()

guard let master = context.makeImage() else {
    FileHandle.standardError.write(Data("cannot snapshot the icon\n".utf8))
    exit(1)
}

// ---- iconset ----------------------------------------------------------------
let fileManager = FileManager.default
try? fileManager.removeItem(atPath: iconsetPath)
try! fileManager.createDirectory(
    atPath: iconsetPath, withIntermediateDirectories: true)

func writePNG(_ image: CGImage, _ path: String) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

func scaled(_ image: CGImage, _ size: Int) -> CGImage? {
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()
}

let variants: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    guard let image = scaled(master, variant.size) else {
        FileHandle.standardError.write(Data("cannot scale to \(variant.size)\n".utf8))
        exit(1)
    }
    let path = (iconsetPath as NSString).appendingPathComponent(variant.name)
    guard writePNG(image, path) else {
        FileHandle.standardError.write(Data("cannot write \(path)\n".utf8))
        exit(1)
    }
}

print("wrote \(variants.count) PNGs to \(iconsetPath)")
