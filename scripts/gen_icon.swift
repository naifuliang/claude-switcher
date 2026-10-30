// Draws the app icon into an .iconset directory:
//   swift gen_icon.swift <out.iconset> [preview.png]
//
// A toggle switch on a terracotta tile: the faint person on the left is the
// claude.ai account, the knob slid to the right carries a key (API mode).
import AppKit

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Draws an SF Symbol tinted with `color`, centred in `rect`.
func symbol(_ name: String, in rect: NSRect, color: NSColor, weight: NSFont.Weight) {
    let cfg = NSImage.SymbolConfiguration(pointSize: rect.height, weight: weight)
        .applying(.init(paletteColors: [color]))
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    else { return }
    let s = img.size
    let k = min(rect.width / s.width, rect.height / s.height)
    let w = s.width * k, h = s.height * k
    img.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    // Work in a 1024 canvas (Apple's macOS icon grid) and scale down.
    let k = CGFloat(px) / 1024
    cg.scaleBy(x: k, y: k)

    // Tile: 824pt squircle with the standard drop shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.30).cgColor)
    rgb(0xC8603F).setFill()
    tilePath.fill()
    cg.restoreGState()

    cg.saveGState()
    tilePath.addClip()
    NSGradient(colors: [rgb(0xEA8A68), rgb(0xD96E4C), rgb(0xB9502F)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -90)
    // Soft top highlight.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    cg.restoreGState()

    // Track.
    let track = NSRect(x: 196, y: 362, width: 632, height: 300)
    let trackPath = NSBezierPath(roundedRect: track, xRadius: 150, yRadius: 150)
    rgb(0x7A2E17, 0.42).setFill()
    trackPath.fill()
    // Inner shadow along the top edge of the track.
    cg.saveGState()
    trackPath.addClip()
    let inner = NSBezierPath(rect: track.insetBy(dx: -60, dy: -60))
    inner.append(trackPath.reversed)
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    rgb(0x000000).setFill()
    inner.fill()
    cg.restoreGState()
    // Thin light rim at the bottom so the track reads as recessed.
    rgb(0xFFFFFF, 0.18).setStroke()
    let rim = NSBezierPath(roundedRect: track.insetBy(dx: 1.5, dy: 1.5), xRadius: 148, yRadius: 148)
    rim.lineWidth = 3
    rim.stroke()

    // The "account" side, dimmed.
    symbol("person.fill", in: NSRect(x: 262, y: 432, width: 168, height: 160),
           color: rgb(0xFFF4EA, 0.55), weight: .semibold)

    // Knob on the right, with a soft cast shadow.
    let knob = NSRect(x: 538, y: 382, width: 260, height: 260)
    let knobPath = NSBezierPath(ovalIn: knob)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.38).cgColor)
    rgb(0xFFF8F1).setFill()
    knobPath.fill()
    cg.restoreGState()
    cg.saveGState()
    knobPath.addClip()
    NSGradient(colors: [rgb(0xFFFFFF), rgb(0xF6E7D8)])!.draw(in: knob, angle: -90)
    cg.restoreGState()

    // The "API" side: a key on the knob.
    symbol("key.horizontal.fill", in: NSRect(x: knob.minX + 40, y: knob.minY + 58, width: 180, height: 144),
           color: rgb(0xC8583A), weight: .bold)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if args.count > 2 { try! render(1024).write(to: URL(fileURLWithPath: args[2])) }
