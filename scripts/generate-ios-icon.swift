// Generate the launcher icon and the matching, scalable in-app brand mark.
// Run from the repository root: swift scripts/generate-ios-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let bounds = CGRect(x: 0, y: 0, width: size, height: size)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let mint = CGColor(colorSpace: colorSpace, components: [0.36, 0.91, 0.75, 1])!
let ink = CGColor(colorSpace: colorSpace, components: [0.91, 1, 0.97, 1])!
let assets = URL(fileURLWithPath: "app-ios/Resources/Assets.xcassets", isDirectory: true)

func drawMark(in context: CGContext) {
    context.saveGState()
    defer { context.restoreGState() }
    context.setStrokeColor(mint.copy(alpha: 0.12)!)
    context.setLineWidth(3)
    context.strokeEllipse(in: CGRect(x: 135, y: 135, width: 754, height: 754))

    // An open ring and its presence dot suggest a connection in progress.
    context.setStrokeColor(mint)
    context.setLineWidth(44)
    context.setLineCap(.round)
    context.addArc(center: CGPoint(x: 512, y: 512), radius: 300,
                   startAngle: 80 * .pi / 180, endAngle: 370 * .pi / 180, clockwise: false)
    context.strokePath()
    let dot = CGPoint(x: 512 + 300 / sqrt(2), y: 512 + 300 / sqrt(2))
    context.setFillColor(mint)
    context.fillEllipse(in: CGRect(x: dot.x - 25, y: dot.y - 25, width: 50, height: 50))

    // Five strong bars remain legible at Home Screen and notification sizes.
    context.setFillColor(ink)
    for (index, height) in [96.0, 200, 290, 200, 96].enumerated() {
        let bar = CGRect(x: 356 + Double(index) * 69, y: (1024 - height) / 2,
                         width: 36, height: height)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 18, cornerHeight: 18, transform: nil))
        context.fillPath()
    }
}

// Render directly into a 32-bit RGB context so the PNG contains the drawn pixels.
// App Store icons must be opaque.
let bitmap = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                       bytesPerRow: 0, space: colorSpace,
                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let background = CGGradient(colorsSpace: colorSpace, colors: [
    CGColor(colorSpace: colorSpace, components: [0.035, 0.13, 0.14, 1])!,
    CGColor(colorSpace: colorSpace, components: [0.025, 0.055, 0.075, 1])!,
] as CFArray, locations: [0, 1])!
bitmap.drawLinearGradient(background, start: CGPoint(x: 160, y: 1024),
                          end: CGPoint(x: 864, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
drawMark(in: bitmap)
let icon = assets.appendingPathComponent("AppIcon.appiconset/AppIcon.png")
let destination = CGImageDestinationCreateWithURL(icon as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write the app icon") }

let mark = assets.appendingPathComponent("BrandMark.imageset", isDirectory: true)
try FileManager.default.createDirectory(at: mark, withIntermediateDirectories: true)
var mediaBox = bounds
let pdf = CGContext(mark.appendingPathComponent("BrandMark.pdf") as CFURL, mediaBox: &mediaBox, nil)!
pdf.beginPDFPage(nil)
drawMark(in: pdf)
pdf.endPDFPage()
pdf.closePDF()
print("Generated opaque 1024×1024 app icon and vector BrandMark.pdf")
