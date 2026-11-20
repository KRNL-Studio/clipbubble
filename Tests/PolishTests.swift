import AppKit

/// The screenshot editor: layout maths, rendering, marks, redaction matching, presets and undo.
func polishTests() {
    let dir = testHome.appendingPathComponent("polish")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // A 400×200 test image: left half red, right half blue, with a white stripe across the middle.
    let src = makeImage(width: 400, height: 200) { ctx in
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 90, width: 400, height: 20))
    }
    let url = dir.appendingPathComponent("shot.png")
    writePNG(src, to: url)
    check(PolishRenderer.load(url).map { $0.width == 400 && $0.height == 200 } == true, "loads a PNG at its own size")

    // Layout: padding is a share of the longer side, on every side.
    var doc = PolishDoc(source: url, size: CGSize(width: 400, height: 200), style: PolishPreset.builtIn[0].style)
    check(PolishLayout(doc: doc).canvas == CGSize(width: 400, height: 200), "no style: the picture is just the image")
    doc.style = PolishStyle(background: .solid(.white), padding: 0.1, radius: 0, shadow: 0)
    var L = PolishLayout(doc: doc)
    check(L.canvas == CGSize(width: 480, height: 280), "padding 0.1 of 400 on each side: \(L.canvas)")
    check(L.image == CGRect(x: 40, y: 40, width: 400, height: 200), "the image sits in the middle: \(L.image)")
    check(PolishLayout(doc: doc, scale: 0.5).canvas == CGSize(width: 240, height: 140), "half scale halves everything")

    for size in PolishStyle.Size.allCases {
        doc.style.size = size
        L = PolishLayout(doc: doc)
        if let px = size.pixels { check(L.canvas == px, "\(size.title) is exactly \(px): \(L.canvas)") }
        if let aspect = size.aspect { check(abs(L.canvas.width / L.canvas.height - aspect) < 0.01, "\(size.title) keeps its shape: \(L.canvas)") }
        check(L.canvas.width >= L.image.maxX && L.canvas.height >= L.image.maxY && L.image.minX >= 0 && L.image.minY >= 0,
              "\(size.title): the image fits inside the picture")
    }
    doc.style.size = .auto
    doc.style.frame = .light
    L = PolishLayout(doc: doc)
    check(L.titleBar > 0 && L.card.height == L.image.height + L.titleBar && L.image.minY == L.card.minY + L.titleBar,
          "a window frame adds a title bar above the image")
    doc.style.frame = .none

    // Crop and coordinates: points on the canvas map back to the same source pixel.
    doc.crop = CGRect(x: 100, y: 50, width: 200, height: 100)
    L = PolishLayout(doc: doc, scale: 2)
    let p = CGPoint(x: 150, y: 75)
    let back = L.toSource(L.toCanvas(p, crop: doc.crop), crop: doc.crop)
    check(abs(back.x - p.x) < 0.001 && abs(back.y - p.y) < 0.001, "source → canvas → source round-trips")
    check(L.toCanvas(doc.crop.origin, crop: doc.crop) == L.image.origin, "the crop's corner is the image's corner")

    // Rendering: the export is the size the layout says, and with no style it's the source pixels unchanged.
    doc = PolishDoc(source: url, size: CGSize(width: 400, height: 200), style: PolishPreset.builtIn[0].style)
    if let img = PolishRenderer.render(doc, source: src) {
        check(img.width == 400 && img.height == 200, "plain render is source-sized")
        check(pixel(img, 50, 20).r > 240 && pixel(img, 50, 20).b < 15, "top left is still red: \(pixel(img, 50, 20))")
        check(pixel(img, 350, 20).b > 240, "top right is still blue")
        check(pixel(img, 50, 100).g > 240, "the white stripe is where it was, the right way up")
    } else { check(false, "renders") }
    doc.style = PolishStyle(background: .solid(RGBA(0, 1, 0)), padding: 0.1, radius: 0.05, shadow: 0.5)
    if let img = PolishRenderer.render(doc, source: src) {
        check(img.width == 480 && img.height == 280, "styled render is canvas-sized")
        check(pixel(img, 2, 2).g > 240 && pixel(img, 2, 2).r < 15, "the background fills the corners")
        check(pixel(img, 100, 70).r > 240, "the image is inside the padding")
    } else { check(false, "renders with a style") }
    for (i, _) in Gradients.all.enumerated() {
        doc.style.background = .gradient(i)
        check(PolishRenderer.render(doc, source: src) != nil, "gradient \(i) renders")
    }
    doc.style.background = .blurred
    doc.style.frame = .dark
    check(PolishRenderer.render(doc, source: src) != nil, "a blurred background with a dark frame renders")

    // Redaction is baked into the export: the stripe under a solid box is gone.
    doc = PolishDoc(source: url, size: CGSize(width: 400, height: 200), style: PolishPreset.builtIn[0].style)
    var box = Mark(.redact, [CGPoint(x: 0, y: 80), CGPoint(x: 400, y: 120)])
    box.redaction = .solid
    box.color = .black
    doc.marks = [box]
    if let img = PolishRenderer.render(doc, source: src) {
        check(pixel(img, 50, 100).r < 10 && pixel(img, 50, 100).g < 10, "a solid redaction covers the stripe: \(pixel(img, 50, 100))")
        check(pixel(img, 50, 20).r > 240, "and nothing else")
    }
    for mode in [Mark.Redaction.pixelate, .blur] {
        doc.marks[0].redaction = mode
        guard let img = PolishRenderer.render(doc, source: src) else { check(false, "\(mode) renders"); continue }
        let mid = pixel(img, 50, 100)
        check(mid.g < 230, "\(mode) hides the white stripe: \(mid)")
    }
    // Pixelate blocks are big: a whole row of pixels across one block is one color.
    doc.marks = [Mark(.redact, [CGPoint(x: 0, y: 0), CGPoint(x: 120, y: 120)])]
    if let img = PolishRenderer.render(doc, source: src) {
        let row = (0..<50).map { pixel(img, $0, 10) }
        check(Set(row.map { "\($0.r),\($0.g),\($0.b)" }).count == 1, "a pixelate block is one flat color")
    }

    // Every kind of mark draws without trouble, through the same path as export.
    doc.style = PolishPreset.builtIn[2].style
    doc.marks = Mark.Kind.allCases.map { kind in
        var m = Mark(kind, [CGPoint(x: 20, y: 20), CGPoint(x: 180, y: 120)])
        if kind == .pen { m.points = (0..<30).map { CGPoint(x: CGFloat($0) * 5, y: 50 + sin(CGFloat($0) / 3) * 20) } }
        if kind == .text { m.text = "Click here"; m.pill = true }
        if kind == .step { m.number = 1 }
        return m
    }
    doc.marks[0].points.append(CGPoint(x: 60, y: 140))  // a bent arrow
    check(PolishRenderer.render(doc, source: src) != nil, "every mark kind renders")
    let png = PolishRenderer.png(doc)
    check(png.flatMap { NSBitmapImageRep(data: $0) }.map { $0.pixelsWide == Int(PolishLayout(doc: doc).canvas.width) } == true,
          "the PNG export is canvas-sized")
    check(PolishRenderer.png(doc, retina: false).flatMap { NSBitmapImageRep(data: $0) }.map { $0.pixelsWide == Int(PolishLayout(doc: doc, scale: 0.5).canvas.width) } == true,
          "1× export is half the pixels")
    let saved = PolishRenderer.saveURL(for: url)
    check(saved.lastPathComponent == "shot polished.png", "saved copies are named after the original: \(saved.lastPathComponent)")
    FileManager.default.createFile(atPath: saved.path, contents: Data())
    check(PolishRenderer.saveURL(for: url).lastPathComponent == "shot polished 2.png", "and never overwrite one")

    // Marks: hit testing, moves and the Shift snaps.
    let line = Mark(.line, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
    check(line.hit(CGPoint(x: 50, y: 3), slop: 4) && !line.hit(CGPoint(x: 50, y: 20), slop: 4), "a line is hit near it, not far off")
    let frame = Mark(.rect, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)])
    check(frame.hit(CGPoint(x: 1, y: 50), slop: 4) && !frame.hit(CGPoint(x: 50, y: 50), slop: 4), "an empty box is grabbed by its edge")
    var filled = frame; filled.fill = .fill
    check(filled.hit(CGPoint(x: 50, y: 50), slop: 4), "a filled box is grabbed anywhere")
    var bent = Mark(.arrow, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 50, y: 40)])
    check(bent.hit(CGPoint(x: 50, y: 40), slop: 4) && !bent.hit(CGPoint(x: 50, y: 0), slop: 4), "a bent arrow goes through its bend point")
    bent = bent.moved(by: CGSize(width: 10, height: 5))
    check(bent.points == [CGPoint(x: 10, y: 5), CGPoint(x: 110, y: 5), CGPoint(x: 60, y: 45)], "moving a mark moves every point")
    let snapped = Mark.snap45(.zero, CGPoint(x: 100, y: 10))
    check(abs(snapped.y) < 0.001 && abs(snapped.x - hypot(100, 10)) < 0.001, "Shift snaps a line flat")
    check(Mark.square(.zero, CGPoint(x: 100, y: -40)) == CGPoint(x: 100, y: -100), "Shift makes a box square")
    check(Mark.smooth((0..<100).map { CGPoint(x: CGFloat($0), y: 0) }, minGap: 5).count <= 21, "pen strokes are thinned out")
    var steps = doc
    steps.marks = [Mark(.step, [.zero])]
    steps.marks[0].number = 3
    check(steps.nextStep == 4, "the next step follows the highest")

    // Redaction matching.
    func kinds(_ s: String) -> [Redactor.Kind] { Redactor.matches(in: s).map(\.kind) }
    func found(_ s: String) -> [String] { Redactor.matches(in: s).map { (s as NSString).substring(with: $0.range) } }
    check(found("mail rohit.g+test@example.co.uk now") == ["rohit.g+test@example.co.uk"], "finds an email: \(found("mail rohit.g+test@example.co.uk now"))")
    check(kinds("card 4242 4242 4242 4242 exp") == [.card], "finds a valid card number: \(kinds("card 4242 4242 4242 4242 exp"))")
    check(kinds("4000-0566-5566-5556") == [.card], "with dashes too")
    check(!kinds("4242 4242 4242 4241").contains(.card), "a number that fails the check digit isn't a card")
    check(Redactor.luhn(Redactor.digits("378282246310005")) && !Redactor.luhn(Redactor.digits("378282246310006")), "Luhn")
    check(kinds("call +1 (415) 555-0132 today") == [.phone], "finds a phone number: \(found("call +1 (415) 555-0132 today"))")
    check(kinds("+91 98765 43210") == [.phone], "an Indian mobile number")
    check(kinds("2026-11-20 14:22:01").isEmpty, "a timestamp isn't a phone number: \(found("2026-11-20 14:22:01"))")
    check(kinds("order 12345").isEmpty && kinds("v1.2.3").isEmpty, "short numbers and versions are left alone")
    check(found("ssh 192.168.1.20 -p 22") == ["192.168.1.20"], "finds an IP address")
    check(kinds("999.1.1.1").isEmpty, "a part over 255 isn't an IP address")
    // Split up so the source holds nothing that looks like a real key to a secret scanner.
    let secrets: [String] = [
        "sk-" + "ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz012345",
        "sk_" + "live_4eC39HqLyjWDarjtT1zdp7dc",
        "ghp" + "_16C7e42F292c6912E7710c838347Ae178B4a",
        "git" + "hub_pat_11ABCDEFG0123456789_abcdefghijklmnop",
        "AKI" + "AIOSFODNN7EXAMPLE",
        "xox" + "b-123456789012-123456789012-AbCdEfGhIjKl",
        "eyJ" + "hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
        "da3" + "9a3ee5e6b4b0d3255bfef95601890afd80709",
        "Zm9" + "vYmFyQmF6UXV4MTIzNDU2Nzg5MEFCQ0RFRkdISUpL",
    ]
    for s in secrets { check(kinds("key: \(s)") == [.secret] && found("key: \(s)") == [s], "finds \(s.prefix(12))…: \(found("key: \(s)"))") }
    check(kinds("/Users/rohitgoyal/Library/Application Support/ClipBubble/history.sqlite").isEmpty, "a long path isn't a key")
    check(kinds("internationalizationandlocalization").isEmpty, "a long word isn't a key")
    check(Redactor.matches(in: "a@b.co 4242424242424242", kinds: [.card]).map(\.kind) == [.card], "only the kinds asked for")
    check(Redactor.pixels(CGRect(x: 0.5, y: 0.75, width: 0.25, height: 0.25), in: CGSize(width: 400, height: 200))
          == CGRect(x: 200, y: 0, width: 100, height: 50), "Vision boxes flip to top-left pixels")

    // Presets and documents survive JSON.
    for preset in PolishPreset.builtIn {
        let back = (try? JSONEncoder().encode(preset)).flatMap { try? JSONDecoder().decode(PolishPreset.self, from: $0) }
        check(back == preset, "preset \(preset.name) round-trips")
    }
    let docBack = (try? JSONEncoder().encode(doc)).flatMap { try? JSONDecoder().decode(PolishDoc.self, from: $0) }
    check(docBack == doc, "a document with every mark round-trips")

    // Undo and redo.
    var h = DocHistory()
    var d = PolishDoc(source: url, size: CGSize(width: 400, height: 200))
    let d0 = d
    h.record(d); d.marks.append(line)
    let d1 = d
    h.record(d); d.style.padding = 0.2
    check(h.canUndo && !h.canRedo, "changes can be undone")
    if let u = h.undo(d) { d = u }
    check(d == d1, "undo goes back one change")
    if let u = h.undo(d) { d = u }
    check(d == d0 && !h.canUndo, "and back to the start")
    if let r = h.redo(d) { d = r }
    check(d == d1 && h.canRedo, "redo goes forward again")
    h.record(d); d.marks.removeAll()
    check(!h.canRedo, "a new change drops the redo trail")
}

private func makeImage(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Draw top-down, like a screenshot.
    ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    return ctx.makeImage()!
}

private func writePNG(_ img: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: img)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

/// The color at (x, y), origin top left, in 0–255 sRGB.
private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
    return (Int(px[0]), Int(px[1]), Int(px[2]))
}
