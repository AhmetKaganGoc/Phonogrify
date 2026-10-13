// Draws the app icon at every size macOS asks for, into the folder given.
//   swift Scripts/make-icon.swift <folder.iconset>
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func icon(side: Int) -> Data? {
    guard let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let size = Double(side)
    let green = CGColor(srgbRed: 0.114, green: 0.725, blue: 0.329, alpha: 1)

    // A black tile with the system's usual margin and rounding.
    let inset = size * 0.1
    let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    context.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil))
    context.setFillColor(CGColor(gray: 0.07, alpha: 1))
    context.fillPath()

    // A cord from the top of the tile down to a record.
    let centre = CGPoint(x: size / 2, y: size * 0.4)
    let radius = size * 0.2
    context.setStrokeColor(CGColor(gray: 0.93, alpha: 1))
    context.setLineWidth(max(1, size * 0.018))
    context.setLineCap(.round)
    context.move(to: CGPoint(x: size / 2, y: tile.maxY))
    context.addLine(to: CGPoint(x: size / 2, y: centre.y + radius))
    context.strokePath()

    func circle(_ r: Double) -> CGRect { CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2) }
    context.setFillColor(green)
    context.fillEllipse(in: circle(radius))
    context.setStrokeColor(CGColor(gray: 0, alpha: 0.25))
    context.setLineWidth(max(0.5, size * 0.006))
    for groove in [0.82, 0.66, 0.5] { context.strokeEllipse(in: circle(radius * groove)) }
    context.setFillColor(CGColor(gray: 0.07, alpha: 1))
    context.fillEllipse(in: circle(radius * 0.3))
    context.setFillColor(CGColor(gray: 0.93, alpha: 1))
    context.fillEllipse(in: circle(radius * 0.08))

    // The ring that turns while a track plays: an open arc round the record.
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
    context.setLineWidth(max(1, size * 0.012))
    context.addArc(center: centre, radius: radius * 1.3, startAngle: .pi * 0.15, endAngle: .pi * 1.25, clockwise: false)
    context.strokePath()

    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try icon(side: points * scale)?.write(to: folder.appendingPathComponent(name))
    }
}
