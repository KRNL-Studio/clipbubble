"""Direct Sync v2 on real TLS sockets, independent of SSH and the clipboard."""
import datetime
import hashlib
import os
import select
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import closing
from dataclasses import replace
from pathlib import Path
from queue import Queue

from clipbubble import direct, store


class DirectIdentityTests(unittest.TestCase):
    def test_persistent_v3_identity(self):
        with tempfile.TemporaryDirectory() as home:
            identity = direct.DirectIdentity(home)
            pem = identity.cert_path.read_text()
            self.assertEqual(identity.fingerprint, hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest())
            self.assertRegex(identity.fingerprint, r"^[0-9a-f]{64}$")
            self.assertEqual(stat.S_IMODE(identity.key_path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(identity.cert_path.stat().st_mode), 0o644)
            self.assertEqual(direct.DirectIdentity(home).fingerprint, identity.fingerprint)
            self.assertEqual(direct.DirectIdentity(home).device, identity.device)
            cert = subprocess.check_output(["openssl", "x509", "-in", str(identity.cert_path), "-text", "-noout"],
                                           text=True)
            for expected in ("Version: 3", "prime256v1", "ecdsa-with-SHA256", "CA:FALSE", "Digital Signature",
                             "TLS Web Server Authentication, TLS Web Client Authentication"):
                self.assertIn(expected, cert)
            decoded = ssl._ssl._test_decode_cert(str(identity.cert_path))
            self.assertEqual(decoded["subject"], ((("commonName", f"clipbubble-{identity.device}"),),))
            self.assertEqual(decoded["issuer"], decoded["subject"])
            self.assertAlmostEqual(time.time() - ssl.cert_time_to_seconds(decoded["notBefore"]), 86400, delta=20)
            now = datetime.datetime.now(datetime.timezone.utc)
            end = now.replace(year=now.year + 20, day=min(now.day, 28) if now.month == 2 else now.day)
            self.assertAlmostEqual(ssl.cert_time_to_seconds(decoded["notAfter"]), end.timestamp(), delta=86420)

    def test_sas_golden_vector_including_leading_zero(self):
        low, high = "0" * 64, "0" * 62 + "05"
        self.assertEqual(direct.pair_code(low, high), "027982")
        self.assertEqual(direct.pair_code(high, low), "027982")
        self.assertEqual(direct.display_code("027982"), "027 982")


class DirectTransportTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        home = Path(temp.name)
        self.a = direct.DirectIdentity(home / "a")
        self.b = direct.DirectIdentity(home / "b")
        self.a_peers = direct.DirectPeers(home / "a")
        self.b_peers = direct.DirectPeers(home / "b")
        self.client = direct.DirectPairingClient(self.a, self.a_peers, "Client")

    def server(self, **kwargs):
        server = direct.DirectServer(self.b, self.b_peers, "Server", host="127.0.0.1", port=0, **kwargs)
        self.addCleanup(server.close)
        return server

    def target(self, server):
        return direct.DirectPeer(self.b.device, "Server", "linux", self.b.fingerprint, ("127.0.0.1",), server.port)

    def test_rejects_certificate_less_and_untrusted_sync(self):
        accepted = Queue()
        server = self.server(on_sync=lambda stream, peer: accepted.put(peer))
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with socket.create_connection(("127.0.0.1", server.port), timeout=2) as tcp:
            # TLS 1.3 can report a missing client certificate on the client's first read.
            with self.assertRaises(ssl.SSLError):
                with ctx.wrap_socket(tcp) as tls:
                    tls.recv(1)
        with self.assertRaises(direct.NeedsKeyAuth):
            direct.DirectTunnel.connect(self.a, self.target(server))
        self.assertTrue(accepted.empty())
        self.assertEqual(self.a_peers.all(), [])
        self.assertEqual(self.b_peers.all(), [])

    def test_nearby_sas_confirm_decline_and_rate_limit(self):
        seen = []

        def approve(peer, code, deadline):
            seen.append((peer, code))
            return len(seen) == 1

        server = self.server(approve=approve)
        target = replace(self.target(server), fingerprint=self.b.fingerprint[:16])
        shown = []
        paired = self.client.pair(target, shown.append)
        self.assertEqual(paired.fingerprint, self.b.fingerprint)
        self.assertEqual(seen[0][0].id, self.a.device)
        self.assertEqual(seen[0][1], shown[0])
        self.assertEqual(self.b_peers.by_fingerprint(self.a.fingerprint).alias, "direct:" + self.a.device)
        for _ in range(4):
            with self.assertRaisesRegex(direct.DirectError, "Declined on Server"):
                self.client.pair(target, shown.append)
        with self.assertRaisesRegex(direct.DirectError, "Too many pairing requests"):
            self.client.pair(target, shown.append)
        self.assertEqual(len(seen), 5)

    def test_nearby_approval_timeout(self):
        server = self.server(approve=lambda *args: time.sleep(0.08) or True, approval_timeout=0.02)
        with self.assertRaisesRegex(direct.DirectError, "Declined on Server"):
            self.client.pair(self.target(server), lambda code: None)
        self.assertFalse(self.b_peers.all())

    def test_qr_pin_wrong_code_success_and_replay(self):
        server = self.server()
        url, invite = server.invite(("127.0.0.1",))
        _, token = direct.qr_target(url)
        wrong = "0" * 32 if token != "0" * 32 else "1" * 32
        with self.assertRaises(direct.HostKeyChanged):
            self.client.pair_qr(url.replace(self.b.fingerprint, self.a.fingerprint))
        self.assertEqual(invite.wrong, 0, "the client never sent its token to an unpinned endpoint")
        self.assertFalse(self.b_peers.all())
        with self.assertRaisesRegex(direct.DirectError, "Invalid or expired"):
            self.client.pair_qr(url.replace(token, wrong))
        self.assertEqual(invite.wrong, 1)
        peer = self.client.pair_qr(url)
        self.assertEqual(peer, self.target(server))
        self.assertEqual(self.a_peers.by_id(peer.id), peer)
        self.assertEqual(stat.S_IMODE(self.a_peers.path.stat().st_mode), 0o600)
        self.assertEqual(self.b_peers.by_id(self.a.device).fingerprint, self.a.fingerprint)
        with self.assertRaisesRegex(direct.DirectError, "Invalid or expired"):
            self.client.pair_qr(url)

    def test_qr_expires_and_locks_after_five_wrong_guesses(self):
        server = self.server()
        url, invite = server.invite(("127.0.0.1",))
        wrong = "0" * 32 if invite.token != "0" * 32 else "1" * 32
        for _ in range(5):
            with self.assertRaisesRegex(direct.DirectError, "Invalid or expired"):
                self.client.pair_qr(url.replace(invite.token, wrong))
        self.assertTrue(invite.done.wait(1))
        with self.assertRaisesRegex(direct.DirectError, "Invalid or expired"):
            self.client.pair_qr(url)
        url, invite = server.invite(("127.0.0.1",))
        invite.expires = time.monotonic() - 1
        with self.assertRaisesRegex(direct.DirectError, "Invalid or expired"):
            self.client.pair_qr(url)
        self.assertFalse(self.b_peers.all())

    def test_tls_stream_hands_off_bytes_and_requires_device_match(self):
        accepted = Queue()
        server = self.server(on_sync=lambda stream, peer: accepted.put((stream, peer)))
        self.client.pair_qr(server.invite(("127.0.0.1",))[0])
        tls, _, end = direct._connect(self.a, ("127.0.0.1",), server.port, self.b.fingerprint)
        with tls:
            tls.send_json({"mode": "sync", "v": 2, "device": self.b.device}, end)
            self.assertEqual(tls.read_json(end), {"ok": False, "error": "unpaired"})
        self.assertTrue(accepted.empty())
        with direct.DirectTunnel.connect(self.a, self.target(server)) as client:
            stream, peer = accepted.get(timeout=2)
            with stream:
                self.assertEqual(peer.id, self.a.device)
                if ssl.HAS_TLSv1_3:
                    self.assertEqual(client.sock.version(), "TLSv1.3")
                stream.send_json({"ok": True}, time.monotonic() + 2)
                stream.sendall(b"frame")
                self.assertEqual(client.read_json(time.monotonic() + 2), {"ok": True})
                self.assertEqual(client.recv(5, time.monotonic() + 2), b"frame")
            self.assertEqual(stream.sock.fileno(), -1)
        self.assertEqual(client.sock.fileno(), -1)


ENGINE_SCRIPT = """
import sys
import threading
from clipbubble import engine, store

e = engine.Engine()
e.start()

def listening():
    assert e.direct_server
    print(e.direct_server.port, flush=True)

def stop():
    for link in list(e.links.values()):
        link.stop()
    for session in list(e.sessions):
        session.close()
    e.direct_control.close()
    e.discovery.close()
    e.direct_server.close()
    e.db.c.close()
    done.set()

done = threading.Event()
e.post(listening)
sys.stdin.readline()
e.post(stop)
assert done.wait(5)
"""


class DirectEngineTests(unittest.TestCase):
    def start_engine(self, home, name):
        proc = subprocess.Popen([sys.executable, "-W", "error::ResourceWarning", "-c", ENGINE_SCRIPT],
                                env=dict(os.environ, CLIPBUBBLE_HOME=str(home), CLIPBUBBLE_DEVICE_NAME=name),
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        def stop():
            try:
                _, errors = proc.communicate("\n", timeout=6)
            except subprocess.TimeoutExpired:
                proc.kill()
                _, errors = proc.communicate()
            self.assertEqual(proc.returncode, 0, errors)
            self.assertNotIn("ResourceWarning", errors)

        self.addCleanup(stop)
        self.assertTrue(select.select([proc.stdout], [], [], 5)[0], "engine startup timed out")
        return int(proc.stdout.readline())

    def test_cli_pair_and_two_way_engine_sync_then_revoke(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        first, second = Path(temp.name) / "a", Path(temp.name) / "b"
        first_port = self.start_engine(first, "First")
        second_port = self.start_engine(second, "Second")
        self.assertNotEqual(first_port, second_port, "the second listener falls back when the default port is occupied")

        def cli(home, *args):
            return subprocess.run([sys.executable, "-m", "clipbubble", *args],
                                  env=dict(os.environ, CLIPBUBBLE_HOME=str(home)),
                                  text=True, capture_output=True, check=True, timeout=6)

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as control:
            control.settimeout(5)
            control.connect(str(first / "peer.sock.direct"))
            control.sendall(b"Q")
            with control.makefile("r", encoding="utf-8") as replies:
                url = replies.readline().rstrip()
                peer, _ = direct.qr_target(url)
                self.assertEqual(peer.port, first_port, "QR uses the running engine's listener")
                self.assertIn("Linked 'First'", cli(second, "--link", url).stdout)
                self.assertTrue(replies.readline().strip())

        def seed(home, text):
            script = "from clipbubble.store import DB, sha; import sys; DB().upsert('text', sys.argv[1], None, 'Test', 't:' + sha(sys.argv[1]))"
            subprocess.run([sys.executable, "-c", script, text], check=True, timeout=6,
                           env=dict(os.environ, CLIPBUBBLE_HOME=str(home)))

        def wait_for_status(home, expected):
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                report = cli(home, "--status").stdout
                if expected in report:
                    return
                time.sleep(0.05)
            self.fail(f"Expected {expected!r} in {report}")

        def wait_for_text(home, text):
            import sqlite3
            hash_ = "t:" + store.sha(text)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                with closing(sqlite3.connect(home / "clips.sqlite")) as db:
                    row = db.execute("SELECT text FROM clips WHERE hash = ?", (hash_,)).fetchone()
                if row:
                    self.assertEqual(row[0], text)
                    return
                time.sleep(0.05)
            self.fail(f"Timed out waiting for {text!r} in {home}")

        wait_for_status(second, "Linked with First")
        seed(first, "from First over Direct")
        seed(second, "from Second over Direct")
        wait_for_text(first, "from Second over Direct")
        wait_for_text(second, "from First over Direct")
        cli(first, "--unlink-direct", direct.device_id(second))
        wait_for_status(second, "revoked this device")
        self.assertIsNone(direct.DirectPeers(first).by_id(direct.device_id(second)))


if __name__ == "__main__":
    unittest.main()
