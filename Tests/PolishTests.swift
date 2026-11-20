import AppKit
import ImageIO
import UniformTypeIdentifiers

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
    var tiny = PolishDoc(source: dir, size: .zero, style: PolishStyle(size: .x))
    for crop in [CGRect.zero, .null, CGRect(x: 10, y: 10, width: 100, height: 0.5)] {
        tiny.crop = crop
        let layout = PolishLayout(doc: tiny, scale: .zero)
        check(layout.image.hasFiniteBounds && layout.card.hasFiniteBounds && layout.scale.isFinite
              && layout.toCanvas(.zero, crop: crop).hasFiniteCoordinates
              && layout.toSource(.zero, crop: crop).hasFiniteCoordinates && layout.pixelAspect(crop: crop).isFinite,
              "zero and subpixel dimensions keep layout and coordinate mapping finite")
    }
    let url = dir.appendingPathComponent("shot.png")
    writePNG(src, to: url)
    check(PolishRenderer.load(url).map { $0.width == 400 && $0.height == 200 } == true, "loads a PNG at its own size")
    let tall = dir.appendingPathComponent("tall.png")
    writePNG(makeImage(width: 500, height: 20_000) { ctx in
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 500, height: 20_000))
    }, to: tall)
    check(PolishRenderer.load(tall).map { $0.width == 500 && $0.height == 20_000 } == true, "long PNG loads at full resolution")

    for type in [UTType.jpeg, .heic] {
        let rotated = dir.appendingPathComponent("rotated.\(type.preferredFilenameExtension!)")
        if let dest = CGImageDestinationCreateWithURL(rotated as CFURL, type.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, src, [kCGImagePropertyOrientation: 6] as CFDictionary)
            check(CGImageDestinationFinalize(dest) && PolishRenderer.load(rotated).map {
                $0.width == 200 && $0.height == 400 && pixel($0, 40, 50).r > 220 && pixel($0, 40, 350).b > 220
            } == true, "\(type) honors EXIF rotation")
        } else { check(false, "can write a rotated \(type) fixture") }
    }

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
    renderRegressionTests(in: dir)

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
    check(PolishRenderer.isPolished(saved) && PolishRenderer.isPolished(PolishRenderer.saveURL(for: url)) && !PolishRenderer.isPolished(url),
          "saved copies are told apart from screenshots")
    let internalCopy = PolishRenderer.saveURL(for: Paths.images.appendingPathComponent("3f2a.png"))
    check(internalCopy.deletingLastPathComponent().standardizedFileURL != Paths.images.standardizedFileURL && internalCopy.lastPathComponent.hasPrefix("Image polished"),
          "a copied image's polished copy goes somewhere you can find it: \(internalCopy.path)")

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
    rotationTests(url)

    // Redaction matching.
    func kinds(_ s: String) -> [Redactor.Kind] { Redactor.matches(in: s).map(\.kind) }
    func found(_ s: String) -> [String] { Redactor.matches(in: s).map { (s as NSString).substring(with: $0.range) } }
    check(found("mail rohit.g+test@example.co.uk now") == ["rohit.g+test@example.co.uk"], "finds an email: \(found("mail rohit.g+test@example.co.uk now"))")
    check(kinds("card 4242 4242 4242 4242 exp") == [.card], "finds a valid card number: \(kinds("card 4242 4242 4242 4242 exp"))")
    check(kinds("4000-0566-5566-5556") == [.card], "with dashes too")
    check(found("card 4242 4242 4242 4242 12/29") == ["4242 4242 4242 4242"], "card span ends before expiry")
    check(found("12 4242 4242 4242 4242 12/29") == ["4242 4242 4242 4242"], "card span can start inside a grouped run")
    check(found("2022 4242 4242 4242 4242 12/29") == ["2022 4242 4242 4242 4242"],
          "overlapping card spans cover every valid window")
    check(!kinds("4242 4242 4242 4241").contains(.card), "a number that fails the check digit isn't a card")
    check(Redactor.luhn(Redactor.digits("378282246310005")) && !Redactor.luhn(Redactor.digits("378282246310006")), "Luhn")
    check(kinds("call +1 (415) 555-0132 today") == [.phone], "finds a phone number: \(found("call +1 (415) 555-0132 today"))")
    check(kinds("+91 98765 43210") == [.phone], "an Indian mobile number")
    check(kinds("2026-11-20 14:22:01").isEmpty, "a timestamp isn't a phone number: \(found("2026-11-20 14:22:01"))")
    check(kinds("order 12345").isEmpty && kinds("v1.2.3").isEmpty, "short numbers and versions are left alone")
    check(found("ssh 192.168.1.20 -p 22") == ["192.168.1.20"], "finds an IP address")
    check(found("ssh [2001:db8::1], [::ffff:192.0.2.1], and ::1") == ["2001:db8::1", "::ffff:192.0.2.1", "::1"], "finds valid IPv6 addresses")
    check(found("IPv6:2001:db8::1 host:::1") == ["2001:db8::1", "::1"], "finds IPv6 addresses after labels")
    check(kinds("bad 2001:::db8::1 and 2001:db8::xyz").isEmpty, "rejects malformed IPv6")
    check(kinds("v1.2.3.4 V1.2.3.4 build1.2.3.4").isEmpty, "skips letter-prefixed IPv4 versions")
    check(kinds("clock:14:22:01 mac:aa:bb:cc:dd:ee:ff aa:bb:cc:dd:ee:ff").isEmpty, "timestamps and MAC addresses aren't IPs")
    check(kinds("time=1712345678 time:1712345678").isEmpty, "skips bare Unix timestamps as phones")
    check(kinds("ts=1712345678000 ts:1712345678006").isEmpty, "skips bare millisecond timestamps")
    check(found("tel:4155550132 TEL:4155550132") == ["4155550132", "4155550132"], "accepts phones directly after tel:")
    check(found("phone: 415-555-0132") == ["415-555-0132"], "accepts formatted phones after a label and space")
    check(found("call: 4155550132") == ["4155550132"], "accepts bare phones after a space")
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

