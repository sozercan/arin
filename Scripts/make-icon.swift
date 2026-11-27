#!/usr/bin/env swift
// Draws Arin's app icon and writes Resources/AppIcon.icns.
// Usage: swift Scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Draws the icon on a 1024-point canvas scaled to `pixels`.
func render(pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // macOS icon grid: an 824-point rounded square centered on the canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.30))
    ctx.addPath(shape)
    ctx.setFillColor(color(0, 0.4, 0.42))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0.20, 0.72, 0.69), color(0.00, 0.36, 0.40)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    // A soft highlight across the top.
    let gloss = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.22), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(gloss, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
    ctx.restoreGState()

    // The glyph: a ring gauge with most of its track reclaimed.
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 228
    ctx.setLineCap(.round)
    ctx.setLineWidth(78)

    ctx.setStrokeColor(color(1, 1, 1, 0.22))
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0, 0.15, 0.17, 0.35))
    ctx.setStrokeColor(color(1, 1, 1, 1))
    let start = CGFloat.pi * 0.5
    ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start - .pi * 1.45, clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()

    // The hub.
    ctx.setFillColor(color(1, 1, 1, 0.95))
    ctx.fillEllipse(in: CGRect(x: center.x - 58, y: center.y - 58, width: 116, height: 116))

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
