import json
import os
import random
import threading
import time
import unittest
import uuid
from pathlib import Path

from clipbubble import engine as eng
from clipbubble import sync
from clipbubble.sync import Blob, Entry, Hello, Stamp

FIXTURES = Path(__file__).resolve().parents[2] / "Tests/fixtures/sync/frames.json"

FRAMES = {
    "hello": (sync.HELLO, Hello(1, "3F2A-mac", "Rohit's MacBook", "macos", "1.4.0", 1792000000.25)),
    "summary": (sync.SUMMARY, [Stamp("t:abc", 1792000000.5, False), Stamp("i:def", 1791999999, True)]),
    "summary-empty": (sync.SUMMARY, []),
    "put-text": (sync.PUT, Entry("t:01", 1792000001, "text", "héllo\nwörld 👋", "Safari", "3F2A-mac")),
    "put-image": (sync.PUT, Entry("i:ff", 1792000002, "image", "", "Figma", "rog", (Blob("ff.png", 1234, "ff"),))),
    "put-files": (sync.PUT, Entry("f:9", 1792000003, "file", "a.pdf\nb c.zip", "Finder", "3F2A-mac",
                                  (Blob("a.pdf", 10, ""), Blob("b c.zip", 30_000_000_000, "")))),
    "tombstone": (sync.TOMBSTONE, Stamp("t:01", 1792000004, True)),
    "fetch": (sync.FETCH, ("f:9", 1, 262144)),
    "chunk": (sync.CHUNK, ("f:9", 0, 0, 10, bytes([0, 1, 2, 255, 254, 10, 13, 0, 7, 9]))),
    "cancel": (sync.CANCEL, "f:9"),
    "applied": (sync.APPLIED, "t:01"),
    "ping": (sync.PING, 1792000005.125),
    "pong": (sync.PONG, 1792000005.125),
    "offer": (sync.OFFER, "f:9"),
    "device": (sync.DEVICE, ("ad03-rog", "ROG Strix ☕", "linux")),
}


class Codec(unittest.TestCase):
    def test_matches_swift_bytes(self):
        committed = {r["name"]: r["hex"] for r in json.loads(FIXTURES.read_text())}
        self.assertEqual(set(committed), set(FRAMES))
        for name, frame in FRAMES.items():
            self.assertEqual(sync.encode(frame).hex(), committed[name], name)
            self.assertEqual(sync.FrameReader().feed(bytes.fromhex(committed[name])), [frame], name)

    def test_split_reads(self):
        data = b"".join(sync.encode(f) for f in FRAMES.values())
        r, got = sync.FrameReader(), []
        for i in range(0, len(data), 7):
            got += r.feed(data[i:i + 7])
        self.assertEqual(got, list(FRAMES.values()))

    def test_rejects_bad_input(self):
        with self.assertRaises(sync.Malformed):
            sync.FrameReader().feed(b"\x7f\xff\xff\xff")
        with self.assertRaises(sync.Malformed):
            sync.FrameReader().feed(b"\0\0\0\0")
        body = sync.encode((sync.PING, 1.0))[4:]
        for bad in (body[:-1], body + b"\0", b"\x63", b"\x09" + bytes.fromhex("7ff8000000000000"),
                    b"\x02\xff\xff\xff\xff"):
            with self.assertRaises(sync.Malformed):
                sync.decode(bad)

    def test_fuzz_never_crashes(self):
        rnd = random.Random(7)
        seeds = [sync.encode(f)[4:] for f in FRAMES.values()]
        for _ in range(3000):
            b = bytearray(rnd.choice(seeds))
            for _ in range(rnd.randint(1, 4)):
                if b:
                    b[rnd.randrange(len(b))] = rnd.randrange(256)
            try:
                sync.decode(bytes(b))
            except sync.Malformed:
                pass


