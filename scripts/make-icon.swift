// Draws the Hush app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
// Only needed when the icon design changes; the .icns is checked in.
import AppKit

let canvas: CGFloat = 1024
// Apple's macOS icon grid: an 824pt rounded tile centred on a 1024pt canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / canvas
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)

    // Tile with a soft drop shadow, like system icons.
    let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.36, green: 0.33, blue: 0.95, alpha: 1),
        ending: NSColor(calibratedRed: 0.12, green: 0.10, blue: 0.35, alpha: 1))!
    gradient.draw(in: path, angle: -90)

    // White headphones glyph, centred on the tile.
    let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let s = symbol.size
    symbol.draw(in: NSRect(x: tile.midX - s.width / 2, y: tile.midY - s.height / 2,
                           width: s.width, height: s.height))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
try? render(size: 1024).write(to: root.appendingPathComponent("build/icon-preview.png"))
print("Wrote \(out.path)")
