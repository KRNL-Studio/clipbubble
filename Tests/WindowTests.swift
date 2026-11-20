import Foundation

func windowTests() {
    let nav = AppNav()
    nav.page = .capture
    nav.sidebarSelection.wrappedValue = nil
    check(nav.page == .capture, "clearing the list selection keeps the current page")

    let model = Model()
    let browser = HistoryBrowser(model: model)
    let now = Date()
    let prefix = "history_%_page"
    for i in 0..<501 {
        model.db.insertIfMissing(kind: "text", text: "\(prefix) \(i)", source: "Notes",
                                 hash: "window-page-\(i)", created: now.addingTimeInterval(-Double(i == 500 ? i : i / 3)))
    }
    model.db.insertIfMissing(kind: "text", text: "history_a_page decoy", source: "Notes",
                             hash: "window-page-percent-decoy", created: now)
    model.db.insertIfMissing(kind: "text", text: "historyA%Bpage decoy", source: "Notes",
                             hash: "window-page-underscore-decoy", created: now)
    browser.query = prefix
    check(browser.count == 501 && browser.clips.count < browser.count, "History counts all matches before loading the later pages")
    for _ in 0..<10 {
        if let last = browser.clips.last { browser.loadMore(after: last.id) }
    }
    let ids = browser.clips.map(\.id)
    check(ids.count == 501 && Set(ids).count == 501 && browser.clips.last?.text == "\(prefix) 500",
          "History loads every match once, even with tied timestamps")

    let selected = browser.clips.last
    browser.selection = selected?.id
    browser.reload()
    check(selected != nil && browser.selected == selected, "History keeps a selection on a later page when refreshed")

    model.pickClip = { _, _ in false }
    browser.copySelected()
    check(browser.copyFeedback == false, "History reports a failed clipboard write")
    model.pickClip = { _, _ in true }
    browser.copySelected()
    check(browser.copyFeedback == true, "History reports a successful clipboard write")

    model.historyChanged = { [weak browser] in browser?.reload() }
    if let selected { model.delete(selected) }
    check(browser.count == 500 && browser.selection == nil, "a panel deletion updates History and clears the selected clip")

    browser.filter = "shots"
    let shot = testHome.appendingPathComponent("\(prefix).png")
    model.db.insertIfMissing(kind: "file", text: shot.path, source: "Screenshot", hash: "window-shot", created: now)
    browser.reload()
    check(browser.count == 1 && browser.clips.first?.hash == "window-shot", "History counts source-filtered matches")

    historyRecycledIDTest(model)
}

private func historyRecycledIDTest(_ model: Model) {
    let browser = HistoryBrowser(model: model)
    let prefix = "history recycled fixture"
    let now = Date()
    for i in 0..<102 {
        model.db.insertIfMissing(kind: "text", text: "\(prefix) \(i)", source: "Notes", hash: "recycled-\(i)",
                                 created: now.addingTimeInterval(-Double(i)))
    }
    browser.filter = "text"
    browser.query = prefix
    let removed = model.db.clip(hash: "recycled-101")
    check(browser.count == 102 && browser.clips.count == 100 && removed != nil, "the recycled ID fixture starts beyond the first page")
    if let removed { model.db.delete(id: removed.id) }
    model.db.insertIfMissing(kind: "text", text: "unrelated replacement", source: "Notes", hash: "recycled-decoy",
                             created: now.addingTimeInterval(-101))
    let replacement = model.db.clip(hash: "recycled-decoy")
    check(replacement != nil && replacement?.id == removed?.id, "SQLite reuses the unloaded row's ID")
    if let boundary = browser.clips.last { browser.loadMore(after: boundary.id) }
    check(browser.count == 101 && browser.clips.count == 101 && browser.clips.last?.hash == "recycled-100",
          "the next page includes the remaining match and excludes the recycled ID's unrelated clip")
}
