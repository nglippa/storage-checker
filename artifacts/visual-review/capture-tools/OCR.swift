import AppKit
import Vision
for path in CommandLine.arguments.dropFirst() {
    let image=NSImage(contentsOfFile:path)!
    let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
    let request=VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage:cg).perform([request])
    print("FILE \(URL(fileURLWithPath:path).lastPathComponent)")
    print((request.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined(separator:"\n"))
}
