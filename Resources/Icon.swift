import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func color(_ value: UInt32) -> NSColor {
  NSColor(
    srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
    blue: CGFloat(value & 255) / 255, alpha: 1)
}
func polygon(_ points: [(CGFloat, CGFloat)], fill: NSColor) {
  let path = NSBezierPath()
  path.move(to: .init(x: points[0].0, y: points[0].1))
  for point in points.dropFirst() { path.line(to: .init(x: point.0, y: point.1)) }
  path.close()
  fill.setFill()
  path.fill()
}
for size in [16, 32, 128, 256, 512] {
  for multiplier in [1, 2] {
    let pixels = size * multiplier
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    graphics.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let square = NSBezierPath(
      roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 190, yRadius: 190)
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 25
    shadow.shadowOffset = .init(width: 0, height: -12)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.set()
    color(0xF2EEE4).setFill()
    square.fill()
    NSShadow().set()
    NSGradient(starting: color(0xFCFAF5), ending: color(0xE4DFD1))!.draw(in: square, angle: 270)
    polygon([(262, 630), (512, 775), (762, 630), (512, 485)], fill: color(0xEAA47E))
    polygon([(262, 630), (512, 485), (512, 200), (262, 345)], fill: color(0xC96543))
    polygon([(512, 485), (762, 630), (762, 345), (512, 200)], fill: color(0xA74C32))
    let seam = NSBezierPath()
    seam.move(to: .init(x: 512, y: 485))
    seam.line(to: .init(x: 512, y: 200))
    seam.lineWidth = 2
    color(0xF1C6AA).withAlphaComponent(0.35).setStroke()
    seam.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(size)x\(size)" + (multiplier == 2 ? "@2x" : "") + ".png"
    try rep.representation(using: .png, properties: [:])!.write(
      to: output.appendingPathComponent(name))
  }
}
