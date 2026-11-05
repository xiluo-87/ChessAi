#!/usr/bin/env swift
// Renders Assets/AppIcon/*.svg into Assets/AppIcon/AppIcon.icns. Run it from the repo after changing the artwork:
// `swift scripts/make-icon.swift`. The small artwork, with heavier braces, is used at 32 pixels and below.
import AppKit

let folder = URL(fileURLWithPath: "Assets/AppIcon")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func render(_ svg: String, pixels: Int, to name: String) throws {
    guard let image = NSImage(contentsOf: folder.appendingPathComponent(svg)),
          let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])?.write(to: iconset.appendingPathComponent(name))
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels <= 32 ? "icon-small.svg" : "icon.svg", pixels: pixels, to: name)
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", folder.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
