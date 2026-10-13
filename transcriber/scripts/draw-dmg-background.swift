import AppKit

// Finder uses points for layout. Include both resolutions in one TIFF so the
// background stays 640 × 360 points on standard and Retina displays.
let size = NSSize(width: 640, height: 360)
let output = CommandLine.arguments[1]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func label(_ text: String, top: CGFloat, font: NSFont, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (text as NSString).draw(in: NSRect(x: 32, y: top, width: 576, height: 40), withAttributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
    ])
}

var representations: [NSBitmapImageRep] = []
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = size
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    // bitmap.size already makes AppKit apply the pixel/point scale. Applying
    // scale again crops the Retina representation to its upper-left quadrant.
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)

    let bounds = NSRect(origin: .zero, size: size)
    NSGradient(starting: color(0.055, 0.075, 0.13), ending: color(0.085, 0.12, 0.20))!
        .draw(in: bounds, angle: 90)

    // Soft blue light echoes the app icon without competing with the two items.
    let glow = NSGradient(colors: [color(0.12, 0.38, 0.85, 0.22), color(0.12, 0.38, 0.85, 0)])!
    glow.draw(fromCenter: NSPoint(x: 175, y: 220), radius: 0,
              toCenter: NSPoint(x: 175, y: 220), radius: 260, options: [])

    label("Transcriber", top: 45, font: .systemFont(ofSize: 30, weight: .semibold),
          color: color(0.96, 0.97, 1))
    label("Перетащите приложение в папку «Программы»", top: 94,
          font: .systemFont(ofSize: 14), color: color(0.67, 0.74, 0.86))

    for center in [CGFloat(174), CGFloat(466)] {
        let plate = NSBezierPath(roundedRect: NSRect(x: center - 70, y: 160, width: 140, height: 150),
                                 xRadius: 24, yRadius: 24)
        color(0.65, 0.78, 1, 0.035).setFill()
        plate.fill()
        color(0.65, 0.78, 1, 0.10).setStroke()
        plate.lineWidth = 1
        plate.stroke()

        // Finder uses black filenames over a picture, even in dark appearance.
        // Give the real, selectable labels a light surface with enough contrast.
        // With 96-point icons and 13-point labels, the text is centered at y=288.
        color(0.78, 0.85, 0.96).setFill()
        NSBezierPath(roundedRect: NSRect(x: center - 64, y: 273, width: 128, height: 30),
                     xRadius: 14, yRadius: 14).fill()
    }

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 294, y: 222))
    arrow.line(to: NSPoint(x: 346, y: 222))
    arrow.move(to: NSPoint(x: 336, y: 212))
    arrow.line(to: NSPoint(x: 346, y: 222))
    arrow.line(to: NSPoint(x: 336, y: 232))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    color(0.44, 0.67, 0.98).setStroke()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    representations.append(bitmap)
}

let data = NSBitmapImageRep.tiffRepresentationOfImageReps(in: representations, using: .lzw, factor: 0)!
try data.write(to: URL(fileURLWithPath: output), options: .atomic)
