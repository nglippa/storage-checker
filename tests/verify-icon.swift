import AppKit
import Foundation

// Export the icon macOS actually resolves for the installed application, rather
// than reading the source PNG. This does not launch or alter the application.
let args = CommandLine.arguments
_ = NSApplication.shared
guard args.count == 3 else { fatalError("usage: verify-icon installed.app preview-directory") }
let app = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2], isDirectory: true)
let infoURL = app.appendingPathComponent("Contents/Info.plist")
let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
guard info["CFBundleIconFile"] as? String == "AppIcon" else { fatalError("Missing app icon declaration") }
let resource = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
guard FileManager.default.fileExists(atPath: resource.path) else { fatalError("Missing icon resource") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let icon = NSWorkspace.shared.icon(forFile: app.path)
var renderedArtwork = false
for pixels in [64, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    if let bytes = bitmap.bitmapData {
        for y in 0..<pixels {
            for x in 0..<pixels {
                let offset = y * bitmap.bytesPerRow + x * 4
                if bytes[offset + 3] > 0 && (bytes[offset] > 32 || bytes[offset + 1] > 32 || bytes[offset + 2] > 32) { renderedArtwork = true }
            }
        }
    }
    let target = output.appendingPathComponent("installed-icon-\(pixels).png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: target)
    print(target.path)
}
print("CFBundleIconFile=AppIcon; NSWorkspace resolved icon representations=\(icon.representations.count)")
if !renderedArtwork {
    fputs("NSWorkspace returned blank pixels on this host; inspect the installed ICNS resource directly. This does not verify Finder's rendered icon.\n", stderr)
    exit(2)
}
