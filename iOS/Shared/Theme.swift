import SwiftUI
import UIKit

/// ClipBubble's look: soft pastels led by light blue, on a cool off-white (light) or deep navy-black (dark).
enum Brand {
    /// Buttons, links and selection: a blue deep enough for text to stay readable.
    static let tint = dynamic(light: 0x2F7FD8, dark: 0x9CCBFF)
    /// The pastels. Text and glyphs on them use `ink`.
    static let sky = Color(hex: 0xA9D4FF)
    static let periwinkle = Color(hex: 0xC4D3FF)
    static let lavender = Color(hex: 0xD6C9FF)
    static let mint = Color(hex: 0xBDEBD6)
    static let peach = Color(hex: 0xFFD8C2)
    static let butter = Color(hex: 0xFFEDB3)
    static let rose = Color(hex: 0xFFC9CE)
    static let cloud = Color(hex: 0xE3E9F1)
    static let ink = Color(hex: 0x17212E)
    /// The mascot, as in the app icon (Assets/icon-ios.svg).
    static let bubble = Color(hex: 0x8EC5FF)

    static let background = dynamic(light: 0xF4F7FB, dark: 0x0B0E13)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x161B23)
    /// Behind icons and unselected chips.
    static let wash = dynamic(light: 0xE9F0F8, dark: 0x212935)
    static let hairline = dynamic(light: 0xE2E9F1, dark: 0x262F3B)

    /// A quiet wash from light blue to lavender.
    static let gradient = LinearGradient(colors: [sky, periwinkle, lavender], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let radius: CGFloat = 22

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    /// Rounded navigation titles, set once at launch. Only the fonts: the bars keep the system's own background.
    static func styleBars() {
        func rounded(_ style: UIFont.TextStyle, _ weight: UIFont.Weight) -> UIFont {
            let base = UIFont.preferredFont(forTextStyle: style)
            let font = UIFont.systemFont(ofSize: base.pointSize, weight: weight)
            guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
            return UIFont(descriptor: descriptor, size: base.pointSize)
        }
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: rounded(.largeTitle, .heavy)]
        UINavigationBar.appearance().titleTextAttributes = [.font: rounded(.headline, .bold)]
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

/// The app icon's character: a bubble with a face, and the ring of the one it copied.
struct Mascot: View {
    var size: CGFloat = 44
    var ring = true
    var color = Brand.bubble

    var body: some View {
        let s = size
        ZStack {
            if ring {
                Circle().stroke(color, lineWidth: s * 0.11)
                    .frame(width: s * 0.86, height: s * 0.86)
                    .offset(x: s * 0.2, y: -s * 0.2)
                Circle().fill(.black).frame(width: s * 1.0, height: s * 1.0).blendMode(.destinationOut)
            }
            Circle().fill(color).frame(width: s * 0.86, height: s * 0.86)
            HStack(spacing: s * 0.17) { eye; eye }.offset(y: -s * 0.08)
            Smile().stroke(Brand.ink, style: StrokeStyle(lineWidth: s * 0.055, lineCap: .round))
                .frame(width: s * 0.22, height: s * 0.07).offset(y: s * 0.13)
        }
        .compositingGroup()
        .frame(width: ring ? s * 1.2 : s * 0.86, height: ring ? s * 1.2 : s * 0.86)
        .offset(x: ring ? -s * 0.08 : 0, y: ring ? s * 0.08 : 0)
        .accessibilityHidden(true)
    }

    private var eye: some View {
        Capsule().fill(Brand.ink).frame(width: size * 0.085, height: size * 0.15)
            .overlay(alignment: .top) { Circle().fill(color).frame(width: size * 0.035).padding(.top, size * 0.025) }
    }

    private struct Smile: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 1.9))
            return p
        }
    }
}

/// A computer's operating system, as icons and labels show it.
enum ComputerOS {
    static func symbol(_ os: String?) -> String {
        switch os {
        case "windows": return "pc"
        case "linux": return "desktopcomputer"
        default: return "laptopcomputer"
        }
    }

    static func name(_ os: String?) -> String {
        switch os {
        case "windows": return "Windows"
        case "linux": return "Linux"
        default: return "macOS"
        }
    }
}

/// An SF Symbol on a tinted rounded square, as in the Settings app.
struct IconTile: View {
    let symbol: String
    var color: Color = Brand.tint
    var size: CGFloat = 30
    var filled = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(filled ? Brand.ink : color)
            .frame(width: size, height: size)
            .background(filled ? color : color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The main action on a screen: a light blue capsule.
struct GlowButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.bold)).fontDesign(.rounded)
            .foregroundStyle(Brand.ink)
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(Brand.sky, in: Capsule())
            .shadow(color: Brand.sky.opacity(configuration.isPressed ? 0.2 : 0.45), radius: 12, y: 5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

extension View {
    /// A rounded card on the warm background.
    func brandCard(padding: CGFloat = 16, radius: CGFloat = Brand.radius) -> some View {
        self.padding(padding)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 0.5))
    }

    /// A Form or List on the warm background instead of system gray.
    func brandForm() -> some View {
        scrollContentBackground(.hidden).background(Brand.background)
    }
}
