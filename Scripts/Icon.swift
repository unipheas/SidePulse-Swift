import AppKit

// Render the master at 1024 points. All iconset sizes are resampled from this artwork.
let canvas = NSSize(width: 1024, height: 1024)
let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
func ink(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
  NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let tile = NSBezierPath(
  roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872), xRadius: 192, yRadius: 192)
NSGradient(starting: ink(0.12, 0.21, 0.25), ending: ink(0.025, 0.045, 0.067))!.draw(
  in: tile, angle: -80)
ink(0.28, 0.38, 0.40).setStroke()
tile.lineWidth = 4
tile.stroke()
ctx.saveGState()
ctx.translateBy(x: 512, y: 508)
ctx.rotate(by: 10 * .pi / 180)
ctx.translateBy(x: -512, y: -508)
let card = NSBezierPath()
card.move(to: NSPoint(x: 300, y: 279))
card.line(to: NSPoint(x: 300, y: 679))
card.line(to: NSPoint(x: 395, y: 779))
card.line(to: NSPoint(x: 690, y: 779))
card.curve(
  to: NSPoint(x: 720, y: 749), controlPoint1: NSPoint(x: 714, y: 779),
  controlPoint2: NSPoint(x: 720, y: 771))
card.line(to: NSPoint(x: 720, y: 279))
card.curve(
  to: NSPoint(x: 694, y: 251), controlPoint1: NSPoint(x: 720, y: 260),
  controlPoint2: NSPoint(x: 712, y: 251))
card.line(to: NSPoint(x: 326, y: 251))
card.curve(
  to: NSPoint(x: 300, y: 279), controlPoint1: NSPoint(x: 309, y: 251),
  controlPoint2: NSPoint(x: 300, y: 259))
card.close()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 24, color: ink(0, 0, 0, 0.75).cgColor)
NSGradient(starting: ink(0.32, 0.39, 0.42), ending: ink(0.065, 0.105, 0.13))!.draw(
  in: card, angle: -80)
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ink(0.58, 0.68, 0.69).setStroke()
card.lineWidth = 5
card.stroke()
for i in 0..<7 {
  ink(0.83, 0.68, 0.37).setFill()
  NSBezierPath(
    roundedRect: NSRect(x: 407 + i * 42, y: 669, width: 23, height: 84), xRadius: 6, yRadius: 6
  ).fill()
}
let panel = NSBezierPath(
  roundedRect: NSRect(x: 328, y: 303, width: 364, height: 280), xRadius: 19, yRadius: 19)
ink(0.035, 0.075, 0.09).setFill()
panel.fill()
let wave = NSBezierPath()
for (i, point) in [
  (350, 440), (407, 440), (445, 480), (480, 387), (528, 518), (572, 415), (602, 440), (671, 440),
].enumerated() {
  let p = NSPoint(x: point.0, y: point.1)
  if i == 0 { wave.move(to: p) } else { wave.line(to: p) }
}
wave.lineWidth = 14
wave.lineJoinStyle = .round
wave.lineCapStyle = .round
ctx.setShadow(offset: .zero, blur: 18, color: ink(0, 0.88, 0.74).cgColor)
ink(0.33, 1, 0.81).setStroke()
wave.stroke()
for i in 0..<8 {
  ink(0.23, 0.92, 0.77, 0.45 + Double(i % 4) * 0.15).setFill()
  NSBezierPath(
    roundedRect: NSRect(x: 338 + 44 * i, y: 269, width: 27, height: 12), xRadius: 5, yRadius: 5
  ).fill()
}
ctx.restoreGState()
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(
  to: URL(fileURLWithPath: CommandLine.arguments[1]))
