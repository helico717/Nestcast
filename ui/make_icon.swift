// Renders the Nestcast app icon (simple, quiet): a soft light-gray tile with
// a slate speaker and two sound waves. Writes an .iconset for iconutil.
// usage: swift make_icon.swift <out.iconset>
import AppKit

func render(_ px: Int) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let ctx = NSGraphicsContext.current!.cgContext
  let s = CGFloat(px) / 1024.0
  ctx.scaleBy(x: s, y: s)

  // macOS icon grid: 824x824 tile centred in 1024, corner radius ~185.
  let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
  let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
  // Soft shadow under the tile.
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
                color: NSColor(white: 0, alpha: 0.18).cgColor)
  ctx.addPath(tilePath)
  ctx.setFillColor(NSColor(white: 0.95, alpha: 1).cgColor)
  ctx.fillPath()
  ctx.restoreGState()
  // Very subtle vertical gradient.
  ctx.saveGState()
  ctx.addPath(tilePath)
  ctx.clip()
  let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.975, green: 0.978, blue: 0.983, alpha: 1).cgColor,
    NSColor(red: 0.885, green: 0.897, blue: 0.913, alpha: 1).cgColor,
  ] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
  ctx.restoreGState()

  let slate = NSColor(red: 0.24, green: 0.28, blue: 0.34, alpha: 1).cgColor
  ctx.setFillColor(slate)
  ctx.setStrokeColor(slate)

  // Speaker: small rounded box + cone, slightly left of centre.
  let cx: CGFloat = 430, cy: CGFloat = 512
  let box = CGRect(x: cx - 150, y: cy - 62, width: 92, height: 124)
  ctx.addPath(CGPath(roundedRect: box, cornerWidth: 22, cornerHeight: 22, transform: nil))
  ctx.fillPath()
  let cone = CGMutablePath()
  cone.move(to: CGPoint(x: cx - 72, y: cy - 62))
  cone.addLine(to: CGPoint(x: cx + 30, y: cy - 165))
  cone.addQuadCurve(to: CGPoint(x: cx + 52, y: cy - 150), control: CGPoint(x: cx + 50, y: cy - 172))
  cone.addLine(to: CGPoint(x: cx + 52, y: cy + 150))
  cone.addQuadCurve(to: CGPoint(x: cx + 30, y: cy + 165), control: CGPoint(x: cx + 50, y: cy + 172))
  cone.addLine(to: CGPoint(x: cx - 72, y: cy + 62))
  cone.closeSubpath()
  ctx.addPath(cone)
  ctx.fillPath()

  // Two waves, rounded caps, the outer one lighter.
  ctx.setLineCap(.round)
  ctx.setLineWidth(40)
  for (i, r) in [CGFloat(120), 215].enumerated() {
    ctx.setStrokeColor(NSColor(red: 0.24, green: 0.28, blue: 0.34, alpha: i == 0 ? 1 : 0.55).cgColor)
    ctx.addArc(center: CGPoint(x: cx + 60, y: cy), radius: r,
               startAngle: -.pi / 4.2, endAngle: .pi / 4.2, clockwise: false)
    ctx.strokePath()
  }
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                   ("128x128", 128), ("128x128@2x", 256), ("256x256", 256),
                   ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
  let data = render(px).representation(using: .png, properties: [:])!
  try! data.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
