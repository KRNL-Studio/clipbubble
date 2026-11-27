import AppKit

func onboardingTests() {
    let suite = "clipbubble-onboarding-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let shots = URL(fileURLWithPath: "/fake/Desktop", isDirectory: true)
    let downloads = URL(fileURLWithPath: "/fake/Downloads", isDirectory: true)
    let custom = URL(fileURLWithPath: "/fake/My Screenshots", isDirectory: true)
    func folderURL(_ folder: OnboardingFolder) -> URL? {
        if folder == .downloads { return downloads }
        return defaults.string(forKey: "screenshotFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? shots
    }

    var trusted = false
    var axChecks = 0
    let probeEntered = DispatchSemaphore(value: 0)
    let finishProbe = DispatchSemaphore(value: 0)
    let state = OnboardingState(defaults: defaults, isTrusted: { axChecks += 1; return trusted },
        readFolder: { url in
            if Thread.isMainThread { return false }
            probeEntered.signal()
            guard finishProbe.wait(timeout: .now() + 2) == .success else { return false }
            return url == shots || url == custom
        }, folderURL: folderURL)

    var prefChanges: [(OnboardingFolder, Bool)] = []
    var watcherSnapshots: [Set<OnboardingFolder>] = []
    func refreshWatchers() {
        watcherSnapshots.append(Set(OnboardingFolder.allCases.filter {
            state.canWatch($0) && (defaults.object(forKey: "save." + $0.rawValue) as? Bool ?? true)
        }))
    }
    state.setFolderPreference = { folder, on in
        defaults.set(on, forKey: "save." + folder.rawValue)
        prefChanges.append((folder, on))
        refreshWatchers()
    }
    var completions = 0
    state.didCompleteFirstRun = { completions += 1; refreshWatchers() }

    refreshWatchers()
    check(state.needsSetup && watcherSnapshots.last == [], "fresh launch defers both folder watchers even with default-on preferences")
    state.begin()
    state.back()
    check(state.isRunning && state.step == .welcome && axChecks == 0, "fresh setup starts on Welcome without checking permissions")
    state.next()
    check(state.step == .accessibility && state.accessibility == false, "Accessibility step shows waiting when the app is untrusted")
    state.back()
    check(state.step == .welcome, "Back returns to Welcome")
    state.next()
    state.begin()
    check(state.step == .accessibility, "reopening an active setup preserves its place")

    defaults.set(false, forKey: "autoPaste")
    // Restart with the preference already off so the probe must set it.
    let autoPasteState = OnboardingState(defaults: defaults, isTrusted: { trusted }, readFolder: { _ in false })
    autoPasteState.begin()
    autoPasteState.next()
    check(autoPasteState.accessibility == false && !autoPasteState.autoPaste, "waiting leaves auto-paste off")
    trusted = true
    autoPasteState.refreshAccessibility()
    check(autoPasteState.accessibility == true && autoPasteState.autoPaste && defaults.bool(forKey: "autoPaste"),
          "a live grant enables and persists auto-paste")

    state.skip()
    let checksBeforeFolderStep = axChecks
    state.refreshAccessibility()
    check(state.step == .folders && axChecks == checksBeforeFolderStep, "Skip advances and Accessibility probing stops on the folder step")
    state.requestFolder(.screenshots)
    check(probeEntered.wait(timeout: .now() + 1) == .success, "Allow Screenshots checks the folder off the main thread")
    check(!state.canWatch(.screenshots) && !state.canWatch(.downloads), "a pending request leaves both watchers deferred")
    finishProbe.signal()
    check(waitForOnboarding { state.checkingFolder == nil }, "screenshot probe result returns")
    check(state.folderAccess(.screenshots, at: shots) == .allowed && watcherSnapshots.last == [.screenshots],
          "a successful read starts only the requested watcher immediately")

    state.chooseScreenshotFolder(custom)
    check(state.displayedURL(.screenshots) == custom && state.checkingFolder == nil,
          "choosing a folder shows its path without probing it")
    check(defaults.object(forKey: "screenshotFolder") == nil, "choosing a folder leaves the previous location configured until the probe succeeds")
    state.requestFolder(.screenshots)
    check(probeEntered.wait(timeout: .now() + 1) == .success, "Allow Screenshots probes the chosen location")
    finishProbe.signal()
    check(waitForOnboarding { state.checkingFolder == nil }, "chosen-folder probe result returns")
    check(defaults.string(forKey: "screenshotFolder") == custom.path && watcherSnapshots.last == [.screenshots],
          "the chosen location is saved before refreshing the watcher")
    defaults.set("/fake/Unconfirmed", forKey: "screenshotFolder")
    check(!state.canWatch(.screenshots), "a grant for one screenshot path cannot open the watcher for another path")
    defaults.set(custom.path, forKey: "screenshotFolder")

    state.requestFolder(.downloads)
    check(probeEntered.wait(timeout: .now() + 1) == .success, "Allow Downloads runs its own folder probe")
    finishProbe.signal()
    check(waitForOnboarding { state.checkingFolder == nil }, "download probe result returns")
    check(state.folderAccess(.downloads, at: downloads) == .denied && !state.canWatch(.downloads),
          "a denied read leaves the watcher deferred")

    state.skip()
    check(state.step == .ready && state.needsSetup, "Skip from Folders opens the summary before completing")
    state.finish()
    check(!state.isRunning && defaults.bool(forKey: OnboardingState.completionKey)
          && defaults.bool(forKey: OnboardingState.shownWindowKey) && completions == 1,
          "completion is persisted and refreshes the normal capture services once")
    check(state.canWatch(.downloads) && defaults.object(forKey: "save.downloads") as? Bool == false
          && watcherSnapshots.last == [.screenshots], "normal capture services honor the first-run decision to leave Downloads off")

    defaults.set(false, forKey: "autoPaste")
    let editsBeforeRerun = prefChanges.count
    state.begin()
    state.next()
    check(state.isRunning && state.step == .accessibility && state.accessibility == true && !state.autoPaste,
          "running setup again shows existing Accessibility access and preserves the Auto-paste preference")
    state.finish()
    check(!state.needsSetup && completions == 1 && prefChanges.count == editsBeforeRerun
          && defaults.string(forKey: "screenshotFolder") == custom.path,
          "closing a setup rerun keeps completion and preferences intact")

    defaults.removeObject(forKey: OnboardingState.completionKey)
    let upgraded = OnboardingState(defaults: defaults)
    check(!upgraded.needsSetup && defaults.bool(forKey: OnboardingState.completionKey)
          && OnboardingFolder.allCases.allSatisfy(upgraded.canWatch),
          "an upgrading user skips setup and is eligible to start both watchers at launch")

    defaults.set(false, forKey: OnboardingState.completionKey)
    let dismissed = OnboardingState(defaults: defaults, isTrusted: { false }, readFolder: { _ in false })
    var skipped: Set<OnboardingFolder> = []
    dismissed.setFolderPreference = { folder, on in if !on { skipped.insert(folder) } }
    check(dismissed.needsSetup, "explicit incomplete setup takes precedence over the migration")
    dismissed.begin()
    dismissed.skip()
    check(dismissed.step == .ready, "Skip setup jumps straight to the summary")
    dismissed.finish()
    check(skipped == Set(OnboardingFolder.allCases) && !dismissed.needsSetup, "finishing without a read skips both folder prompts")

    let dragURL = AppBundleDragView.bundleFileURL
    check(dragURL.isFileURL && (dragURL as URL) == Bundle.main.bundleURL,
          "drag source provides the main bundle's file NSURL even in an unbundled test executable")
    let dragPasteboard = NSPasteboard(name: .init("clipbubble-onboarding-drag-" + UUID().uuidString))
    defer { dragPasteboard.releaseGlobally() }
    check(dragURL.writableTypes(for: dragPasteboard).contains(.fileURL), "the drag writer advertises a Finder-style file URL")
}

private func waitForOnboarding(_ test: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while !test(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return test()
}
