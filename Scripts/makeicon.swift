// makeicon.swift — render tech-pomodoro's 1024×1024 base icon to a PNG.
//
//   swift Scripts/makeicon.swift [--ios] [out.png]
//
// `--ios` draws the tile full-bleed and square: iOS masks the corners itself and rejects an icon with
// transparency, so the macOS inset and rounding are dropped.
//
// Draws into an offscreen bitmap (no window server required): a dark blue rounded-rect tile with a
// cyan outlined clock — the same cyan the menu bar and popover use. Scaled into the app icon set by
// Scripts/make-icon.sh.
import AppKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()
let fullBleed = arguments.contains("--ios")
let outPath = arguments.first { !$0.hasPrefix("--") } ?? "icon_1024.png"
let pixels = 1024
let S = CGFloat(pixels)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("could not allocate bitmap\n".utf8)); exit(1)
}

// The app's own palette: the cyan is the popover's primary text colour.
let cyan = NSColor(srgbRed: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255, alpha: 1)
let deepBlue = NSColor(srgbRed: 0x0B / 255, green: 0x1E / 255, blue: 0x3A / 255, alpha: 1)
let darkerBlue = NSColor(srgbRed: 0x06 / 255, green: 0x11 / 255, blue: 0x22 / 255, alpha: 1)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!

// Rounded-rect tile with a macOS-like inset + corner radius.
let inset = fullBleed ? 0 : S * 0.085
let rect = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let radius = fullBleed ? 0 : rect.width * 0.2237
let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

ctx.saveGraphicsState()
tile.addClip()
NSGradient(starting: deepBlue, ending: darkerBlue)!.draw(in: rect, angle: -90)
ctx.restoreGraphicsState()

let center = NSPoint(x: S / 2, y: S / 2)
// Sized from the macOS tile either way, so the glyph matches across platforms.
let dialRadius = S * (1 - 2 * 0.085) * 0.325
let stroke = S * 0.035

// The dial: a cyan ring, left as an outline rather than a filled face so the icon reads at 16pt.
let ring = NSBezierPath(ovalIn: NSRect(
    x: center.x - dialRadius, y: center.y - dialRadius,
    width: dialRadius * 2, height: dialRadius * 2
))
ring.lineWidth = stroke
cyan.setStroke()
ring.stroke()

// Twelve tick marks, the quarters longer than the rest.
for tick in 0..<12 {
    let angle = CGFloat(tick) * .pi / 6
    let isQuarter = tick % 3 == 0
    let outer = dialRadius - stroke * 0.9
    let inner = outer - (isQuarter ? dialRadius * 0.16 : dialRadius * 0.09)

    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x + sin(angle) * inner, y: center.y + cos(angle) * inner))
    path.line(to: NSPoint(x: center.x + sin(angle) * outer, y: center.y + cos(angle) * outer))
    path.lineWidth = isQuarter ? stroke * 0.7 : stroke * 0.45
    path.lineCapStyle = .round
    cyan.withAlphaComponent(isQuarter ? 1 : 0.55).setStroke()
    path.stroke()
}

// Hands set to 12:25 — the length of a work interval.
func hand(angle: CGFloat, length: CGFloat, width: CGFloat) {
    let path = NSBezierPath()
    path.move(to: center)
    path.line(to: NSPoint(x: center.x + sin(angle) * length, y: center.y + cos(angle) * length))
    path.lineWidth = width
    path.lineCapStyle = .round
    cyan.setStroke()
    path.stroke()
}

hand(angle: 0, length: dialRadius * 0.46, width: stroke * 0.95)                 // hour, at 12
hand(angle: .pi * 5 / 6, length: dialRadius * 0.68, width: stroke * 0.8)        // minute, at 25

// Hub, drawn over the hands so they meet cleanly.
let hubRadius = stroke * 0.85
cyan.setFill()
NSBezierPath(ovalIn: NSRect(
    x: center.x - hubRadius, y: center.y - hubRadius,
    width: hubRadius * 2, height: hubRadius * 2
)).fill()

NSGraphicsContext.restoreGraphicsState()

/// The iOS icon, flattened onto an opaque RGB bitmap: App Store Connect rejects an icon that carries
/// an alpha channel even when every pixel is opaque.
func opaque(_ rep: NSBitmapImageRep) -> NSBitmapImageRep? {
    guard let image = rep.cgImage,
          let context = CGContext(
              data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return context.makeImage().map(NSBitmapImageRep.init(cgImage:))
}

guard let output = fullBleed ? opaque(rep) : rep,
      let png = output.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG encode failed\n".utf8)); exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath) (\(pixels)×\(pixels))")
} catch {
    FileHandle.standardError.write(Data("write failed: \(error)\n".utf8)); exit(1)
}
