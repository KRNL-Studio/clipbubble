"""clipbubble: the app (default), --pair (link an iPhone or computer), --link ADDRESS CODE (link to a computer),
--status, --peer (run by ssh), --peer-stdio (tests), --mcp, --version."""
import os
import signal
import sys
import time


def has_display():
    try:
        import gi
        gi.require_version("Gtk", "4.0")
        gi.require_version("Gdk", "4.0")
        from gi.repository import Gdk, Gtk
    except (ImportError, ValueError):
        return None   # no GTK at all
    # PyGObject's init_check says True even when it found no display.
    Gtk.init_check()
    return Gdk.Display.get_default() is not None


def desktop_appeared():
    """The Wayland socket a compositor is answering on, if any. One left behind by a crash refuses the connection."""
    import socket
    run = os.environ.get("XDG_RUNTIME_DIR", "")
    try:
        names = sorted(n for n in os.listdir(run) if n.startswith("wayland-") and not n.endswith(".lock"))
    except OSError:
        return None
    for n in names:
        with socket.socket(socket.AF_UNIX) as s:
            try:
                s.connect(os.path.join(run, n))
                return n
            except OSError:
                pass
    return None


def run_app():
    from .engine import Engine
    from .store import DB
    gui = has_display()
    if gui:
        from .ui import run
        run()
        return
    # No desktop: a server, or the login screen after logging out. History still syncs and agents still see it;
    # once someone logs in, start over as the full app.
    engine = Engine()
    engine.start()
    last_prune = 0
    while True:
        if time.time() - last_prune > 3600:
            DB().prune()
            last_prune = time.time()
        time.sleep(5)
        display = gui is False and desktop_appeared()
        if display:
            os.environ["WAYLAND_DISPLAY"] = display
            os.execv(sys.executable, [sys.executable, "-P", "-m", "clipbubble"])


def run_peer_stdio():
    from .engine import Engine, log
    engine = Engine()
    applied = os.path.join(os.environ.get("CLIPBUBBLE_HOME", "."), "applied.txt")

    def apply(c):
        with open(applied, "a") as f:
            f.write(c.hash + "\n")

    engine.apply = apply
    engine.serve_stdio()


def run_pair():
    """Link iPhone from a terminal: for a machine without a desktop, or one you're logged in to over SSH."""
    import socket
    import threading
    from . import pairing, peers, qr
    if not pairing.ssh_server_on():
        print("Start the SSH server first, so the iPhone can reach this machine. "
              "On Ubuntu or Debian: sudo apt install openssh-server")
        sys.exit(1)
    done, result = threading.Event(), []
    server = pairing.Server(os.environ.get("CLIPBUBBLE_DEVICE_NAME") or socket.gethostname(),
                            lambda name: (result.append(name), done.set()), on_expired=done.set)
    link = server.link()
    print(qr.terminal(link))
    print("Scan this with the iPhone's Camera, or in ClipBubble on the iPhone. It needs the same Wi-Fi as this machine.")
    print(f"Or open this link on the iPhone: {link}")
    print(f"To link another computer, enter {server.typed_address()} and the code {peers.display_code(server.short_code)} "
          "in its Add a computer… (or run clipbubble --link there).")
    hint = pairing.firewall_hint()
    if hint:
        print(hint)
    sys.stdout.flush()
    try:
        done.wait()
    except KeyboardInterrupt:
        server.stop()
        sys.exit(130)
    if not result:
        print("That code expired. Run clipbubble --pair again for a new one.")
        sys.exit(1)
    print(f"Linked {result[0]}. It syncs whenever ClipBubble is open there.")


def run_link(args):
    """clipbubble --link ADDRESS CODE [--yes]: links to a computer showing Link iPhone…, without writing SSH config."""
    import socket
    from . import peers, store
    from .engine import ssh_hosts
    rest = [a for a in args if not a.startswith("--")]
    if len(rest) < 1 or (len(rest) < 2 and not rest[0].startswith("clipbubble://")):
        print("Usage: clipbubble --link ADDRESS CODE. On the other computer, open Link iPhone… (or run clipbubble --pair) "
              "and use the address and code it shows.")
        sys.exit(2)
    name = os.environ.get("CLIPBUBBLE_DEVICE_NAME") or socket.gethostname()
    try:
        host, user, their_name, host_key = peers.link(rest[0], rest[1] if len(rest) > 1 else "", name)
    except (peers.LinkError, OSError, ValueError, subprocess_error()) as e:
        print(e)
        sys.exit(1)
    p = {"alias": peers.free_alias(their_name, ssh_hosts()), "name": their_name, "user": user, "host": host, "hostKey": host_key}
    print(f"Ready to link with {their_name}.")
    print(f"  Connects as {peers.summary(p)}")
    fp = peers.fingerprint(host_key)
    print(f"  Its identity is {fp}. It should match the one ClipBubble shows there." if fp
          else "  It didn't send its identity; check it the first time it connects.")
    print("  That key can only run ClipBubble there: no shell, no files, no forwarding.")
    print("  Syncing shares what you copy, plus screenshots and downloads if they're on in Settings.")
    start = "--yes" in args
    if not start and sys.stdin.isatty():
        start = input("Start syncing now? [y/N] ").strip().lower() in ("y", "yes")
    peers.save(p)
    if start:
        hosts = store.Prefs.get("sync.hosts", [])
        if p["alias"] not in hosts:
            store.Prefs.set("sync.hosts", hosts + [p["alias"]])
        print(f"Syncing with {their_name}. ClipBubble picks it up within a few seconds, or when it next starts.")
    else:
        print(f"Saved as {p['alias']}, switched off. Turn it on in Settings → Sync over SSH when you're ready.")


def subprocess_error():
    import subprocess
    return subprocess.CalledProcessError


def run_status():
    import socket
    from . import peers, store
    running = False
    with socket.socket(socket.AF_UNIX) as s:
        try:
            s.connect(str(store.socket_path()))
            running = True
        except OSError:
            pass
    print(peers.report(running))


def main():
    args = sys.argv[1:]
    if "--version" in args:
        from .engine import VERSION
        print(VERSION)
    elif "--peer" in args:
        from .engine import relay
        relay()
    elif "--peer-stdio" in args:
        run_peer_stdio()
    elif "--pair" in args:
        run_pair()
    elif "--link" in args:
        run_link(args)
    elif "--status" in args:
        run_status()
    elif "--mcp" in args:
        from .mcp import Server
        Server().run()
    else:
        run_app()


main()
