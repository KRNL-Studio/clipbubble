import Combine
import Foundation

func updaterTests() {
    check(Updater.isNewer("1.10.0", than: "1.9.2"), "1.10.0 is newer than 1.9.2")
    check(Updater.isNewer("1.6.1", than: "1.6.0"), "1.6.1 is newer than 1.6.0")
    check(!Updater.isNewer("1.6.0", than: "1.6.0"), "the same version isn't an update")
    check(!Updater.isNewer("1.5.0", than: "1.6.0"), "an older release isn't an update")
    check(Updater.releases.absoluteString == "https://github.com/KRNL-Studio/clipbubble/releases/latest",
          "the releases link uses the canonical repo")
    check(Updater.latest.absoluteString == "https://api.github.com/repos/KRNL-Studio/clipbubble/releases/latest",
          "the release check uses the canonical repo")

    let release = """
    {"tag_name": "v1.7.0", "html_url": "https://github.com/KRNL-Studio/clipbubble/releases/tag/v1.7.0",
     "assets": [{"name": "ClipBubble.dmg", "browser_download_url": "https://example.com/ClipBubble.dmg"},
                {"name": "ClipBubble.zip", "browser_download_url": "https://example.com/ClipBubble.zip"}]}
    """
    let r = try? Updater.parse(Data(release.utf8))
    check(r?.version == "1.7.0", "the tag's v is dropped")
    check(r?.zip.lastPathComponent == "ClipBubble.zip", "the Mac update is the zip, not the dmg")
    check(r?.page.absoluteString.hasSuffix("/v1.7.0") == true, "what's new links to the release")

    let windowsOnly = #"{"tag_name": "v1.7.0", "html_url": "https://x", "assets": [{"name": "ClipBubble.exe", "browser_download_url": "https://x/e"}]}"#
    check((try? Updater.parse(Data(windowsOnly.utf8))) == nil, "a release without the Mac zip isn't offered")

    MainActor.assumeIsolated {
        updaterCheckDuringInstall()
        var terminated = false
        let helper = testHome.appendingPathComponent("missing-relaunch-helper")
        do {
            try Updater.reopen(Bundle.main.bundleURL, helper: helper) { terminated = true }
            check(false, "a relaunch helper launch failure is thrown")
        } catch {
            check(!terminated, "a relaunch helper launch failure is thrown before quitting")
        }
    }
}

@MainActor
private func updaterCheckDuringInstall() {
    let updater = Updater()
    let release = Updater.Release(version: "999.0.0", zip: URL(string: "clipbubble-test://no-download")!, page: Updater.releases)
    var states: [Updater.State] = []
    let subscription = updater.$state.sink { states.append($0) }
    defer { subscription.cancel() }
    updater.check(quietly: true) {
        updater.install(release)
        return release
    }

    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if case .failed = updater.state { break }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    if case .failed = updater.state {
        check(states.contains(.installing("Downloading 999.0.0…")) && !states.contains(.available(release)) && !states.contains(.current),
              "the quiet check result leaves an active installation alone")
    } else { check(false, "the test installation reports its download failure") }
}
