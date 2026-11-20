import Foundation
import ObjectiveC

/// Use Foundation's defaults lookups, with test writes kept in a process-local domain.
private final class TestDefaults: UserDefaults {
    private let edits = NSLock()

    override func set(_ value: Any?, forKey key: String) {
        edits.withLock {
            var domain = volatileDomain(forName: Self.argumentDomain)
            domain[key] = value
            setVolatileDomain(domain, forName: Self.argumentDomain)
        }
    }

    override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any, forKey: key) }
    override func removeObject(forKey key: String) { set(nil, forKey: key) }
}

private let testDefaults = TestDefaults(suiteName: "clipbubble-test-" + UUID().uuidString)!

private extension UserDefaults {
    @objc class func clipBubbleTestDefaults() -> UserDefaults { testDefaults }
}

func isolateTestDefaults() {
    // Otherwise cfprefsd shares the "tests" domain across worktrees and peer children.
    method_exchangeImplementations(
        class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard))!,
        class_getClassMethod(UserDefaults.self, #selector(UserDefaults.clipBubbleTestDefaults))!
    )
}
