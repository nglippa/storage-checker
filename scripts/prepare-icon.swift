import AppKit
import Foundation

// Use conventional RGBA icon representations. Preserve every supplied
// RGB channel value and add an opaque alpha channel; do not redraw the artwork.
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let source = NSBitmapImageRep(data: try Data(contentsOf: input))!
precondition(source.bitsPerSample == 8 && source.samplesPerPixel == 3 && !source.isPlanar)
let rgba = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide, pixelsHigh: source.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: source.colorSpaceName, bytesPerRow: 0, bitsPerPixel: 0)!
var pixel = [Int](repeating: 0, count: 4)
for y in 0..<source.pixelsHigh {
    for x in 0..<source.pixelsWide {
        source.getPixel(&pixel, atX: x, y: y)
        pixel[3] = 255
        rgba.setPixel(&pixel, atX: x, y: y)
    }
}
try rgba.representation(using: .png, properties: [:])!.write(to: output)
