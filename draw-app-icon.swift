import Cocoa

// draw-app-icon <out.png>
// Draws the app's own 1024x1024 icon: a macOS-style rounded square with a deep
// night-blue gradient and two overlapping speech bubbles -- one chat app,
// several accounts. Independent of the workspace logos.

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: draw-app-icon <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let S: CGFloat = 1024

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// A speech bubble: rounded body plus a short, rounded tail at a bottom corner.
func bubble(_ r: NSRect, radius: CGFloat, tailLeft: Bool) -> NSBezierPath {
    let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    // Built for the left side, mirrored for the right.
    let sx: CGFloat = tailLeft ? 1 : -1
    let ox = tailLeft ? r.minX : r.maxX
    func pt(_ dx: CGFloat, _ dy: CGFloat) -> NSPoint { NSPoint(x: ox + sx * dx, y: r.minY + dy) }
    let W = r.width, H = r.height
    // Starts inside the rounded corner, so the tail grows out of it seamlessly.
    let tail = NSBezierPath()
    tail.move(to: pt(W * 0.08, H * 0.20))
    tail.curve(to: pt(W * 0.0, H * -0.12),
               controlPoint1: pt(W * 0.08, H * 0.02), controlPoint2: pt(W * 0.06, H * -0.07))
    tail.curve(to: pt(W * 0.34, H * 0.0),
               controlPoint1: pt(W * 0.14, H * -0.10), controlPoint2: pt(W * 0.26, H * -0.04))
    tail.line(to: pt(W * 0.30, H * 0.20))
    tail.close()
    // Mirroring flips the winding; reverse it back so the overlap fills.
    p.append(tailLeft ? tail : tail.reversed)
    p.windingRule = .nonZero
    return p
}

// --- Rounded-square body on the standard macOS icon grid (824pt, 100pt margin).
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor(white: 0, alpha: 0.35).cgColor)
rgb(0x14163A).setFill()
bodyPath.fill()
ctx.restoreGState()

ctx.saveGState()
bodyPath.addClip()
NSGradient(colorsAndLocations:
    (rgb(0x3B3F9E), 0.0), (rgb(0x23266B), 0.55), (rgb(0x12143A), 1.0))!
    .draw(in: body, angle: -60)
// Soft glow, top-left, so the surface reads as lit rather than flat.
NSGradient(colors: [rgb(0x8C9BFF, 0.22), rgb(0x8C9BFF, 0)])!
    .draw(fromCenter: NSPoint(x: 300, y: 820), radius: 0,
          toCenter: NSPoint(x: 300, y: 820), radius: 560, options: [])
ctx.restoreGState()

// Hairline inner edge.
let edge = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
edge.lineWidth = 4
NSGradient(colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0.02)])!.draw(in: edge, angle: -90)
rgb(0xFFFFFF, 0.10).setStroke()
edge.stroke()

// --- Back bubble: the "other account", a luminous teal, up and to the right.
let back = NSRect(x: 412, y: 470, width: 400, height: 300)
let backPath = bubble(back, radius: 120, tailLeft: false)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor(white: 0, alpha: 0.25).cgColor)
rgb(0x2DD4BF).setFill()
backPath.fill()
ctx.restoreGState()
ctx.saveGState()
backPath.addClip()
NSGradient(colors: [rgb(0x7AF0DA), rgb(0x14B8A6)])!.draw(in: back.insetBy(dx: -60, dy: -60), angle: -90)
ctx.restoreGState()

// --- Front bubble: white, down and to the left, overlapping the back one.
let front = NSRect(x: 214, y: 290, width: 470, height: 350)
let frontPath = bubble(front, radius: 140, tailLeft: true)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40, color: NSColor(white: 0, alpha: 0.38).cgColor)
rgb(0xFFFFFF).setFill()
frontPath.fill()
ctx.restoreGState()
ctx.saveGState()
frontPath.addClip()
NSGradient(colors: [rgb(0xFFFFFF), rgb(0xE4E8FF)])!.draw(in: front.insetBy(dx: -60, dy: -60), angle: -90)
ctx.restoreGState()

// Typing dots in the front bubble.
let dotR: CGFloat = 30, gap: CGFloat = 46
let cy = front.midY + 6
for i in -1...1 {
    let cx = front.midX + CGFloat(i) * (2 * dotR + gap)
    let d = NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: cy - dotR, width: 2 * dotR, height: 2 * dotR))
    (i == 1 ? rgb(0x14B8A6) : rgb(0x2B2F7A)).setFill()
    d.fill()
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: args[1])) } catch { exit(1) }