private func rotationTests(_ url: URL) {
    let source = makeImage(width: 400, height: 260) { ctx in
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 260))
    }
    var doc = PolishDoc(source: url, size: CGSize(width: 400, height: 260), style: PolishPreset.builtIn[0].style)
    for kind in [Mark.Kind.rect, .ellipse, .text] {
        var mark = Mark(kind, [CGPoint(x: 140, y: 100), CGPoint(x: 260, y: 140)])
        mark.color = RGBA(0, 0, 1)
        mark.fill = .fill
        mark.text = "Rotate it"
        mark.pill = true
        mark.rotation = .pi / 2
        let r = mark.unrotatedBounds
        // Sample the text pill before its first glyph.
        let rise = kind == .text ? r.width / 2 - 5 : r.width * 0.38
        let x = Int(r.midX), y = Int(r.midY - rise)
        let hit = CGPoint(x: x, y: y)
        check(mark.hit(hit, slop: 0) && !r.contains(hit), "a rotated \(kind.rawValue) is hit in its rotated frame")

        doc.marks = [mark]
        let live = makeImage(width: 400, height: 260) { ctx in
            MarkPainter.draw(doc.marks, doc: doc, source: source, layout: PolishLayout(doc: doc), in: ctx)
        }
        let export = PolishRenderer.render(doc, source: source)
        let livePixel = pixel(live, x, y), exportedPixel = export.map { pixel($0, x, y) }
        check(livePixel.b > 240 && livePixel.r < 40 && (exportedPixel?.b ?? 0) > 240 && (exportedPixel?.r ?? 255) < 40,
              "live and export paint the rotated \(kind.rawValue)")
        check(export.map { pixel($0, Int(r.minX + 12), Int(r.midY)).r > 240 } == true,
              "the original \(kind.rawValue) footprint is clear after rotation")
    }
    let encoded = try! JSONEncoder().encode(doc.marks[0])
    check((try? JSONDecoder().decode(Mark.self, from: encoded)) == doc.marks[0], "rotation round-trips as radians")
    var legacy = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    let storedAngle = legacy.removeValue(forKey: "rotation") as? Double
    let legacyData = try! JSONSerialization.data(withJSONObject: legacy)
    check(storedAngle == .pi / 2 && (try? JSONDecoder().decode(Mark.self, from: legacyData))?.rotation == 0,
          "legacy mark JSON with no rotation decodes upright")
    var redaction = Mark(.redact, [.zero, CGPoint(x: 30, y: 80)])
    redaction.rotation = .pi / 4
    check(!redaction.canRotate && redaction.rotationTransform.isIdentity && redaction.bounds == redaction.rect,
          "redactions keep axis-aligned coverage")
}

