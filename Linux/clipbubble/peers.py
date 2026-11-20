"""Computers linked with clipbubble --link, as the Mac's Add a computer does (Sources/Peers.swift). They live in
ClipBubble's own prefs and known_hosts, never in ~/.ssh/config, so linking can't change a connection you set up."""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import socket
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from . import store

PORT = 47821
# In ~/.ssh, except for tests and second instances (CLIPBUBBLE_HOME), which keep their own.
KEY = (Path(os.environ["CLIPBUBBLE_HOME"]) if os.environ.get("CLIPBUBBLE_HOME") else Path.home() / ".ssh") / "clipbubble_ed25519"
ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"


def known_hosts():
    return store.DIR / "known_hosts"


def all_peers():
    return [p for p in store.Prefs.get("sync.peers", []) if isinstance(p, dict) and p.get("alias")]


def peer(alias):
    return next((p for p in all_peers() if p["alias"] == alias), None)


def save(p):
    _store([q for q in all_peers() if q["alias"] != p["alias"]] + [p])


def remove(alias):
    _store([q for q in all_peers() if q["alias"] != alias])


def _store(peers):
    store.Prefs.set("sync.peers", peers)
    store.DIR.mkdir(parents=True, exist_ok=True)
    lines = [f"{p['alias']} {p['hostKey']}" for p in peers if p.get("hostKey")]
    known_hosts().write_text("\n".join(lines) + "\n")


def free_alias(name, taken):
    slug = "-".join(w for w in re.split(r"[^a-z0-9]+", name.lower()) if w)[:40] or "computer"
    base, used, n = "clipbubble-" + slug, set(taken) | {p["alias"] for p in all_peers()}, 2
    alias = base
    while alias in used:
        alias, n = f"{base}-{n}", n + 1
    return alias


def summary(p):
    return f"{p['user']}@{p['host']}, with the key {str(KEY).replace(str(Path.home()), '~', 1)}"


def ssh_args(alias):
    """For a linked computer: this key only, its pinned identity only, strict checking always. None for other hosts."""
    p = peer(alias)
    if not p:
        return None
    return ["-i", str(KEY), "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
            "-o", f"UserKnownHostsFile={known_hosts()}", "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=yes", "-o", f"HostKeyAlias={p['alias']}", "-l", p["user"], "--", p["host"]]


def public_key(name):
    """ClipBubble's own key, made the first time. Only its public half ever leaves this machine."""
    if not KEY.exists():
        KEY.parent.mkdir(mode=0o700, exist_ok=True)
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", f"ClipBubble on {name}", "-f", str(KEY)],
                       check=True, capture_output=True)
    parts = KEY.with_suffix(".pub").read_text().split()
    if len(parts) < 2 or parts[0] != "ssh-ed25519":
        raise ValueError("Couldn't make this machine's ClipBubble key.")
    return " ".join(parts[:2])


def fingerprint(key):
    """SHA256 fingerprint of a public key line, as ssh-keygen -l shows it."""
    parts = (key or "").split()
    if len(parts) < 2:
        return None
    try:
        blob = base64.b64decode(parts[1], validate=True)
    except ValueError:
        return None
    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")


# Short codes

def make_code():
    return "".join(secrets.choice(ALPHABET) for _ in range(8))


def display_code(code):
    return f"{code[:4]}-{code[4:]}" if len(code) == 8 else code


def normalize(typed):
    return "".join(ch for ch in str(typed).upper() if ch.isalnum())


def same_code(typed, code):
    return hmac.compare_digest(normalize(typed).encode(), code.encode())


# Linking

class LinkError(Exception):
    pass


def target(address, code):
    """(hosts, port, code) for what someone typed, or a whole clipbubble://pair link. None if it can't be one."""
    from urllib.parse import parse_qs, urlparse
    a = address.strip()
    u = urlparse(a)
    if u.scheme == "clipbubble" and u.netloc == "pair":
        q = parse_qs(u.query)
        try:
            return q["h"][0].split(","), int(q["p"][0]), q["c"][0]
        except (KeyError, IndexError, ValueError):
            return None
    c = normalize(code)
    if not a or " " in a or a.startswith("-") or len(c) != 8:
        return None
    if a.count(":") == 1:
        host, _, port = a.partition(":")
        if port.isdigit():
            return [host], int(port), c
    return [a], PORT, c


