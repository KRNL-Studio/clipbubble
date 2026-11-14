import AppKit

// A linked device can vanish mid-write; that should end its link, not the app.
signal(SIGPIPE, SIG_IGN)

// A typo'd or newer option shouldn't open a second bubble next to the running one.
let options = ["--peer", "--peer-stdio", "--pair", "--status", "--update", "--mcp"]
if let unknown = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("--") && !options.contains($0) }) {
    print("ClipBubble: unknown option \(unknown). Options: \(options.joined(separator: ", "))")
    exit(2)
}
if CommandLine.arguments.contains("--peer") { PeerRelay.run() }
if CommandLine.arguments.contains("--peer-stdio") {
    SyncEngine.shared.apply = { c in SyncLog.write("would apply \(c.hash)") }
    SyncEngine.shared.serveStdio()
    dispatchMain()
}
if CommandLine.arguments.contains("--pair") {
    // The same pairing as Settings, from a terminal: prints the link the QR code would hold.
    let p = PairingServer()
    p.onReady = { url in
        print(url.absoluteString)
        print("On another computer, choose Add a computer… and enter \(p.typedAddress) and the code \(LinkCode.display(p.shortCode)).")
        fflush(stdout)
    }
    p.onGaveUp = {
        print("Too many wrong codes. Run --pair again for a new one.")
        // Long enough for the last answer to reach the other computer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(1) }
    }
    p.onPaired = { print("Linked \($0)"); exit(0) }
    p.start()
    dispatchMain()
}
if CommandLine.arguments.contains("--status") {
    // Link health only: names, states and versions, never anything from the history.
    let me = ProcessInfo.processInfo.processIdentifier
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "studio.krnl.clipbubble").contains { $0.processIdentifier != me }
    print(SyncStatus.report(running: running))
    exit(0)
}
if CommandLine.arguments.contains("--update") { Updater.runFromTerminal() }
if CommandLine.arguments.contains("--mcp") {
    MCP.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
