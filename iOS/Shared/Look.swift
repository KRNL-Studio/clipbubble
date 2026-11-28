import SwiftUI

/// What an item is, as the iPhone shows and filters it.
enum Look: String, CaseIterable, Identifiable {
    case text = "Text", link = "Links", image = "Images", file = "Files"

    var id: Self { self }

    var name: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return "File"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    /// Behind the type's label, with `Brand.ink` text.
    var pastel: Color {
        switch self {
        case .text: return Brand.cloud
        case .link: return Brand.sky
        case .image: return Brand.lavender
        case .file: return Brand.peach
        }
    }

    var tint: Color {
        switch self {
        case .text: return Color(hex: 0x7D8896)
        case .link: return Brand.tint
        case .image: return Color(hex: 0x8C70E8)
        case .file: return Color(hex: 0xE38A52)
        }
    }
}

extension Clip {
    var look: Look {
        switch kind {
        case "text": return isLink ? .link : .text
        case "image": return .image
        default: return imagePath != nil ? .image : .file
        }
    }

    /// One web address and nothing else.
    private var isLink: Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where: \.isWhitespace), let scheme = URL(string: t)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
