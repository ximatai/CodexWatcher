import AppKit
import CoreText

/// Compose icon and text as one template image to preserve their optical alignment.
@MainActor
enum MenuBarLabelRenderer {
    static let height: CGFloat = 18
    static let iconWidth: CGFloat = 14
    static let spacing: CGFloat = 4

    static func image(title: String, symbolName: String? = "gauge.with.dots.needle.50percent") -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: NSColor.black
        ]))
        let ink = title.isEmpty ? CGRect.zero : CTLineGetImageBounds(line, nil)
        let textWidth = ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        let textOrigin = symbolName == nil ? 0 : iconWidth + (title.isEmpty ? 0 : spacing)
        let size = NSSize(width: max(1, textOrigin + textWidth), height: height)
        let symbol = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let image = NSImage(size: size)

        // Explicit representations preserve sharp pixel alignment on standard and Retina displays.
        for scale: CGFloat in [1, 2] {
            let icon = tile(size: NSSize(width: iconWidth, height: iconWidth), scale: scale) { _ in
                symbol?.draw(in: NSRect(x: 0, y: 0, width: iconWidth, height: iconWidth))
            }.flatMap(croppedInk)
            let text = tile(size: NSSize(width: textWidth + 8, height: ceil(ink.height) + 8), scale: scale) { context in
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: 4 - ink.minX, y: 4 - ink.minY)
                CTLineDraw(line, context)
            }.flatMap(croppedInk)
            guard let representation = tile(size: size, scale: scale, draw: { _ in
                func draw(_ glyph: CGImage?, x: CGFloat) {
                    guard let glyph else { return }
                    let glyphSize = NSSize(width: CGFloat(glyph.width) / scale, height: CGFloat(glyph.height) / scale)
                    // Center the actual alpha bounds on integral device pixels, not font line boxes.
                    let y = floor((size.height * scale - CGFloat(glyph.height)) / 2) / scale
                    NSImage(cgImage: glyph, size: glyphSize).draw(in: NSRect(x: x, y: y,
                                                                         width: glyphSize.width, height: glyphSize.height))
                }
                if let icon {
                    draw(icon, x: floor((iconWidth * scale - CGFloat(icon.width)) / 2) / scale)
                }
                draw(text, x: textOrigin)
            }) else { continue }
            image.addRepresentation(representation)
        }
        image.isTemplate = true
        image.accessibilityDescription = "Codex Watcher · \(title)"
        return image
    }

    private static func tile(size: NSSize, scale: CGFloat, draw: (CGContext) -> Void) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(ceil(size.width * scale)),
                                            pixelsHigh: Int(ceil(size.height * scale)),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .none
        graphics.cgContext.scaleBy(x: scale, y: scale)
        draw(graphics.cgContext)
        return bitmap
    }

    private static func croppedInk(_ bitmap: NSBitmapImageRep) -> CGImage? {
        guard let data = bitmap.bitmapData else { return nil }
        var minX = bitmap.pixelsWide, maxX = -1, minY = bitmap.pixelsHigh, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where data[y * bitmap.bytesPerRow + x * 4 + 3] > 64 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return bitmap.cgImage?.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }
}
