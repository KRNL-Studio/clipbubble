import AppKit
// slice <pano.png> <outdir>: cuts 1320-wide slides and flattens to opaque sRGB PNG (App Store rejects alpha).
let a = CommandLine.arguments
let src = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let n = src.width / 1320
for i in 0..<n {
    let part = src.cropping(to: CGRect(x: i * 1320, y: 0, width: 1320, height: src.height))!
    let cg = CGContext(data: nil, width: 1320, height: src.height, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    cg.draw(part, in: CGRect(x: 0, y: 0, width: 1320, height: src.height))
    let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(a[2])/\(i + 1).png"))
}
