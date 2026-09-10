import AppKit

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: generate-app-icons.swift <source.png> <output-directory>\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    fputs("Unable to read source image.\n", stderr)
    exit(1)
}

let outputs: [(String, Int)] = [
    ("AppIcon-16.png", 16),
    ("AppIcon-16@2x.png", 32),
    ("AppIcon-32.png", 32),
    ("AppIcon-32@2x.png", 64),
    ("AppIcon-128.png", 128),
    ("AppIcon-128@2x.png", 256),
    ("AppIcon-256.png", 256),
    ("AppIcon-256@2x.png", 512),
    ("AppIcon-512.png", 512),
    ("AppIcon-512@2x.png", 1_024),
]

func squircle(in rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    let exponent = 5.0
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let radiusX = rect.width / 2
    let radiusY = rect.height / 2

    for index in 0...256 {
        let angle = Double(index) / 256 * 2 * Double.pi
        let cosine = cos(angle)
        let sine = sin(angle)
        let point = NSPoint(
            x: center.x + radiusX * copysign(pow(abs(cosine), 2 / exponent), cosine),
            y: center.y + radiusY * copysign(pow(abs(sine), 2 / exponent), sine)
        )
        if index == 0 {
            path.move(to: point)
        } else {
            path.line(to: point)
        }
    }
    path.close()
    return path
}

try FileManager.default.createDirectory(
    at: outputURL,
    withIntermediateDirectories: true
)

for (filename, pixels) in outputs {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("Unable to allocate \(pixels)x\(pixels) bitmap.\n", stderr)
        exit(1)
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
    squircle(in: NSRect(x: 0, y: 0, width: pixels, height: pixels)).addClip()
    sourceImage.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Unable to encode \(filename).\n", stderr)
        exit(1)
    }
    try data.write(to: outputURL.appendingPathComponent(filename))
}
