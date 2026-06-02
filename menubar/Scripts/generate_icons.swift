import AppKit
import CoreGraphics
import Foundation

let scriptURL = URL(fileURLWithPath: #filePath)
let menubarRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let resourcesURL = menubarRoot.appendingPathComponent("Resources", isDirectory: true)
let iconsetURL = resourcesURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)

try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)

        for index in 0..<elementCount {
            switch element(at: index, associatedPoints: &points) {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }

        return path
    }
}

func withBitmapContext(size: Int, draw: () -> Void) throws -> NSBitmapImageRep {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create bitmap"])
    }

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGenerator", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to encode PNG"])
    }

    try png.write(to: url)
}

func drawRoundedRect(_ rect: CGRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, strokeWidth: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()

    if let stroke {
        stroke.setStroke()
        path.lineWidth = strokeWidth
        path.stroke()
    }
}

func drawDockIcon(size: CGFloat) {
    let scale = size / 1024
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)

    NSColor.clear.setFill()
    canvas.fill()

    let base = CGRect(x: 102 * scale, y: 100 * scale, width: 820 * scale, height: 824 * scale)
    let basePath = NSBezierPath(roundedRect: base, xRadius: 188 * scale, yRadius: 188 * scale)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 34 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    shadow.set()

    NSGradient(colors: [
        NSColor(hex: 0xffffff),
        NSColor(hex: 0xf7f8fb),
        NSColor(hex: 0xebedf3)
    ])?.draw(in: basePath, angle: -78)

    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

    NSColor.black.withAlphaComponent(0.08).setStroke()
    basePath.lineWidth = 1.5 * scale
    basePath.stroke()

    NSGraphicsContext.current?.cgContext.saveGState()
    basePath.addClip()
    NSColor(hex: 0x5f7dff, alpha: 0.10).setFill()
    NSBezierPath(ovalIn: CGRect(x: 210 * scale, y: 238 * scale, width: 604 * scale, height: 516 * scale)).fill()
    NSColor.white.withAlphaComponent(0.72).setFill()
    NSBezierPath(ovalIn: CGRect(x: 190 * scale, y: 658 * scale, width: 642 * scale, height: 214 * scale)).fill()
    NSGraphicsContext.current?.cgContext.restoreGState()

    let backPod = NSBezierPath(roundedRect: CGRect(
        x: 286 * scale,
        y: 578 * scale,
        width: 454 * scale,
        height: 154 * scale
    ), xRadius: 77 * scale, yRadius: 77 * scale)
    let backShadow = NSShadow()
    backShadow.shadowColor = NSColor(hex: 0x5361ff, alpha: 0.18)
    backShadow.shadowBlurRadius = 18 * scale
    backShadow.shadowOffset = NSSize(width: 0, height: -7 * scale)
    backShadow.set()
    NSGradient(colors: [
        NSColor(hex: 0xded9ff),
        NSColor(hex: 0x93a8ff),
        NSColor(hex: 0x6179ff)
    ])?.draw(in: backPod, angle: 12)
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
    NSColor.white.withAlphaComponent(0.52).setStroke()
    backPod.lineWidth = 2 * scale
    backPod.stroke()

    let mainPod = NSBezierPath(roundedRect: CGRect(
        x: 184 * scale,
        y: 294 * scale,
        width: 656 * scale,
        height: 390 * scale
    ), xRadius: 118 * scale, yRadius: 118 * scale)
    let podShadow = NSShadow()
    podShadow.shadowColor = NSColor(hex: 0x2536c7, alpha: 0.26)
    podShadow.shadowBlurRadius = 28 * scale
    podShadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    podShadow.set()
    NSGradient(colorsAndLocations:
        (NSColor(hex: 0x9edbff), 0.00),
        (NSColor(hex: 0x638cff), 0.34),
        (NSColor(hex: 0x4357ff), 0.66),
        (NSColor(hex: 0x5c35f2), 1.00)
    )?.draw(in: mainPod, angle: 48)
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

    NSGraphicsContext.current?.cgContext.saveGState()
    mainPod.addClip()
    NSColor.white.withAlphaComponent(0.20).setFill()
    NSBezierPath(ovalIn: CGRect(x: 240 * scale, y: 544 * scale, width: 548 * scale, height: 150 * scale)).fill()
    NSColor(hex: 0x63fff0, alpha: 0.14).setFill()
    NSBezierPath(ovalIn: CGRect(x: 224 * scale, y: 296 * scale, width: 260 * scale, height: 208 * scale)).fill()
    NSGraphicsContext.current?.cgContext.restoreGState()

    NSColor(hex: 0x263fff, alpha: 0.32).setStroke()
    mainPod.lineWidth = 5 * scale
    mainPod.stroke()
    NSColor.white.withAlphaComponent(0.42).setStroke()
    mainPod.lineWidth = 2 * scale
    mainPod.stroke()

    let nodeFill = NSColor.white.withAlphaComponent(0.92)
    for x in [640, 696] {
        nodeFill.setFill()
        NSBezierPath(ovalIn: CGRect(x: CGFloat(x) * scale, y: 592 * scale, width: 28 * scale, height: 28 * scale)).fill()
    }

    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor(hex: 0x17218f, alpha: 0.28)
    glyphShadow.shadowBlurRadius = 8 * scale
    glyphShadow.shadowOffset = NSSize(width: 0, height: -3 * scale)
    glyphShadow.set()

    let font = NSFont.systemFont(ofSize: 250 * scale, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(hex: 0xf6f9ff)
    ]
    let mark = NSAttributedString(string: "cx", attributes: attrs)
    let markSize = mark.size()
    mark.draw(at: NSPoint(x: 286 * scale, y: 354 * scale + ((226 * scale - markSize.height) / 2)))

    let cursor = NSBezierPath(roundedRect: CGRect(
        x: 652 * scale,
        y: 374 * scale,
        width: 92 * scale,
        height: 42 * scale
    ), xRadius: 21 * scale, yRadius: 21 * scale)
    NSColor(hex: 0xf6f9ff).setFill()
    cursor.fill()

    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
}

