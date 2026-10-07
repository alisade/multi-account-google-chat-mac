import Cocoa

// compose-icon <out.png> <logo.png> [logo.png ...]
// Composite workspace logos onto one rounded light card for the combined
// multi-workspace app's icon: one logo fills the card, two stack vertically,
// three or more go in a grid. Renders offscreen to a 1024x1024 PNG.

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: compose-icon <out.png> <logo.png> [logo.png ...]\n".data(using: .utf8)!)
    exit(2)
}
let outPath = args[1]
let logos = args.dropFirst(2).map { NSImage(contentsOfFile: $0) }
let S = 1024

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    FileHandle.standardError.write("could not create bitmap\n".data(using: .utf8)!)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Transparent background.
NSColor.clear.set()
NSRect(x: 0, y: 0, width: S, height: S).fill()

// Rounded light card so the two logos read as one icon.
let inset: CGFloat = 40
let card = NSRect(x: inset, y: inset, width: CGFloat(S) - 2 * inset, height: CGFloat(S) - 2 * inset)
NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.97, alpha: 1).set()
NSBezierPath(roundedRect: card, xRadius: 180, yRadius: 180).fill()

func drawFit(_ img: NSImage?, into rect: NSRect, scale frac: CGFloat) {
    guard let img = img else { return }
    let s = img.size
    guard s.width > 0, s.height > 0 else { return }
    let k = min(rect.width / s.width, rect.height / s.height) * frac
    let w = s.width * k, h = s.height * k
    let r = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
}

// Rows/cols: 1 -> 1x1, 2 -> 2 rows x 1 col, 3+ -> near-square grid.
let n = logos.count
let cols = n <= 2 ? 1 : Int(ceil(sqrt(Double(n))))
let rows = Int(ceil(Double(n) / Double(cols)))
let cellW = card.width / CGFloat(cols), cellH = card.height / CGFloat(rows)
let frac: CGFloat = n == 1 ? 0.75 : 0.66
for (i, img) in logos.enumerated() {
    let r = i / cols, c = i % cols
    // Row 0 is the top of the card (AppKit y grows upward).
    let cell = NSRect(x: card.minX + CGFloat(c) * cellW,
                      y: card.maxY - CGFloat(r + 1) * cellH,
                      width: cellW, height: cellH)
    drawFit(img, into: cell, scale: frac)
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("could not encode png\n".data(using: .utf8)!)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
