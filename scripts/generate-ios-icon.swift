// Rebuild the app's simple vector brand mark without an image-generation dependency.
import AppKit
import Foundation

let size = 1024
let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
NSColor(red: 0.035, green: 0.055, blue: 0.065, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
for (diameter, alpha) in [(760.0, 0.15), (600.0, 0.28), (440.0, 0.5)] {
    NSColor(red: 0.35, green: 0.95, blue: 0.78, alpha: alpha).setStroke()
    let path = NSBezierPath(ovalIn: NSRect(x: (1024 - diameter) / 2, y: (1024 - diameter) / 2, width: diameter, height: diameter))
    path.lineWidth = 5; path.stroke()
}
NSColor(red: 0.45, green: 1, blue: 0.83, alpha: 1).setStroke()
for (index, height) in [80.0, 160, 260, 340, 210, 120, 60].enumerated() {
    let x = 326.0 + Double(index) * 62
    let path = NSBezierPath()
    path.lineWidth = 26; path.lineCapStyle = .round
    path.move(to: NSPoint(x: x, y: (1024 - height) / 2))
    path.line(to: NSPoint(x: x, y: (1024 + height) / 2))
    path.stroke()
}
NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: "app-ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try image.representation(using: .png, properties: [:])!.write(to: output)
