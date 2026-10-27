#!/usr/bin/env swift
import AppKit

// Vector artwork rendered at every macOS icon size. No fonts or external assets.
let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets", isDirectory: true)
let iconset = destination.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func color(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}
func draw(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = color(0x00152F, alpha: 0.30); shadow.shadowBlurRadius = 26; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
    color(0x123D7C).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colorsAndLocations: (color(0x082854), 0), (color(0x1255A1), 0.60), (color(0x2877C9), 1))!.draw(in: tile, angle: 70)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    // Quiet measurement grid; the waveform stays legible at menu/Finder sizes.
    if pixels >= 64 {
        let grid = NSBezierPath()
        for x in stride(from: 288, through: 736, by: 224) { grid.move(to: NSPoint(x: x, y: 210)); grid.line(to: NSPoint(x: x, y: 814)) }
        for y in stride(from: 288, through: 736, by: 224) { grid.move(to: NSPoint(x: 210, y: y)); grid.line(to: NSPoint(x: 814, y: y)) }
        grid.lineWidth = 2; color(0xD3ECFF, alpha: 0.10).setStroke(); grid.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    let rim = NSBezierPath(roundedRect: NSRect(x: 66, y: 66, width: 892, height: 892), xRadius: 200, yRadius: 200)
    rim.lineWidth = 3; color(0xD5EAFF, alpha: 0.23).setStroke(); rim.stroke()
    let trace = NSBezierPath()
    trace.move(to: NSPoint(x: 218, y: 456))
    trace.line(to: NSPoint(x: 326, y: 456))
    trace.curve(to: NSPoint(x: 358, y: 480), controlPoint1: NSPoint(x: 343, y: 456), controlPoint2: NSPoint(x: 348, y: 466))
    trace.line(to: NSPoint(x: 391, y: 530))
    trace.line(to: NSPoint(x: 452, y: 354))
    trace.line(to: NSPoint(x: 548, y: 699))
    trace.line(to: NSPoint(x: 630, y: 456))
    trace.line(to: NSPoint(x: 802, y: 456))
    trace.lineWidth = pixels <= 32 ? 45 : 38; trace.lineCapStyle = .round; trace.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow(); glow.shadowColor = color(0x65D8FF, alpha: 0.36); glow.shadowBlurRadius = 26; glow.shadowOffset = .zero; glow.set()
    color(0xEFFAFF).setStroke(); trace.stroke()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 2 ? "@2x" : ""
        try draw(size * factor).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
try draw(1024).write(to: destination.appendingPathComponent("AppIcon.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", destination.appendingPathComponent("AppIcon.icns").path]
try task.run(); task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
try FileManager.default.removeItem(at: iconset)
print("Generated AppIcon.icns and AppIcon.png")
