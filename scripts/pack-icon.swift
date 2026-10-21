import AppKit
import Foundation

// Standard ICNS container with PNG representations. Used when iconutil rejects
// an otherwise valid iconset on this host; no artwork processing occurs here.
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let entries = [("icp4", "icon_16x16", 16), ("ic11", "icon_16x16@2x", 32), ("icp5", "icon_32x32", 32), ("ic12", "icon_32x32@2x", 64), ("ic07", "icon_128x128", 128), ("ic13", "icon_128x128@2x", 256), ("ic08", "icon_256x256", 256), ("ic14", "icon_256x256@2x", 512), ("ic09", "icon_512x512", 512), ("ic10", "icon_512x512@2x", 1024)]
func bigEndian(_ number: Int) -> Data { var value = UInt32(number).bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
var payload = Data()
for (type, name, pixels) in entries {
    let image = try Data(contentsOf: folder.appendingPathComponent(name + ".png"))
    guard let bitmap = NSBitmapImageRep(data: image), bitmap.pixelsWide == pixels, bitmap.pixelsHigh == pixels else { fatalError("Invalid icon representation: \(name)") }
    payload.append(Data(type.utf8)); payload.append(bigEndian(image.count + 8)); payload.append(image)
}
var result = Data("icns".utf8); result.append(bigEndian(payload.count + 8)); result.append(payload)
try result.write(to: output)
guard NSImage(contentsOf: output) != nil else { fatalError("AppKit cannot decode packaged icon") }
print("Packaged 10 PNG icon representations in \(output.path)")