func drawMenuBarIcon(in rect: CGRect, color: NSColor) {
    let scale = min(rect.width, rect.height) / 18

    let pod = NSBezierPath(roundedRect: CGRect(
        x: rect.minX + 2.65 * scale,
        y: rect.minY + 4.45 * scale,
        width: 12.7 * scale,
        height: 9.1 * scale
    ), xRadius: 2.9 * scale, yRadius: 2.9 * scale)
    color.setStroke()
    pod.lineWidth = 1.55 * scale
    pod.stroke()

    let prompt = NSBezierPath()
    prompt.move(to: NSPoint(x: rect.minX + 6.05 * scale, y: rect.minY + 7.0 * scale))
    prompt.line(to: NSPoint(x: rect.minX + 8.2 * scale, y: rect.minY + 9.0 * scale))
    prompt.line(to: NSPoint(x: rect.minX + 6.05 * scale, y: rect.minY + 11.0 * scale))
    prompt.lineCapStyle = .round
    prompt.lineJoinStyle = .round
    prompt.lineWidth = 1.65 * scale
    prompt.stroke()

    let cursor = NSBezierPath(roundedRect: CGRect(
        x: rect.minX + 9.65 * scale,
        y: rect.minY + 6.85 * scale,
        width: 2.9 * scale,
        height: 1.45 * scale
    ), xRadius: 0.72 * scale, yRadius: 0.72 * scale)
    color.setFill()
    cursor.fill()
}

func writeMenuBarPDF(to url: URL) throws {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 18, height: 18)

    guard
        let consumer = CGDataConsumer(data: data),
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
        throw NSError(domain: "IconGenerator", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to create PDF context"])
    }

    context.beginPDFPage(nil)
    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    drawMenuBarIcon(in: mediaBox, color: .black)
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()

    try data.write(to: url)
}

let iconSpecs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in iconSpecs {
    let image = try withBitmapContext(size: Int(size)) {
        drawDockIcon(size: size)
    }
    try writePNG(image, to: iconsetURL.appendingPathComponent(name))
}

let preview = try withBitmapContext(size: 1024) {
    drawDockIcon(size: 1024)
}
try writePNG(preview, to: resourcesURL.appendingPathComponent("AppIcon.png"))
try writeMenuBarPDF(to: resourcesURL.appendingPathComponent("MenuBarIcon.pdf"))

print("Generated icons in \(resourcesURL.path)")
