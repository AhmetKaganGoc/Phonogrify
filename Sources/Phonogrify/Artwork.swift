import AppKit
import ImageIO
import PhonogrifyCore

/// Fetches album covers, and keeps the last few in memory and on disk.
///
/// The one thing Phonogrify ever asks the network for: a cover, once per album,
/// from the address Spotify itself gave, and only if that address is on
/// Spotify's image servers.
actor CoverStore {
    private var memory: [String: CGImage] = [:]
    private var order: [String] = []
    private let folder: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        folder = caches.appendingPathComponent("Phonogrify/Covers", isDirectory: true)
    }

    func cover(for track: Track) async -> CGImage? {
        guard let url = track.artworkURL, Self.isAllowed(url) else { return nil }
        let key = url.absoluteString
        if let known = memory[key] { return known }

        let file = folder.appendingPathComponent(Self.fileName(for: key))
        var data = try? Data(contentsOf: file)
        if data == nil, let fetched = await Self.download(url) {
            data = fetched
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fetched.write(to: file, options: .atomic)
            prune()
        }
        guard let data, let image = Self.decode(data) else { return nil }

        memory[key] = image
        order.append(key)
        if order.count > 12 {
            memory[order.removeFirst()] = nil
        }
        return image
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return ["scdn.co", "spotifycdn.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func download(_ url: URL) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 4 * 1024 * 1024
        else { return nil }
        return data
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Keeps the sixty newest covers on disk.
    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys),
              files.count > 60
        else { return }
        let dated = files.map { file -> (URL, Date) in
            (file, (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - 60) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func fileName(for key: String) -> String {
        String(Hashing.fnv(key), radix: 16) + ".img"
    }
}

enum Hashing {
    /// Small and stable, for file names and for picking a colour. Not a secret.
    static func fnv(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// Everything that is drawn once and then shown as a picture.
enum Artist {
    private static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func circle(_ centre: CGPoint, _ radius: Double) -> CGRect {
        CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
    }

    /// A cover cut into a record: round, darkened toward its edge so any cover
    /// reads as an object, with a small label and a spindle hole you can see through.
    static func disc(cover: CGImage?, seed: String, side: Int) -> CGImage? {
        guard let context = bitmap(width: side, height: side) else { return nil }
        let size = Double(side)
        let centre = CGPoint(x: size / 2, y: size / 2)
        let radius = size / 2 - 1
        context.interpolationQuality = .high

        context.saveGState()
        context.addEllipse(in: circle(centre, radius))
        context.clip()
        if let cover {
            // Fill the circle, cropping the longer side.
            let scale = max(size / Double(cover.width), size / Double(cover.height))
            let drawn = CGSize(width: Double(cover.width) * scale, height: Double(cover.height) * scale)
            context.draw(cover, in: CGRect(
                x: (size - drawn.width) / 2, y: (size - drawn.height) / 2, width: drawn.width, height: drawn.height
            ))
        } else {
            drawPlainRecord(in: context, centre: centre, radius: radius, seed: seed)
        }
        let edge = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.5)] as CFArray
        if let gradient = CGGradient(colorsSpace: nil, colors: edge, locations: [0, 0.8, 1]) {
            context.drawRadialGradient(
                gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: []
            )
        }
        context.restoreGState()

        context.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
        context.setLineWidth(size * 0.008)
        context.strokeEllipse(in: circle(centre, radius - size * 0.006))

        context.setFillColor(CGColor(gray: 0.06, alpha: 0.72))
        context.fillEllipse(in: circle(centre, size * 0.075))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.3))
        context.setLineWidth(size * 0.006)
        context.strokeEllipse(in: circle(centre, size * 0.075))
        context.setBlendMode(.clear)
        context.fillEllipse(in: circle(centre, size * 0.028))
        return context.makeImage()
    }

    /// The record for a track with no cover: black, grooved, with a label
    /// coloured by the track itself.
    private static func drawPlainRecord(in context: CGContext, centre: CGPoint, radius: Double, seed: String) {
        context.setFillColor(CGColor(gray: 0.06, alpha: 1))
        context.fill(circle(centre, radius))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.06))
        context.setLineWidth(max(1, radius * 0.008))
        for groove in stride(from: 0.46, through: 0.94, by: 0.08) {
            context.strokeEllipse(in: circle(centre, radius * groove))
        }
        let hue = Double(Hashing.fnv(seed) % 360) / 360
        let label = NSColor(hue: hue, saturation: 0.55, brightness: 0.72, alpha: 1)
        context.setFillColor(label.cgColor)
        context.fillEllipse(in: circle(centre, radius * 0.36))
    }

    /// The soft shadow under the disc, as a picture, so nothing has to blur one live.
    static func shadow(side: Int) -> CGImage? {
        guard let context = bitmap(width: side, height: side) else { return nil }
        let size = Double(side)
        let centre = CGPoint(x: size / 2, y: size / 2)
        let colors = [
            CGColor(gray: 0, alpha: 0.34), CGColor(gray: 0, alpha: 0.34),
            CGColor(gray: 0, alpha: 0.13), CGColor(gray: 0, alpha: 0)
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 0.6, 0.8, 1]) else { return nil }
        context.drawRadialGradient(
            gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: size / 2, options: []
        )
        return context.makeImage()
    }

    /// A track's title and artist, white over a soft dark shadow so they read on any desktop.
    static func caption(title: String, artist: String, scale: Double) -> (image: CGImage, size: CGSize)? {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.85)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail

        func line(_ text: String, size: Double, weight: NSFont.Weight, alpha: Double) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: NSColor(white: 1, alpha: alpha),
                .shadow: shadow,
                .paragraphStyle: style
            ])
        }
        let lines = [
            line(title, size: 12, weight: .semibold, alpha: 0.97),
            line(artist, size: 11, weight: .regular, alpha: 0.78)
        ].filter { !$0.string.isEmpty }
        guard !lines.isEmpty else { return nil }

        let widest = lines.map { $0.size().width }.max() ?? 0
        let lineHeight = 16.0
        let size = CGSize(width: min(300, ceil(widest) + 20), height: lineHeight * Double(lines.count) + 8)
        guard let context = bitmap(width: Int(size.width * scale), height: Int(size.height * scale)) else { return nil }
        context.scaleBy(x: scale, y: scale)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, text) in lines.enumerated() {
            // Unflipped: the first line is the top one, so it is drawn highest.
            let y = size.height - 4 - lineHeight * Double(index + 1)
            let box = CGRect(x: 6, y: y, width: size.width - 12, height: lineHeight)
            // Twice, so the shadow is dense enough to carry white text over white.
            text.draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            text.draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        return (image, size)
    }
}
