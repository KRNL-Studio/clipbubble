"""Drive separate SQLite stores and processes using the production Direct Sync transport."""

import json
import os
import random
import ssl
import struct
import subprocess
import sys
import time
import zlib
from contextlib import contextmanager
from pathlib import Path

from clipbubble import direct, engine, store

LOOPBACK = "127.0.0.1"
SWIFT_NAME = "Swift Interop"
PYTHON_NAME = "Python Interop"
TIMEOUT = 22


def require(condition, description):
    if not condition:
        raise AssertionError(description)


class Exchange:
    """Exchange test inputs and results out of band, never clipboard or pairing replies."""

    def __init__(self, root):
        self.root = root
        self.child = None

    def write(self, name, value):
        path = self.root / name
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps(value), encoding="utf-8")
        temp.replace(path)

    def read(self, name):
        return json.loads((self.root / name).read_text(encoding="utf-8"))

    def wait(self, description, ready, seconds=TIMEOUT):
        deadline = time.monotonic() + seconds
        while not ready():
            if self.child is not None and self.child.poll() is not None:
                raise AssertionError(f"Swift exited with {self.child.returncode} before {description}")
            require(time.monotonic() < deadline, f"Timed out waiting for {description}")
            time.sleep(0.025)

    def await_file(self, name, seconds=TIMEOUT):
        self.wait(name, (self.root / name).is_file, seconds)
        return self.read(name)


@contextmanager
def swift_process(binary, role, exchange):
    home = exchange.root / "swift-home"
    env = dict(os.environ, CLIPBUBBLE_HOME=str(home), CLIPBUBBLE_DOWNLOADS=str(home / "Downloads"),
               CLIPBUBBLE_DEVICE_NAME=SWIFT_NAME)
    child = subprocess.Popen([binary, role, str(exchange.root)], env=env)
    exchange.child = child
    try:
        yield child
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


