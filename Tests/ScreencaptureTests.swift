private final class ThumbnailDefaults: ScreenshotThumbnailDefaults {
    private var values: [String: Any] = ["polishCard": true, Screencapture.replacementKey: true]

    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
    func synchronize() -> Bool { true }
}

private final class ThumbnailFixture {
    let defaults = ThumbnailDefaults()
    var value: Bool?
    var writes: [Bool?] = []
    var canWrite = true

    init(_ value: Bool?) { self.value = value }

    func controller() -> Screencapture {
        Screencapture(defaults: defaults, readThumbnail: { self.value }, writeThumbnail: { value in
            self.writes.append(value)
            guard self.canWrite else { return false }
            self.value = value
            return true
        })
    }
}

func screencaptureTests() {
    for original: Bool? in [nil, true, false] {
        let fixture = ThumbnailFixture(original)
        let capture = fixture.controller()
        capture.sync(saveScreenshots: true)
        check(fixture.value == false && !capture.showsThumbnail, "active replacement hides the macOS thumbnail")
        check(fixture.writes == (original == false ? [] : [false]), "only an enabled thumbnail is overridden")

        fixture.defaults.set(false, forKey: Screencapture.replacementKey)
        capture.sync(saveScreenshots: true)
        check(fixture.value == original && capture.showsThumbnail == (original ?? true), "disabling replacement restores the exact prior value")

        fixture.defaults.set(true, forKey: Screencapture.replacementKey)
        capture.sync(saveScreenshots: true)
        capture.restore()
        check(fixture.value == original, "quit restores the exact prior value")
        check(fixture.writes == (original == false ? [] : [false, original, false, original]),
              "a thumbnail disabled by the user stays untouched on disable and quit")
    }

    let prerequisites = ThumbnailFixture(nil)
    let capture = prerequisites.controller()
    capture.sync(saveScreenshots: false)
    check(prerequisites.writes.isEmpty, "replacement waits for Save every screenshot")
    capture.sync(saveScreenshots: true)
    prerequisites.defaults.set(false, forKey: "polishCard")
    capture.sync(saveScreenshots: true)
    check(prerequisites.writes == [false, nil], "turning off the Polish card restores the thumbnail")
    prerequisites.defaults.set(true, forKey: "polishCard")
    capture.sync(saveScreenshots: true)
    check(prerequisites.writes == [false, nil, false], "turning the Polish card back on suppresses the thumbnail")
    capture.sync(saveScreenshots: false)
    check(prerequisites.writes == [false, nil, false, nil], "turning off screenshot capture restores the thumbnail")
    capture.sync(saveScreenshots: true)
    check(prerequisites.writes == [false, nil, false, nil, false], "turning screenshot capture back on suppresses the thumbnail")

    for original: Bool? in [nil, false] {
        let external = ThumbnailFixture(original)
        let watching = external.controller()
        watching.sync(saveScreenshots: true)
        external.writes.removeAll()
        external.value = true
        watching.sync(saveScreenshots: true)
        check(watching.showsThumbnail && !external.defaults.bool(forKey: Screencapture.replacementKey),
              "an external re-enable refreshes the banner and turns the replacement toggle off")
        watching.sync(saveScreenshots: true)
        watching.restore()
        external.controller().sync(saveScreenshots: true)
        check(external.writes.isEmpty && external.value == true, "polling, quitting and relaunching honor the external choice")
        external.defaults.set(true, forKey: Screencapture.replacementKey)
        watching.sync(saveScreenshots: true, applyRequested: true)
        check(watching.showsThumbnail == false && external.writes == [false], "an explicit request applies replacement again")
        watching.restore()
        check(external.writes == [false, true], "quit restores the most recent external value")
    }

    let requested = ThumbnailFixture(nil)
    let replacing = requested.controller()
    replacing.sync(saveScreenshots: true)
    requested.value = true
    replacing.sync(saveScreenshots: true, applyRequested: true)
    check(requested.value == false && !replacing.showsThumbnail, "an explicit request applies before the next external-change poll")
    replacing.restore()
    check(requested.writes == [false, false, true], "an explicit request records the new value to restore")

    for original: Bool? in [nil, true] {
        let crash = ThumbnailFixture(original)
        crash.controller().sync(saveScreenshots: true)
        let relaunched = crash.controller()
        relaunched.sync(saveScreenshots: true)
        check(crash.writes == [false] && !relaunched.showsThumbnail, "relaunch keeps the existing override and its recorded prior value")
        relaunched.restore()
        check(crash.writes == [false, original] && crash.value == original, "quit after a crash restores the pre-crash value")
        relaunched.restore()
        check(crash.writes == [false, original], "a successful restore clears ownership")
    }

    let retry = ThumbnailFixture(nil)
    retry.controller().sync(saveScreenshots: true)
    retry.canWrite = false
    retry.controller().restore()
    check(retry.value == false, "a failed restore leaves the current value in place")
    retry.canWrite = true
    retry.controller().restore()
    check(retry.writes == [false, nil, nil] && retry.value == nil, "a failed restore keeps ownership for a future retry")

    let writeFail = ThumbnailFixture(nil)
    writeFail.canWrite = false
    let failing = writeFail.controller()
    failing.sync(saveScreenshots: true)
    check(failing.showsThumbnail && writeFail.defaults.bool(forKey: Screencapture.replacementKey),
          "a failed hide leaves the replacement toggle enabled")
    writeFail.canWrite = true
    failing.sync(saveScreenshots: true)
    check(!failing.showsThumbnail && writeFail.value == false,
          "a failed hide clears stale ownership so the next sync retries cleanly")
}
