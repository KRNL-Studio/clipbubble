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

    let dragSource = AppBundleDragView.DragSource(frame: .zero)
    check(!dragSource.mouseDownCanMoveWindow, "dragging the app tile starts a file drag instead of moving the panel")
    check(dragSource.acceptsFirstMouse(for: nil), "the app tile accepts the first click while System Settings has focus")

    accessibilityDragPanelTests(defaults: defaults)
}

private func accessibilityDragPanelTests(defaults: UserDefaults) {
    var trusted = false
    let state = OnboardingState(defaults: defaults, isTrusted: { trusted })
    var returns = 0
    let companion = AccessibilityDragPanelController(state: state) { returns += 1 }
    let screen = NSScreen.main

    state.begin()
    check(!companion.show(on: screen), "the companion only opens on the Accessibility step")
    state.next()
    check(companion.show(on: screen), "opening Accessibility Settings shows the drag companion")
    let panel = companion.panel
    check(panel?.isVisible == true && panel?.isFloatingPanel == true && panel?.level == .floating
          && panel?.hidesOnDeactivate == false, "the companion stays visible above other apps when ClipBubble deactivates")
    check(panel?.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]) == true,
          "the companion can follow System Settings across Spaces and full-screen Spaces")
    check(panel?.styleMask.contains(.nonactivatingPanel) == true && panel?.canBecomeKey == false
          && panel?.isMovableByWindowBackground == true, "the companion can be moved without taking keyboard focus")
    check(companion.show(on: screen) && companion.panel === panel, "opening Settings again reuses the same companion")

    trusted = true
    check(waitForOnboarding { returns == 1 }, "the state polls for access and returns to setup without a SwiftUI view")
    check(state.accessibility == true && state.autoPaste && companion.panel == nil && panel?.isVisible == false,
          "granting access enables auto-paste and dismisses the companion")
    check(!companion.show(on: screen) && companion.panel == nil && returns == 1,
          "existing access leaves the companion dismissed and returns to setup only once")

    trusted = false
    check(companion.show(on: screen), "reopening Settings refreshes a stale permission result")
    state.back()
    check(companion.panel == nil && returns == 1, "Back dismisses the companion without returning to setup")
    state.next()
    check(companion.show(on: screen), "returning to Accessibility allows reopening the companion")
    state.skip()
    check(companion.panel == nil && returns == 1, "Skip dismisses the companion without returning to setup")
    state.back()
    check(companion.show(on: screen), "the companion can reopen after skipping Accessibility")
    companion.dismiss()
    trusted = true
    state.refreshAccessibility()
    check(companion.panel == nil && returns == 1, "dismissing the companion suppresses automatic return to setup")

    trusted = false
    check(companion.show(on: screen), "an untrusted setup can show the companion before finishing")
    state.finish()
    check(companion.panel == nil && returns == 1, "finishing setup dismisses the companion without reactivating ClipBubble")
}

private func waitForOnboarding(_ test: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while !test(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return test()
}
