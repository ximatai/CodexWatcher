import AppKit

// Run from any directory: xcrun swift /path/to/scripts/generate-app-icons.swift
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("CodexWatcher/Assets.xcassets")
let sourceURL = root.appendingPathComponent("docs/design/app-icon-1024.png")
guard let source = NSBitmapImageRep(data: try Data(contentsOf: sourceURL)),
      source.pixelsWide == 1024, source.pixelsHigh == 1024,
      let master = source.cgImage else {
    fatalError("Expected a 1024 × 1024 PNG master at docs/design/app-icon-1024.png")
}

func writePNG(size: Int, macOSInset: Bool, to url: URL) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    let side = CGFloat(size)
    let canvas = CGRect(x: 0, y: 0, width: side, height: side)
    // macOS asset catalogs use pre-shaped artwork. Preserve the square master;
    // apply the rounded tile and optical inset only to exported application icons.
    let tile = macOSInset ? canvas.insetBy(dx: side * 100 / 1024, dy: side * 100 / 1024) : canvas
    if macOSInset {
        let radius = tile.width * 0.22
        context.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
    }
    context.draw(master, in: tile)
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: url, options: .atomic)
}

func writeContents(_ images: [[String: String]], in directory: URL) throws {
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appendingPathComponent("Contents.json"), options: .atomic)
}

let appIcon = assets.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: appIcon, withIntermediateDirectories: true)
var iconEntries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(points)x\(points)@\(scale)x.png"
        try writePNG(size: points * scale, macOSInset: true, to: appIcon.appendingPathComponent(filename))
        iconEntries.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
try writeContents(iconEntries, in: appIcon)

let brand = assets.appendingPathComponent("AppBrand.imageset")
try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
var brandEntries: [[String: String]] = []
for scale in [1, 2] {
    let filename = "brand@\(scale)x.png"
    try writePNG(size: 64 * scale, macOSInset: false, to: brand.appendingPathComponent(filename))
    brandEntries.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x"])
}
try writeContents(brandEntries, in: brand)
try writePNG(size: 256, macOSInset: true, to: root.appendingPathComponent("docs/design/app-icon-macos.png"))
print("Generated AppIcon (10 sizes) and AppBrand (1×/2×) from the square master.")
