import AppKit
import Foundation

enum IconError: Error {
    case bitmapUnavailable
    case pngUnavailable
    case iconutilFailed(Int32)
}

func drawIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw IconError.bitmapUnavailable }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 194, yRadius: 194)
    NSColor(srgbRed: 0.08, green: 0.15, blue: 0.25, alpha: 1).setFill()
    tile.fill()
    let inset = NSBezierPath(roundedRect: NSRect(x: 82, y: 82, width: 860, height: 860), xRadius: 192, yRadius: 192)
    NSColor(srgbRed: 0.28, green: 0.40, blue: 0.54, alpha: 0.45).setStroke()
    inset.lineWidth = 4
    inset.stroke()
    NSColor(srgbRed: 0.85, green: 0.96, blue: 1, alpha: 1).setStroke()
    let pipe = NSBezierPath()
    pipe.lineWidth = 62
    pipe.lineCapStyle = .round
    pipe.lineJoinStyle = .round
    pipe.move(to: NSPoint(x: 305, y: 355))
    pipe.line(to: NSPoint(x: 425, y: 355))
    pipe.line(to: NSPoint(x: 425, y: 669))
    pipe.line(to: NSPoint(x: 719, y: 669))
    pipe.stroke()
    for endpoint in [NSPoint(x: 274, y: 355), NSPoint(x: 750, y: 669)] {
        let ring = NSBezierPath(ovalIn: NSRect(x: endpoint.x - 62, y: endpoint.y - 62, width: 124, height: 124))
        NSColor(srgbRed: 0.08, green: 0.15, blue: 0.25, alpha: 1).setFill()
        ring.fill()
        ring.lineWidth = 38
        ring.stroke()
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw IconError.pngUnavailable }
    return png
}

func generateIcon() throws {
    let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "assets", isDirectory: true)
    let iconset = output.appendingPathComponent("PipeDesk.iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        try drawIcon(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
        try drawIcon(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
    try drawIcon(size: 1024).write(to: output.appendingPathComponent("PipeDesk.png"))
    let converter = Process()
    converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    converter.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("PipeDesk.icns").path]
    try converter.run()
    converter.waitUntilExit()
    guard converter.terminationStatus == 0 else { throw IconError.iconutilFailed(converter.terminationStatus) }
    try FileManager.default.removeItem(at: iconset)
}

do {
    try generateIcon()
} catch {
    FileHandle.standardError.write(Data("Icon generation failed: \(error)\n".utf8))
    exit(1)
}
