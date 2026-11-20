import json
import os
import tempfile
import unittest
from pathlib import Path

from clipbubble import engine, peers, store

KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPqR3mUOcskK0AMMwJekuAgZW350J/juYdkvePQaexfg"


class Classify(unittest.TestCase):
    """Each way a link fails gets its own state, in the order a connection goes. Samples are what OpenSSH prints."""

    def test_states(self):
        cases = {
            "ssh: Could not resolve hostname old-mac: Name or service not known": "unresolved",
            "ssh: connect to host 10.0.0.9 port 22: Connection refused": "refused",
            "No ED25519 host key is known for rog and you have requested strict checking.\nHost key verification failed.": "unknown-host",
            "@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n@@@@@\nHost key verification failed.": "host-key-changed",
            "rohitgoyal@old-mac: Permission denied (publickey).": "needs-key",
            "CLIPBUBBLE_NOT_INSTALLED": "not-installed",
            "CLIPBUBBLE_NOT_RUNNING": "not-running",
        }
        for err, kind in cases.items():
            self.assertEqual(engine.classify(err)[0], kind, err)
        self.assertIsNone(engine.classify("ssh: connect to host rog port 22: Operation timed out"))

    def test_login_failure_names_who(self):
        self.assertEqual(engine.classify("rohitgoyal@old-mac: Permission denied (publickey)."), ("needs-key", "rohitgoyal@old-mac"))
        self.assertIn("rohitgoyal@old-mac wasn't let in", engine.state_text(("needs-key", "rohitgoyal@old-mac")))
        self.assertEqual(engine.classify("Received disconnect: Too many authentication failures"), ("needs-key", ""))

    def test_only_network_trouble_retries_soon(self):
        for kind in ["offline", "unresolved", "refused"]:
            self.assertIn(kind, engine.TRANSIENT)
        for kind in ["unknown-host", "host-key-changed", "needs-key", "not-installed"]:
            self.assertNotIn(kind, engine.TRANSIENT)


class Peers(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.saved = store.DIR
        store.DIR = peers.store.DIR = self.dir

    def tearDown(self):
        store.DIR = peers.store.DIR = self.saved

    def test_codes(self):
        c = peers.make_code()
        self.assertEqual(len(c), 8)
        self.assertTrue(all(ch in peers.ALPHABET for ch in c))
        self.assertTrue(peers.same_code(f" {c[:4].lower()} - {c[4:]} ", c))
        self.assertFalse(peers.same_code("AAAAAAAA", c if c != "AAAAAAAA" else "BBBBBBBB"))

    def test_target(self):
        self.assertEqual(peers.target("rog.local", "k7qm-4ztd"), (["rog.local"], 47821, "K7QM4ZTD"))
        self.assertEqual(peers.target("10.0.0.9:5000", "K7QM4ZTD"), (["10.0.0.9"], 5000, "K7QM4ZTD"))
        self.assertEqual(peers.target("clipbubble://pair?h=a.local,10.0.0.9&p=47821&c=abc", ""), (["a.local", "10.0.0.9"], 47821, "abc"))
        self.assertIsNone(peers.target("rog.local", "123"))
        self.assertIsNone(peers.target("-oProxyCommand=x", "K7QM4ZTD"))

    def test_fingerprint_matches_ssh_keygen(self):
        # ssh-keygen -lf on the same key prints this.
        self.assertEqual(peers.fingerprint(KEY), "SHA256:PTl11TrTbZVxMmYzWAEaSotTJsVhsO9OMdNsevMhAK0")

    def test_saved_peer_pins_its_key_and_leaves_ssh_config_alone(self):
        p = {"alias": peers.free_alias("Rohit's MacBook Air", ["clipbubble-rohit-s-macbook-air"]), "name": "Rohit's MacBook Air",
             "user": "rohit", "host": "air.local", "hostKey": KEY}
        self.assertEqual(p["alias"], "clipbubble-rohit-s-macbook-air-2")
        peers.save(p)
        self.assertEqual(peers.peer(p["alias"])["user"], "rohit")
        self.assertEqual((self.dir / "known_hosts").read_text(), f"{p['alias']} {KEY}\n")
        args = peers.ssh_args(p["alias"])
        self.assertIn("StrictHostKeyChecking=yes", args)
        self.assertIn(f"HostKeyAlias={p['alias']}", args)
        self.assertEqual(args[-3:], ["rohit", "--", "air.local"])
        self.assertIsNone(peers.ssh_args("some-config-host"))
        peers.remove(p["alias"])
        self.assertIsNone(peers.peer(p["alias"]))
        self.assertEqual((self.dir / "known_hosts").read_text(), "\n")

    def test_status_has_no_history(self):
        store.Prefs.set("sync.hosts", ["rog"])
        peers.write_status({"rog": ("live", "ROG")}, engine.state_text, "Studio", False)
        s = json.loads((self.dir / "status.json").read_text())
        self.assertEqual(s["links"][0]["state"], "live")
        self.assertEqual(set(s), {"updated", "name", "identity", "paused", "links"})
        self.assertIn("Nothing from your history", peers.report(running=True))


if __name__ == "__main__":
    unittest.main()