def png(seed):
    """A valid opaque RGB PNG large enough to go through multiple CHUNK frames."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    width, height = 384, 256
    rng = random.Random(seed)
    rows = b"".join(b"\0" + rng.randbytes(3 * width) for _ in range(height))
    header = struct.pack(">2I5B", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def identity_info(identity, name):
    return dict(id=identity.device, fingerprint=identity.fingerprint, name=name, os=direct.OS)


def check_peer(peer, expected, description):
    require(peer is not None and all(getattr(peer, key) == value for key, value in expected.items()), description)


def hand_to_engine(sync, stream, peer):
    session = engine.Session(None, None, sync, stream, peer)
    sync.post(lambda: sync.begin(session))


def verify_sync(db, exchange, remote, swift_text, swift_png, child):
    text_hash = "t:" + store.sha(swift_text)
    image_hash = "i:" + store.sha(swift_png)

    def image_complete():
        clip = db.clip(hash=image_hash)
        return clip is not None and not clip.remote

    exchange.wait("Python SQLite text " + text_hash, lambda: db.clip(hash=text_hash) is not None)
    exchange.wait("Python SQLite PNG " + image_hash, image_complete)
    text, image = db.clip(hash=text_hash), db.clip(hash=image_hash)
    require(text.kind == "text" and text.text == swift_text and text.hash == text_hash and text.origin == remote["id"],
            "Python stored different text, hash or origin")
    require(image.kind == "image" and image.file and image.origin == remote["id"],
            "Python did not store the downloaded Swift PNG and its origin")
    data = Path(image.file).read_bytes()
    require(data == swift_png and image.hash == "i:" + store.sha(data), "Python stored different PNG bytes or hash")
    exchange.write("python-received.json", True)
    exchange.await_file("swift-received.json")
    require(child.wait(timeout=5) == 0, "Swift interop process failed")
    print("PASS  mTLS sync both ways: SQLite text, origin, PNG bytes and SHA-256")


def python_server(binary, exchange, sync, identity, db, swift_text, swift_png):
    approvals = []

    def approve(peer, formatted, expires):
        code = formatted.replace(" ", "")
        swift_code = exchange.await_file("swift-sas.json", max(0, expires - time.monotonic()))
        check_peer(peer, exchange.read("swift-nearby.json"), "Python received the wrong Nearby identity")
        require(len(code) == 6 and code.isascii() and code.isdecimal() and code == swift_code,
                f"SAS differs (Swift {swift_code}, Python {code})")
        approvals.append(code)
        return True

    with direct.DirectServer(identity, sync.direct_peers, sync.name, host=LOOPBACK, port=0,
                             approve=approve, approval_timeout=TIMEOUT,
                             on_sync=lambda stream, peer: hand_to_engine(sync, stream, peer)) as server:
        qr, invitation = server.invite([LOOPBACK])
        exchange.write("python-server.json", dict(device=identity_info(identity, sync.name), port=server.port, qr=qr))
        with swift_process(binary, "client", exchange) as child:
            exchange.await_file("swift-unpaired.json")
            print("PASS  Python returns 'unpaired' to a Swift identity over mTLS")
            exchange.await_file("swift-nearby-paired.json")
            nearby = exchange.read("swift-nearby.json")
            check_peer(sync.direct_peers.by_id(nearby["id"]), nearby, "Python did not persist the Swift Nearby pin")
            require(approvals == [exchange.read("swift-sas.json")], "Python did not approve exactly one matching SAS")
            print(f"PASS  Swift → Python Nearby pairing and stored pins (SAS {approvals[0]})")
            exchange.await_file("swift-paired.json")
            remote = exchange.read("swift-device.json")
            check_peer(sync.direct_peers.by_id(remote["id"]), remote, "Python did not persist the Swift QR pin")
            require(invitation.done.wait(1) and invitation.result == remote["name"], "Python QR invitation was not consumed")
            print("PASS  Swift → Python QR pairing and stored pins")
            verify_sync(db, exchange, remote, swift_text, swift_png, child)


def python_client(binary, exchange, sync, identity, db, swift_text, swift_png):
    nearby_dir = exchange.root / "python-nearby"
    nearby = direct.DirectIdentity(nearby_dir)
    nearby_peers = direct.DirectPeers(nearby_dir)
    nearby_name = sync.name + " Nearby"
    exchange.write("python-nearby.json", identity_info(nearby, nearby_name))
    exchange.write("python-device.json", identity_info(identity, sync.name))
    with swift_process(binary, "server", exchange) as child:
        info = exchange.await_file("swift-server.json")
        remote = info["device"]
        target = direct.DirectPeer(**remote, addresses=(LOOPBACK,), port=info["port"])
        client = direct.DirectPairingClient(nearby, nearby_peers, nearby_name)
        client.pair(target, lambda code: exchange.write("python-sas.json", code.replace(" ", "")))
        check_peer(nearby_peers.by_id(remote["id"]), remote, "Python did not persist the Swift Nearby pin")
        code = exchange.await_file("swift-sas.json")
        require(len(code) == 6 and code.isascii() and code.isdecimal() and code == exchange.read("python-sas.json"),
                "Swift and Python computed different six-digit SAS codes")
        client = direct.DirectPairingClient(identity, sync.direct_peers, sync.name)
        paired = client.pair_qr(info["qr"])
        check_peer(sync.direct_peers.by_id(remote["id"]), remote, "Python did not persist the Swift QR pin")
        require(paired.addresses == (LOOPBACK,) and paired.port == info["port"], "Python QR endpoint differs from Swift listener")
        exchange.write("python-paired.json", True)
        exchange.await_file("swift-paired.json")
        print(f"PASS  Python → Swift Nearby pairing and stored pins (SAS {code})")
        print("PASS  Python → Swift QR pairing and stored pins")
        with direct.DirectTunnel.connect(identity, paired) as stream:
            hand_to_engine(sync, stream, paired)
            verify_sync(db, exchange, remote, swift_text, swift_png, child)


def main(role, binary, root):
    root.mkdir()
    exchange = Exchange(root)
    print(f"=== Swift {role} / Python {'server' if role == 'client' else 'client'} ({ssl.OPENSSL_VERSION}) ===")
    swift_text = "Swift clipboard 🌱\nSecond line"
    python_text = "Python clipboard 🌿\nSecond line"
    swift_png, python_png = png(1), png(2)
    exchange.write("fixtures.json", {"swift": swift_text, "python": python_text})
    (root / "swift.png").write_bytes(swift_png)
    (root / "python.png").write_bytes(python_png)

    db = store.DB()
    image_hash = store.sha(python_png)
    image = store.IMAGES / (image_hash + ".png")
    image.write_bytes(python_png)
    db.upsert("text", python_text, None, "Interop", "t:" + store.sha(python_text))
    db.upsert("image", "", str(image), "Interop", "i:" + image_hash)
    sync = engine.Engine(PYTHON_NAME)
    identity = direct.DirectIdentity(store.DIR, sync.device)
    scenario = python_server if role == "client" else python_client
    try:
        scenario(binary, exchange, sync, identity, db, swift_text, swift_png)
    except Exception:
        if (root / "swift-error.json").is_file():
            print("Swift approval: " + exchange.read("swift-error.json"), file=sys.stderr)
        for path in (store.DIR / "sync.log", root / "swift-home" / "sync.log"):
            if path.exists():
                print(f"{path.name} ({path.parent.name}):\n{path.read_text()}", file=sys.stderr)
        raise


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], Path(sys.argv[3]))
