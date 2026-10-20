// Renders the Nestcast app icon (simple, quiet): a soft light-gray tile with
// a slate "casting" motif (screen outline + broadcast arcs) and a sound wave. Writes an .iconset for iconutil.
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

  let slate = NSColor(red: 0.24, green: 0.28, blue: 0.34, alpha: 1)
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)

  // "Casting" motif: a rounded screen outline whose lower-left corner is
  // replaced by broadcast arcs (drawn here, not a copy of any brand logo),
  // with a small sound wave inside so it reads as audio.
  let frame = CGRect(x: 270, y: 330, width: 500, height: 380)
  let r: CGFloat = 44
  let gap: CGFloat = 150  // How much of the lower-left corner is left open.
  ctx.setStrokeColor(slate.cgColor)
  ctx.setLineWidth(34)
  let outline = CGMutablePath()
  outline.move(to: CGPoint(x: frame.minX, y: frame.minY + gap))
  outline.addLine(to: CGPoint(x: frame.minX, y: frame.maxY - r))
  outline.addArc(tangent1End: CGPoint(x: frame.minX, y: frame.maxY), tangent2End: CGPoint(x: frame.minX + r, y: frame.maxY), radius: r)
  outline.addLine(to: CGPoint(x: frame.maxX - r, y: frame.maxY))
  outline.addArc(tangent1End: CGPoint(x: frame.maxX, y: frame.maxY), tangent2End: CGPoint(x: frame.maxX, y: frame.maxY - r), radius: r)
  outline.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + r))
  outline.addArc(tangent1End: CGPoint(x: frame.maxX, y: frame.minY), tangent2End: CGPoint(x: frame.maxX - r, y: frame.minY), radius: r)
  outline.addLine(to: CGPoint(x: frame.minX + gap, y: frame.minY))
  ctx.addPath(outline)
  ctx.strokePath()

  // Broadcast arcs from the open corner.
  let origin = CGPoint(x: frame.minX - 18, y: frame.minY - 18)
  ctx.setFillColor(slate.cgColor)
  ctx.fillEllipse(in: CGRect(x: origin.x - 24, y: origin.y - 24, width: 48, height: 48))
  for (i, rad) in [CGFloat(92), 156].enumerated() {
    ctx.setStrokeColor(slate.withAlphaComponent(i == 0 ? 1 : 0.75).cgColor)
    ctx.addArc(center: origin, radius: rad, startAngle: 0.06, endAngle: .pi / 2 - 0.06, clockwise: false)
    ctx.strokePath()
  }

  // Sound wave inside the screen (audio, not video).
  ctx.setStrokeColor(slate.withAlphaComponent(0.55).cgColor)
  ctx.setLineWidth(26)
  let bars: [CGFloat] = [70, 150, 110, 190, 90]
  for (i, h) in bars.enumerated() {
    let x = frame.minX + 150 + CGFloat(i) * 52
    let midY = frame.midY + 20
    ctx.move(to: CGPoint(x: x, y: midY - h / 2))
    ctx.addLine(to: CGPoint(x: x, y: midY + h / 2))
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
