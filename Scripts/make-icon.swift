import AppKit
import CoreGraphics

enum Palette {
    static let inkTop = CGColor(srgbRed: 0.145, green: 0.165, blue: 0.220, alpha: 1)
    static let inkBottom = CGColor(srgbRed: 0.043, green: 0.055, blue: 0.082, alpha: 1)
    static let good = CGColor(srgbRed: 0.25, green: 0.86, blue: 0.54, alpha: 1)
    static let traceStart = CGColor(gray: 1, alpha: 0.97)
    static let traceMid = CGColor(srgbRed: 0.93, green: 0.96, blue: 1.0, alpha: 1)
    static let traceEnd = CGColor(srgbRed: 0.72, green: 0.96, blue: 0.83, alpha: 1)
}

enum Geometry {
    static let canvas: CGFloat = 1024
    static let tileHalf: CGFloat = 412
    static let tileExponent: CGFloat = 5
    static let strokeWidth: CGFloat = 60
    static let cornerRadius: CGFloat = 16
    static let dotRadius: CGFloat = 40
    static let thresholdY: CGFloat = 372
    static let trace = [
        CGPoint(x: 298, y: 728), CGPoint(x: 298, y: 296),
        CGPoint(x: 698, y: 728), CGPoint(x: 698, y: 296),
    ]
}

func superellipse(center: CGPoint, half: CGFloat, exponent n: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = center.x + half * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = center.y + half * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func roundedPolyline(_ points: [CGPoint], radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: points[0])
    for i in 1..<points.count - 1 {
        path.addArc(tangent1End: points[i], tangent2End: points[i + 1], radius: radius)
    }
    path.addLine(to: points[points.count - 1])
    return path
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: stops.map { $0.0 } as CFArray,
        locations: stops.map { $0.1 }
    )!
}

func ring(_ ctx: CGContext, at p: CGPoint, radius: CGFloat, width: CGFloat, alpha: CGFloat) {
    ctx.setStrokeColor(Palette.good.copy(alpha: alpha)!)
    ctx.setLineWidth(width)
    ctx.strokeEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
}

func render(px: Int) -> Data {
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let s = CGFloat(px) / Geometry.canvas
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: 0, y: Geometry.canvas)
    ctx.scaleBy(x: 1, y: -1)

    let mid = Geometry.canvas / 2
    let tile = superellipse(center: CGPoint(x: mid, y: mid), half: Geometry.tileHalf, exponent: Geometry.tileExponent)
    let top = mid - Geometry.tileHalf, bottom = mid + Geometry.tileHalf

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 30 * s, color: CGColor(gray: 0, alpha: 0.38))
    ctx.addPath(tile)
    ctx.setFillColor(Palette.inkBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()

    ctx.drawLinearGradient(
        gradient([(Palette.inkTop, 0), (Palette.inkBottom, 1)]),
        start: CGPoint(x: mid, y: top), end: CGPoint(x: mid, y: bottom), options: []
    )
    let glow = CGPoint(x: 700, y: 330)
    ctx.drawRadialGradient(
        gradient([(Palette.good.copy(alpha: 0.10)!, 0), (Palette.good.copy(alpha: 0)!, 1)]),
        startCenter: glow, startRadius: 0, endCenter: glow, endRadius: 460, options: []
    )

    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.07))
    ctx.setLineWidth(3)
    ctx.setLineDash(phase: 0, lengths: [10, 14])
    ctx.move(to: CGPoint(x: top, y: Geometry.thresholdY))
    ctx.addLine(to: CGPoint(x: bottom, y: Geometry.thresholdY))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    let center = roundedPolyline(Geometry.trace, radius: Geometry.cornerRadius)
    let outline = center.copy(
        strokingWithWidth: Geometry.strokeWidth, lineCap: .round, lineJoin: .round, miterLimit: 10
    )

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60 * s, color: Palette.good.copy(alpha: 0.30)!)
    ctx.addPath(center.copy(
        strokingWithWidth: Geometry.strokeWidth - 10, lineCap: .round, lineJoin: .round, miterLimit: 10
    ))
    ctx.setFillColor(Palette.good)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(Palette.traceStart, 0), (Palette.traceMid, 0.55), (Palette.traceEnd, 1)]),
        start: CGPoint(x: 298, y: 740), end: CGPoint(x: 698, y: 290),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    let end = Geometry.trace[Geometry.trace.count - 1]
    ring(ctx, at: end, radius: 76, width: 6, alpha: 0.42)
    ring(ctx, at: end, radius: 116, width: 5, alpha: 0.16)
    ctx.setFillColor(Palette.good)
    let r = Geometry.dotRadius
    ctx.fillEllipse(in: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2))

    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile.copy(strokingWithWidth: 5, lineCap: .butt, lineJoin: .round, miterLimit: 10))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(CGColor(gray: 1, alpha: 0.28), 0), (CGColor(gray: 1, alpha: 0), 0.5)]),
        start: CGPoint(x: mid, y: top), end: CGPoint(x: mid, y: bottom), options: []
    )
    ctx.restoreGState()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output .iconset directory>\n".utf8))
    exit(1)
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try render(px: px).write(to: dir.appendingPathComponent("\(name).png"))
}