private func renderRegressionTests(in dir: URL) {
    let url = dir.appendingPathComponent("redactions.png")
    let plain = PolishPreset.builtIn[0].style
    var doc = PolishDoc(source: url, size: CGSize(width: 100, height: 80), style: plain)
    let full = Mark(.redact, [.zero, CGPoint(x: 100, y: 80)])
    let translucent = makeImage(width: 100, height: 80) { ctx in
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.65))
        ctx.fill(CGRect(x: 25, y: 0, width: 6, height: 80))
    }
    for mode in [Mark.Redaction.pixelate, .blur] {
        doc.marks = [full]
        doc.marks[0].redaction = mode
        check(PolishRenderer.render(doc, source: translucent).map {
            pixel($0, 27, 40).a == 255 && pixel($0, 80, 40).a == 255
        } == true, "\(mode) replaces transparent and translucent pixels")
    }

    let red = makeImage(width: 100, height: 80) { ctx in
        ctx.setFillColor(RGBA(1, 0, 0).cg)
        ctx.fill(doc.crop)
    }
    var solid = full
    solid.redaction = .solid
    solid.color = .black
    solid.points = [.zero, CGPoint(x: 50, y: 80)]
    for mode in [Mark.Redaction.pixelate, .blur] {
        var patch = full
        patch.redaction = mode
        doc.marks = [solid, patch]
        let live = makeImage(width: 100, height: 80) { ctx in
            PolishRenderer.drawImage(red, in: doc.crop, ctx: ctx)
            MarkPainter.draw(doc.marks, doc: doc, source: red, layout: PolishLayout(doc: doc), in: ctx)
        }
        check([live, PolishRenderer.render(doc, source: red)].allSatisfy {
            guard let image = $0 else { return false }
            return pixel(image, 25, 40) == (0, 0, 0, 255) && pixel(image, 75, 40).r > 0
        }, "a solid mask stays solid under \(mode) in preview and export")
    }
    redactionSamplingChecks(doc)
    solid.points = full.points
    doc.marks = [solid]
    doc.style = PolishStyle(background: .blurred, padding: 0.2, radius: 0, shadow: 0)
    check([true, false].allSatisfy { marks in
        PolishRenderer.render(doc, source: red, marks: marks).map { pixel($0, 6, 6).r < 5 } == true
    }, "blurred padding uses redacted pixels")
    doc.marks[0].color = RGBA(0, 0, 1)
    check(PolishRenderer.render(doc, source: red, marks: false).map {
        pixel($0, 6, 6).b > 180 && pixel($0, 70, 60).r > 240
    } == true, "blurred padding refreshes when redactions change")

    doc.style = plain
    doc.marks = [full]
    // Repeatedly release the sources so the allocator can reuse their addresses.
    let ownPatches = (0..<128).allSatisfy { i in
        autoreleasepool {
            let expected = (r: 16 + i % 8 * 32, g: 16 + i / 8 % 4 * 64, b: 16 + i / 32 * 64)
            let source = makeImage(width: 100, height: 80) { ctx in
                ctx.setFillColor(RGBA(CGFloat(expected.r) / 255, CGFloat(expected.g) / 255, CGFloat(expected.b) / 255).cg)
                ctx.fill(doc.crop)
            }
            return PolishRenderer.render(doc, source: source).map {
                let p = pixel($0, 50, 40)
                return abs(p.r - expected.r) <= 1 && abs(p.g - expected.g) <= 1 && abs(p.b - expected.b) <= 1
            } == true
        }
    }
    check(ownPatches, "same mask uses each source image's own pixels")

    solid.color = .white
    var box = Mark(.rect, [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60)])
    box.fill = .fill
    box.color = RGBA(1, 0, 0)
    let firstLight = Mark(.highlight, [CGPoint(x: 8, y: 8), CGPoint(x: 55, y: 65)])
    let secondLight = Mark(.highlight, [CGPoint(x: 28, y: 18), CGPoint(x: 72, y: 72)])
    doc.marks = [solid, firstLight, box]
    let live = makeImage(width: 100, height: 80) { ctx in
        PolishRenderer.drawImage(red, in: doc.crop, ctx: ctx)
        MarkPainter.draw(doc.marks, doc: doc, source: red, layout: PolishLayout(doc: doc), in: ctx)
    }
    check([live, PolishRenderer.render(doc, source: red)].allSatisfy {
        guard let img = $0 else { return false }
        return pixel(img, 40, 40).g == 255 && pixel(img, 90, 40).g == 255
    }, "redaction covers later marks and spotlight dimming")
    doc.marks = [firstLight, secondLight]
    check(PolishRenderer.render(doc, source: red).map {
        pixel($0, 18, 40).r == 255 && pixel($0, 40, 40).r == 255 && pixel($0, 90, 40).r < 150
    } == true, "overlapping spotlights stay lit")

    let split = makeImage(width: 100, height: 80) { ctx in
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(doc.crop)
        ctx.setFillColor(RGBA(1, 0, 0).cg)
        ctx.fill(CGRect(x: 0, y: 0, width: 31, height: 80))
    }
    var strip = Mark(.redact, [.zero, CGPoint(x: 31, y: 80)])
    strip.redaction = .solid
    strip.color = .black
    doc.marks = [strip]
    writePNG(split, to: url)
    check(PolishRenderer.png(doc, retina: false).flatMap { NSBitmapImageRep(data: $0)?.cgImage }.map { img in
        (12...18).allSatisfy { pixel(img, $0, 20).r == 0 }
    } == true, "1× export resamples after masking the original")

    doc.crop = CGRect(x: 31, y: 0, width: 69, height: 80)
    for mode in [Mark.Redaction.pixelate, .blur] {
        doc.marks = [Mark(.redact, [.zero, CGPoint(x: 53, y: 80)])]
        doc.marks[0].redaction = mode
        check(PolishRenderer.render(doc, source: split).map { pixel($0, 2, 40).r == 0 } == true,
              "\(mode) samples only inside the crop")
    }

    doc.crop = CGRect(x: 0, y: 40, width: 100, height: 40)
    doc.style.frame = .light
    doc.marks = []
    box.points = [CGPoint(x: 50, y: 20), CGPoint(x: 90, y: 60)]
    let without = PolishRenderer.render(doc, source: red)
    doc.marks = [box]
    check(without.flatMap { base in
        PolishRenderer.render(doc, source: red).map { pixel($0, 70, 12) == pixel(base, 70, 12) }
    } == true, "marks stay out of the title bar")

    doc.style = plain
    doc.crop = CGRect(x: 0, y: 0, width: 100, height: 80)
    doc.marks = []
    doc.style.radius = 0.25
    check(PolishRenderer.render(doc, source: red).map {
        pixel($0, 0, 0).a == 0 && pixel($0, 50, 40).a == 255
    } == true, "None style honors corners")

    for (w, h) in [(101, 51), (1, 1)] {
        let img = makeImage(width: w, height: h) { ctx in
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        doc = PolishDoc(source: url, size: CGSize(width: w, height: h), style: plain)
        check(PolishRenderer.render(doc, source: img, scale: 0.5).map {
            $0.width == (w + 1) / 2 && $0.height == (h + 1) / 2 &&
                pixel($0, 0, 0).a == 255 && pixel($0, $0.width - 1, $0.height - 1).a == 255
        } == true, "1× output keeps opaque edges at \(w)×\(h)")
    }
}

