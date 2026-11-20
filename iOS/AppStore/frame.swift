// App Store screenshot frame: swiftc frame.swift -o frame && ./frame <raw.png> <out.png> "<headline>" "<subline>"
// Raw shots come from a debug build on the 6.9-inch simulator, launched with -demo YES (see Model.init).
import AppKit

let a = CommandLine.arguments
let shot = NSImage(contentsOfFile: a[1])!
let W: CGFloat = 1320, H: CGFloat = 2868
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: the icon's warm near-black, with a soft pink glow at the top.
NSColor(red: 0x1F/255, green: 0x1C/255, blue: 0x19/255, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()
let pink = NSColor(red: 1, green: 0x7A/255, blue: 0xB6/255, alpha: 1)
NSGradient(colors: [pink.withAlphaComponent(0.55), pink.withAlphaComponent(0)])!
    .draw(fromCenter: NSPoint(x: W / 2, y: H + 200), radius: 0, toCenter: NSPoint(x: W / 2, y: H + 200), radius: 1300, options: [])

// Headline and subline, centred near the top.
func draw(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat) -> CGFloat {
    let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineSpacing = size * 0.08
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p]
    let box = NSRect(x: 90, y: 0, width: W - 180, height: 1000)
    let r = (s as NSString).boundingRect(with: box.size, options: [.usesLineFragmentOrigin], attributes: attrs)
    (s as NSString).draw(with: NSRect(x: 90, y: H - top - r.height, width: W - 180, height: r.height), options: [.usesLineFragmentOrigin], attributes: attrs)
    return r.height
}
let h1 = draw(a[3], size: 104, weight: .bold, color: .white, top: 170)
_ = draw(a[4], size: 50, weight: .regular, color: NSColor.white.withAlphaComponent(0.72), top: 170 + h1 + 36)

// The screenshot, scaled into a rounded phone-shaped card with a shadow, bleeding off the bottom.
let sw: CGFloat = 1050, sh = sw * H / W
let rect = NSRect(x: (W - sw) / 2, y: H - 760 - sh, width: sw, height: sh)
let path = NSBezierPath(roundedRect: rect, xRadius: 110, yRadius: 110)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.6); shadow.shadowBlurRadius = 80; shadow.shadowOffset = NSSize(width: 0, height: -20)
shadow.set(); NSColor.black.setFill(); path.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
path.addClip()
shot.draw(in: rect)
NSGraphicsContext.restoreGraphicsState()
NSColor.white.withAlphaComponent(0.18).setStroke(); path.lineWidth = 4; path.stroke()

NSGraphicsContext.restoreGraphicsState()
// App Store Connect rejects images with an alpha channel, so flatten to RGB.
let cg = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
cg.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: W, height: H))
let out = NSBitmapImageRep(cgImage: cg.makeImage()!)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
