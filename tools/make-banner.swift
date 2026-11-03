// Draws docs/banner.png (title card for the README). Usage: swiftc tools/make-banner.swift -o /tmp/mb && /tmp/mb docs/banner.png
import AppKit
let W = 1600, H = 520
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGradient(colors: [NSColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1), NSColor(red: 0.40, green: 0.25, blue: 0.85, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -20)
if let sym = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 190, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))) {
    sym.draw(in: NSRect(x: 130, y: 150, width: 230, height: 230))
}
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat) {
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                               .foregroundColor: NSColor.white.withAlphaComponent(alpha)])
        .draw(at: NSPoint(x: 430, y: y))
}
text("STFUpdate", size: 120, weight: .bold, alpha: 1, y: 235)
text("Homebrew updates that wait a week before they land.", size: 44, weight: .regular, alpha: 0.88, y: 170)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