private func redactionSamplingChecks(_ original: PolishDoc) {
    var doc = original
    func source(_ hidden: RGBA) -> CGImage {
        makeImage(width: 100, height: 80) { ctx in
            ctx.setFillColor(RGBA(0.2, 0.2, 0.2).cg)
            ctx.fill(doc.crop)
            ctx.setFillColor(hidden.cg)
            for y in stride(from: 0, to: 80, by: 8) {
                ctx.fill(CGRect(x: 0, y: y, width: 20, height: 6))
            }
        }
    }
    let bright = source(.white), dark = source(RGBA(0, 0, 1))
    var solid = Mark(.redact, [.zero, CGPoint(x: 20, y: 80)])
    solid.redaction = .solid
    solid.color = .black
    for mode in [Mark.Redaction.pixelate, .blur] {
        var patch = Mark(.redact, [.zero, CGPoint(x: 80, y: 80)])
        patch.redaction = mode
        doc.marks = [solid, patch]
        func live(_ image: CGImage) -> CGImage {
            makeImage(width: 100, height: 80) { ctx in
                PolishRenderer.drawImage(image, in: doc.crop, ctx: ctx)
                MarkPainter.draw(doc.marks, doc: doc, source: image, layout: PolishLayout(doc: doc), in: ctx)
            }
        }
        func png(_ image: CGImage?) -> Data? {
            image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        }
        let preview = png(live(bright)), export = png(PolishRenderer.render(doc, source: bright))
        check(preview != nil && preview == png(live(dark))
              && export != nil && export == png(PolishRenderer.render(doc, source: dark)),
              "\(mode) cannot sample pixels under the solid mask in preview or export")
    }
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
private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
    return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
}
