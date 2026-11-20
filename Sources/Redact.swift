import AppKit
import Vision

// Finding what to hide in a screenshot: emails, phone and card numbers, IP addresses, keys and tokens, and faces.
// Vision reads the text on the device; nothing leaves the Mac.

enum Redactor {
    enum Kind: String, CaseIterable {
        case email, phone, card, ip, secret
        var title: String {
            switch self {
            case .email: return "Emails"
            case .phone: return "Phone numbers"
            case .card: return "Card numbers"
            case .ip: return "IP addresses"
            case .secret: return "Keys and tokens"
            }
        }
    }

    struct Match: Equatable {
        var kind: Kind
        var range: NSRange
    }

    // MARK: Matching (pure, so it can be tested without Vision)

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    private static let email = rx(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#)
    private static let card = rx(#"(?<![\d-])\d(?:[ -]?\d){12,18}(?![\d-])"#)
    private static let phone = rx(#"(?<![\w.])\+?\(?\d[\d ().-]{7,18}\d(?![\w:])"#)
    private static let ip = rx(#"(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.])"#)
    private static let secrets: [NSRegularExpression] = [
        #"sk-[A-Za-z0-9_-]{16,}"#,                            // OpenAI and Anthropic style
        #"[sr]k_(?:live|test)_[A-Za-z0-9]{16,}"#,             // Stripe
        #"gh[pousr]_[A-Za-z0-9]{20,}"#,                       // GitHub tokens
        #"github_pat_[A-Za-z0-9_]{20,}"#,
        #"AKIA[0-9A-Z]{16}"#,                                 // AWS access key ids
        #"xox[abprs]-[A-Za-z0-9-]{10,}"#,                     // Slack
        #"AIza[0-9A-Za-z_-]{35}"#,                            // Google API keys
        #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, // JWTs
        #"(?<![A-Za-z0-9])[0-9a-fA-F]{32,}(?![A-Za-z0-9])"#,  // long hex: hashes, keys
        #"(?<![A-Za-z0-9+/_-])[A-Za-z0-9+/_-]{32,}={0,2}"#,   // long base64-ish runs
    ].map(rx)

    /// Everything worth hiding in one line of text, longest first where two overlap.
    static func matches(in s: String, kinds: Set<Kind> = Set(Kind.allCases)) -> [Match] {
        let ns = s as NSString, all = NSRange(location: 0, length: ns.length)
        var found: [Match] = []
        func add(_ kind: Kind, _ r: NSRegularExpression, _ ok: (NSTextCheckingResult) -> Bool = { _ in true }) {
            guard kinds.contains(kind) else { return }
            for m in r.matches(in: s, range: all) where ok(m) { found.append(Match(kind: kind, range: m.range)) }
        }
        for r in secrets.dropLast() { add(.secret, r) }
        add(.secret, secrets.last!) { looksRandom(ns.substring(with: $0.range)) }
        add(.email, email)
        add(.card, card) { luhn(digits(ns.substring(with: $0.range))) }
        add(.ip, ip) { m in (1...4).allSatisfy { Int(ns.substring(with: m.range(at: $0))).map { $0 <= 255 } ?? false } }
        add(.phone, phone) { m in
            let s = ns.substring(with: m.range)
            // A date and time reads like a long number too.
            return (10...15).contains(digits(s).count) && s.range(of: #"^\d{4}[-./]\d{1,2}[-./]\d{1,2}"#, options: .regularExpression) == nil
        }
        // Keep the earliest, longest match where they overlap: a card number isn't also a phone number.
        found.sort { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
        var kept: [Match] = []
        for m in found {
            if let last = kept.last, NSIntersectionRange(last.range, m.range).length > 0 {
                if m.range.length > last.range.length { kept[kept.count - 1] = m }
                continue
            }
            kept.append(m)
        }
        return kept
    }

    static func digits(_ s: String) -> [Int] { s.compactMap { $0.wholeNumberValue } }

    /// The check digit test every payment card number passes.
    static func luhn(_ d: [Int]) -> Bool {
        guard (13...19).contains(d.count) else { return false }
        var sum = 0
        for (i, n) in d.reversed().enumerated() {
            if i % 2 == 1 { let x = n * 2; sum += x > 9 ? x - 9 : x } else { sum += n }
        }
        return sum % 10 == 0
    }

    /// A long run that mixes upper case, lower case and digits, so a long word or path isn't mistaken for a key.
    static func looksRandom(_ s: String) -> Bool {
        let up = s.contains { $0.isUppercase }, low = s.contains { $0.isLowercase }, num = s.contains { $0.isNumber }
        return up && low && num && !s.contains("/") || (s.hasSuffix("=") && up && low)
    }

    // MARK: Vision

    private static func recognize(_ image: CGImage, corrected: Bool) -> [VNRecognizedTextObservation] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        // Language correction "fixes" keys and numbers into words, so it's off when looking for them.
        req.usesLanguageCorrection = corrected
        try? VNImageRequestHandler(cgImage: image).perform([req])
        return req.results ?? []
    }

    /// A Vision box (normalized, origin bottom left) in pixels with origin top left.
    static func pixels(_ r: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height)
    }

    /// Boxes to cover, in the image's pixels. Slow: call it off the main thread.
    static func find(in image: CGImage, kinds: Set<Kind> = Set(Kind.allCases), faces: Bool = false) -> [(Kind?, CGRect)] {
        let size = CGSize(width: image.width, height: image.height)
        var boxes: [(Kind?, CGRect)] = []
        for obs in recognize(image, corrected: false) {
            guard let best = obs.topCandidates(1).first else { continue }
            let s = best.string
            for m in matches(in: s, kinds: kinds) {
                guard let range = Range(m.range, in: s), let box = try? best.boundingBox(for: range) else { continue }
                let r = pixels(box.boundingBox, in: size)
                // A little extra all round, so the tops of letters aren't left showing.
                let pad = max(2, r.height * 0.18)
                boxes.append((m.kind, r.insetBy(dx: -pad, dy: -pad)))
            }
        }
        if faces {
            let req = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: image).perform([req])
            for f in req.results ?? [] {
                let r = pixels(f.boundingBox, in: size)
                boxes.append((nil, r.insetBy(dx: -r.width * 0.15, dy: -r.height * 0.2)))
            }
        }
        return boxes
    }

    /// All the text, in reading order. Slow: call it off the main thread.
    static func text(in image: CGImage) -> String {
        let obs = recognize(image, corrected: true)
        // Vision mostly returns reading order; sort rows top to bottom anyway, then left to right within a row.
        let rows = obs.sorted { a, b in
            let h = min(a.boundingBox.height, b.boundingBox.height) / 2
            if abs(a.boundingBox.midY - b.boundingBox.midY) > h { return a.boundingBox.midY > b.boundingBox.midY }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        var out = "", lastY: CGFloat?
        for o in rows {
            guard let s = o.topCandidates(1).first?.string else { continue }
            if let y = lastY { out += abs(y - o.boundingBox.midY) > o.boundingBox.height / 2 ? "\n" : "  " }
            out += s
            lastY = o.boundingBox.midY
        }
        return out
    }
}
