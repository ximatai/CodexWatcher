import AppKit
import XCTest
@testable import WatcherCore

final class MenuBarLabelRendererTests: XCTestCase {
    @MainActor
    func testVisibleIconAndTextCentersMatchAtBothDisplayScales() throws {
        for scale: CGFloat in [1, 2] {
            for title in ["25%", "100%", "—%"] {
                let image = MenuBarLabelRenderer.image(title: title)
                XCTAssertTrue(image.isTemplate)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale),
                    pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ))
                bitmap.size = image.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                image.draw(in: NSRect(origin: .zero, size: image.size))
                NSGraphicsContext.restoreGraphicsState()

                let pixels = try XCTUnwrap(bitmap.bitmapData)
                func verticalCenter(from start: Int, to end: Int) throws -> CGFloat {
                    var rows: [Int] = []
                    for y in 0..<bitmap.pixelsHigh {
                        for x in start..<end where pixels[y * bitmap.bytesPerRow + x * 4 + 3] > 64 {
                            rows.append(y)
                            break
                        }
                    }
                    return CGFloat(try XCTUnwrap(rows.min()) + XCTUnwrap(rows.max())) / 2
                }
                let iconCenter = try verticalCenter(from: 0, to: Int(MenuBarLabelRenderer.iconWidth * scale))
                let textCenter = try verticalCenter(from: Int((MenuBarLabelRenderer.iconWidth + MenuBarLabelRenderer.spacing) * scale),
                                                   to: bitmap.pixelsWide)
                XCTAssertEqual(iconCenter, textCenter, accuracy: 0.5,
                               "Visible centers must align: \(title), scale \(scale)")
                if let directory = ProcessInfo.processInfo.environment["WATCHER_LABEL_PREVIEW_DIR"], title == "25%" {
                    // A white backdrop makes the black template pixels visible in diagnostic previews.
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                    NSColor.white.setFill()
                    NSRect(origin: .zero, size: image.size).fill()
                    image.draw(in: NSRect(origin: .zero, size: image.size))
                    NSGraphicsContext.restoreGraphicsState()
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("status-label-\(Int(scale))x.png")
                    try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }
}
