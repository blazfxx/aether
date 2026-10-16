// Renders Aether's app icon into an .iconset directory.
// Usage: swift Scripts/make_icon.swift <output.iconset>
import AppKit

guard CommandLine.arguments.count == 2 else { print("usage: make_icon <out.iconset>"); exit(1) }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: artwork inset ~10% with continuous-corner squircle.
    let inset = s * 0.098
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); path.fill()
    ctx.restoreGState()

    ctx.saveGState()
    path.addClip()
    let colors = [NSColor(red: 0.36, green: 0.30, blue: 0.95, alpha: 1).cgColor,
                  NSColor(red: 0.80, green: 0.33, blue: 0.88, alpha: 1).cgColor,
                  NSColor(red: 0.99, green: 0.48, blue: 0.45, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // soft top highlight
    let hi = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(hi, start: CGPoint(x: s / 2, y: rect.maxY), end: CGPoint(x: s / 2, y: rect.midY), options: [])
    ctx.restoreGState()

    // Sparkle glyph
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r)
            NSColor.white.setFill()
            r.fill(using: .sourceIn)
            return true
        }
        let g = tinted.size
        let dr = CGRect(x: (s - g.width) / 2, y: (s - g.height) / 2, width: g.width, height: g.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        tinted.draw(in: dr)
        ctx.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(pixels: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote \(out.path)")