class Merge(unittest.TestCase):
    def test_rules(self):
        a = Stamp("t:x", 10, False)
        self.assertEqual(sync.merge(None, False, a), "insert")
        self.assertEqual(sync.merge(Stamp("t:x", 5, False), True, a), "bump")
        self.assertEqual(sync.merge(Stamp("t:x", 20, False), True, a), "ignore")
        self.assertEqual(sync.merge(a, True, Stamp("t:x", 10, True)), "delete")
        self.assertEqual(sync.merge(Stamp("t:x", 10, True), False, a), "ignore")

    def test_order_independent(self):
        rnd = random.Random(3)
        for _ in range(300):
            events = [Stamp(rnd.choice("abc"), rnd.randint(0, 5), rnd.random() < 0.4) for _ in range(8)]
            results = set()
            for _ in range(4):
                rnd.shuffle(events)
                state = {}
                for e in events:
                    if sync.merge(state.get(e.hash), e.hash in state, e) != "ignore":
                        state[e.hash] = e
                results.add(tuple(sorted(state.items())))
            self.assertEqual(len(results), 1)

    def test_device_frames_only_for_new_versions(self):
        def reads(v):
            return Hello(1, "", "", "", v, 0).reads_devices
        self.assertFalse(reads("1.6.1") or reads("1.5.0") or reads("1.6"), "releases before 1.6.2 close the link on them")
        self.assertTrue(reads("1.6.2") and reads("1.6.10") and reads("1.7") and reads("2.0.0"))
        self.assertTrue(reads("dev"), "a dev build runs this code")

    def test_reconcile(self):
        mine = [Stamp("a", 5, False), Stamp("b", 5, False), Stamp("c", 5, True)]
        theirs = [Stamp("a", 6, False), Stamp("b", 5, False)]
        self.assertEqual(sync.reconcile(mine, theirs), [Stamp("c", 5, True)])


class ReceivedFiles(unittest.TestCase):
    """One screenshot once landed on a Mac 68 times: Universal Clipboard bounced each received copy back as a new item."""

    def test_names(self):
        folder = Path(os.environ["CLIPBUBBLE_HOME"]) / "unique"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "shot.png").write_bytes(b"a")
        self.assertEqual(eng.unique_path(folder, "shot.png").name, "shot (2).png")
        (folder / "shot (2).png").write_bytes(b"b")
        self.assertEqual(eng.unique_path(folder, "shot (2).png").name, "shot (3).png", "counts on instead of stacking (2)")
        self.assertEqual(eng.unique_path(folder, "notes").name, "notes")
        self.assertEqual(eng.numbered("at 11.40.14 PM (4)"), ("at 11.40.14 PM", 4, ""), "an extension has no spaces")
        long = "shot (2) " * 30 + "end.png"
        self.assertEqual(len(eng.safe_file_name(long)), 200)
        self.assertTrue(eng.safe_file_name(long).endswith(".png"), "a long name is cut before its extension")

    def test_same_bytes_keep_one_copy(self):
        data = bytes((i * 13) & 0xFF for i in range(3000))

        def receive(name, body):
            d = eng.Download("f:" + uuid.uuid4().hex, "file", [name], [""], [len(body)], "Bouncer", True)
            self.assertEqual(d.write(body, len(body)), "done")
            return d

        first = receive("Screenshot.png", data)
        self.assertFalse(first.bounced)
        again, echoed = receive("Screenshot.png", data), receive("Screenshot (2).png", data)
        self.assertEqual(again.paths, first.paths)
        self.assertEqual(echoed.paths, first.paths, "the same bytes again keep the one file")
        self.assertTrue(again.bounced and echoed.bounced, "a copy saved moments ago is a bounce")
        other = receive("Screenshot.png", data[::-1])
        self.assertTrue(other.paths[0].endswith("/Screenshot (2).png") and not other.bounced, "different bytes get their own file")
        self.assertEqual(len(os.listdir(eng.received_folder("Bouncer"))), 2, "nothing else was saved")

        # A bounced file isn't put on the clipboard, where it would go round again.
        e = eng.Engine()
        applied = []
        e.apply = applied.append

        class Peer:
            offered = {}

            def send(self, frame):
                pass

        bounced = receive("Screenshot.png", data)
        done = threading.Event()

        def finish():
            e.db.insert(Entry(bounced.hash, time.time() + 60, "file", "Screenshot.png", "iPhone", "mac",
                              (Blob("Screenshot.png", len(data), ""),)), "mac")
            e.finished(bounced, Peer())
            done.set()
        e.post(finish)
        self.assertTrue(done.wait(5))
        self.assertEqual(applied, [], "a bounced file stays off the clipboard")
