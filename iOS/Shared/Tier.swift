import Foundation

/// What free ClipBubble shows: one computer and the last day of history. Pro (a one-time purchase) shows everything
/// kept. The app checks the purchase and writes `unlocked`; the keyboard and share sheet only read it.
enum Tier {
    static let freeHours: Double = 24
    static let freeComputers = 1

    private static let key = "pro.unlocked"

    static var unlocked: Bool {
        get { Platform.defaults.bool(forKey: key) }
        set { Platform.defaults.set(newValue, forKey: key) }
    }

    /// How far back lists reach: nil is everything kept.
    static var sinceHours: Double? { unlocked ? nil : freeHours }
}