def link(address, code, name):
    """Sends ClipBubble's public key to the other computer's pairing listener. Returns (host, user, its name, host key)."""
    t = target(address, code)
    if not t:
        raise LinkError("Enter the address and code the other computer shows.")
    hosts, port, code = t
    req = json.dumps({"code": code, "key": public_key(name), "name": name}).encode() + b"\n"
    for host in hosts:
        try:
            with socket.create_connection((host, port), timeout=5) as c:
                c.settimeout(120)  # Windows asks its user before adding the key
                c.sendall(req)
                buf = b""
                while b"\n" not in buf and len(buf) <= 8192:
                    d = c.recv(4096)
                    if not d:
                        break
                    buf += d
        except OSError:
            continue
        if not buf.strip():
            raise LinkError("It stopped linking before answering. Show a new code there and try again.")
        try:
            r = json.loads(buf.split(b"\n", 1)[0])
        except ValueError:
            raise LinkError("It answered, but not like ClipBubble does.")
        if not r.get("ok") or not r.get("user"):
            raise LinkError(r.get("error") or "It said no. Check the code, or show a new one there and try again.")
        return host, r["user"], r.get("name") or host, r.get("hostKey") or ""
    raise LinkError("Couldn't reach it. Check the address, that Link iPhone… is open there, and that both are on the same network.")


# Status

def status_file():
    return store.DIR / "status.json"


def write_status(statuses, state_text, name, paused):
    links = []
    for alias in store.Prefs.get("sync.hosts", []):
        kind, arg = statuses.get(alias, ("connecting", ""))
        row = {"alias": alias, "state": kind, "text": state_text((kind, arg))}
        p = peer(alias)
        if p:
            row.update(name=p["name"], connection=summary(p), identity=fingerprint(p.get("hostKey")) or "")
        if kind == "live":
            row["name"] = arg
        last = store.Prefs.get("sync.lastLive." + alias)
        if last:
            row["lastLinked"] = datetime.fromtimestamp(last, timezone.utc).isoformat(timespec="seconds")
        links.append(row)
    from .pairing import host_key
    out = {"updated": datetime.now(timezone.utc).isoformat(timespec="seconds"), "name": name,
           "identity": fingerprint(host_key()) or "", "paused": paused, "links": links}
    store.DIR.mkdir(parents=True, exist_ok=True)
    tmp = status_file().with_suffix(".tmp")
    tmp.write_text(json.dumps(out, indent=1, sort_keys=True))
    tmp.replace(status_file())


def report(running):
    """`clipbubble --status`: link health only, never anything from the history."""
    try:
        s = json.loads(status_file().read_text())
    except (OSError, ValueError):
        return "ClipBubble is running but hasn't reported yet." if running else "ClipBubble isn't running, and has no status saved."
    lines = [s.get("name", "This machine") + ("" if running else " (ClipBubble isn't running; last known status)")]
    if s.get("identity"):
        lines.append(f"  Identity: {s['identity']}")
    if s.get("paused"):
        lines.append("  Sync is paused")
    links = s.get("links", [])
    if not links:
        lines.append("  No computers linked. Link one with clipbubble --link ADDRESS CODE.")
    for row in links:
        name = f"{row['name']} ({row['alias']})" if row.get("name") else row["alias"]
        lines += ["", f"{name}: {row.get('text', '')}"]
        if row.get("connection"):
            lines.append(f"  Connects as {row['connection']}")
        if row.get("lastLinked"):
            lines.append(f"  Last linked {row['lastLinked']}")
    lines += ["", f"Updated {s.get('updated', 'never')}. Nothing from your history is in this report."]
    return "\n".join(lines)


def mark_live(alias):
    store.Prefs.set("sync.lastLive." + alias, time.time())
