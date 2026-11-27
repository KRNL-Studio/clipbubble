"""Direct Sync v2 identity, TLS transport, pairing and LAN discovery."""
import collections
import contextlib
import datetime
import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import select
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from urllib.parse import parse_qs, quote, urlencode, urlsplit

PORT = 47822
OS = "linux"
SYSTEMS = {"linux", "macos", "windows", "ios"}
PREAMBLE_TIMEOUT = 15
APPROVAL_TIMEOUT = 90
QR_TTL = 600
LINE_LIMIT = 4096
# Older CPython builds omit the name even when their SSL library supports this X509 flag.
_PARTIAL_CHAIN = getattr(ssl, "VERIFY_X509_PARTIAL_CHAIN", 0x80000)
FINGERPRINT = re.compile(r"[0-9a-f]{64}")
TOKEN = re.compile(r"[0-9a-f]{32}")
RATE_ERROR = "Too many pairing requests. Wait a moment and try again."
CODE_ERROR = "Invalid or expired pairing code."


@contextlib.contextmanager
def _locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with os.fdopen(os.open(path, os.O_RDWR | os.O_CREAT, 0o600), "rb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def _replace(path, data, mode):
    fd, temp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            os.fchmod(out.fileno(), mode)
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temp, path)
    finally:
        Path(temp).unlink(missing_ok=True)


def _device_id(value):
    if isinstance(value, str):
        try:
            return str(uuid.UUID(value)) == value
        except ValueError:
            pass
    return False


def device_id(directory):
    directory = Path(directory)
    path = directory / "device-id"
    with _locked(directory / "direct-identity.lock"):
        try:
            value = path.read_text().strip()
        except FileNotFoundError:
            value = ""
        if not value:
            value = str(uuid.uuid4())
            _replace(path, value.encode(), 0o600)
        return value


def _name(value):
    return value.encode("utf-8")[:48].decode("utf-8", "ignore") or "ClipBubble"


class DirectIdentity:
    def __init__(self, directory, device=None):
        directory = Path(directory)
        self.device = device if device is not None else device_id(directory)
        if not _device_id(self.device):
            raise ValueError("Direct Sync requires a lowercase UUID in device-id.")
        self.key_path = directory / "direct-key.pem"
        self.cert_path = directory / "direct-cert.pem"
        with _locked(directory / "direct-identity.lock"):
            if not self.cert_path.exists() or not self.key_path.exists():
                self.cert_path.unlink(missing_ok=True)
                self._generate(directory)
            self.key_path.chmod(0o600)
            self.cert_path.chmod(0o644)
            self.fingerprint = _fingerprint(ssl.PEM_cert_to_DER_cert(self.cert_path.read_text()))

    def _generate(self, directory):
        now = datetime.datetime.now(datetime.timezone.utc)
        try:
            end = now.replace(year=now.year + 20)
        except ValueError:  # February 29 in a year followed by a non-leap century.
            end = now.replace(year=now.year + 20, day=28)
        start = now - datetime.timedelta(days=1)
        with tempfile.TemporaryDirectory(dir=directory) as temp:
            work = Path(temp)
            (work / "index").touch()
            (work / "serial").write_text(secrets.token_hex(16) + "\n")
            (work / "config").write_text(
                "[ca]\ndefault_ca=local\n[local]\ndatabase=index\nserial=serial\n"
                "new_certs_dir=.\ndefault_md=sha256\npolicy=policy\nx509_extensions=extensions\n"
                "[policy]\ncommonName=supplied\n[extensions]\nbasicConstraints=critical,CA:FALSE\n"
                "keyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth,clientAuth\n")
            for args in (
                ["genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-out", "key"],
                ["req", "-new", "-key", "key", "-subj", f"/CN=clipbubble-{self.device}", "-out", "request"],
                ["ca", "-selfsign", "-batch", "-config", "config", "-keyfile", "key", "-in", "request",
                 "-out", "cert", "-notext", "-startdate", start.strftime("%Y%m%d%H%M%SZ"),
                 "-enddate", end.strftime("%Y%m%d%H%M%SZ")],
            ):
                result = subprocess.run(["openssl", *args], cwd=work, capture_output=True, timeout=10)
                if result.returncode:
                    raise OSError("Could not create the Direct Sync certificate: " +
                                  result.stderr.decode(errors="replace").strip())
            _replace(self.key_path, (work / "key").read_bytes(), 0o600)
            _replace(self.cert_path, (work / "cert").read_bytes(), 0o644)

    def context(self, server=False):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER if server else ssl.PROTOCOL_TLS_CLIENT)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.set_ciphers("ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384")
        ctx.options |= ssl.OP_NO_TICKET | getattr(ssl, "OP_NO_RENEGOTIATION", 0)
        ctx.load_cert_chain(self.cert_path, self.key_path)
        if server:
            ctx.verify_mode = ssl.CERT_REQUIRED
            ctx.verify_flags |= _PARTIAL_CHAIN
            if not hasattr(ctx, "_msg_callback"):
                raise OSError("Direct Sync requires CPython's TLS handshake message callback.")
            ctx._msg_callback = _trust_handshake_leaf
        else:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        return ctx


def _trust_handshake_leaf(sock, direction, version, content_type, message_type, data):
    """Seed this connection's empty trust store before OpenSSL verifies the client certificate.

    CPython exposes no verify callback. Its handshake message callback runs before certificate
    processing. Each accepted connection gets its own context, with no public CA roots.
    OpenSSL still requires the certificate and verifies CertificateVerify. Trust for pairing
    and sync uses only the post-handshake fingerprint.
    """
    if direction != "read" or content_type != 22 or message_type != 11 or len(data) < 7:
        return
    start = 4
    if version == ssl.TLSVersion.TLSv1_3:
        start += 1 + data[4]  # certificate_request_context, including its length byte
    end = start + 3 + int.from_bytes(data[start:start + 3], "big")
    start += 3  # certificate_list length
    if end > len(data) or start + 3 >= end:
        return
    size = int.from_bytes(data[start:start + 3], "big")
    start += 3
    if 0 < size <= end - start:
        try:
            sock.context.load_verify_locations(cadata=ssl.DER_cert_to_PEM_cert(data[start:start + size]))
        except ssl.SSLError:
            pass  # The TLS stack rejects an invalid certificate with the trust store still empty.


def _fingerprint(der):
    return hashlib.sha256(der).hexdigest()


def pair_code(local_fp, peer_fp):
    lo, hi = (local_fp, peer_fp) if local_fp <= peer_fp else (peer_fp, local_fp)
    digest = hashlib.sha256(f"clipbubble-pair-v2:{lo}:{hi}".encode()).digest()
    return f"{int.from_bytes(digest[:4], 'big') % 1_000_000:06d}"


def display_code(code):
    return code[:3] + " " + code[3:]


@dataclass(frozen=True)
class DirectPeer:
    id: str
    name: str
    os: str
    fingerprint: str
    addresses: tuple = ()
    port: int = 0

    @property
    def alias(self):
        return "direct:" + self.id


class DirectPeers:
    def __init__(self, directory):
        self.path = Path(directory) / "direct-peers.json"

    def all(self):
        try:
            entries = json.loads(self.path.read_text())
            peers = [DirectPeer(**dict(item, addresses=tuple(item.get("addresses", ())))) for item in entries]
        except (OSError, ValueError, TypeError, AttributeError, RecursionError):
            return []
        return peers

    def by_id(self, device):
        return next((p for p in self.all() if p.id == device), None)

    def by_fingerprint(self, fingerprint):
        return next((p for p in self.all() if p.fingerprint == fingerprint), None)

    def _write(self, peers):
        _replace(self.path, json.dumps([asdict(p) for p in peers], indent=2).encode(), 0o600)

    def save(self, peer):
        with _locked(self.path.with_suffix(".lock")):
            self._write([p for p in self.all() if p.id != peer.id and p.fingerprint != peer.fingerprint] + [peer])

    def remove(self, device):
        with _locked(self.path.with_suffix(".lock")):
            self._write([p for p in self.all() if p.id != device])


class DirectError(OSError):
    pass


class HostKeyChanged(DirectError):
    pass


class NeedsKeyAuth(DirectError):
    pass


class DirectStream:
    """Serialize nonblocking TLS calls while allowing the session's reader and writer to wait independently."""
    def __init__(self, sock):
        self.sock = sock
        self.sock.setblocking(False)
        self.lock = threading.Lock()
        self.closed = False
        self.buffer = bytearray()

    def _io(self, operation, deadline):
        while True:
            with self.lock:
                if self.closed:
                    raise OSError("Direct connection closed")
                if deadline is not None and time.monotonic() >= deadline:
                    raise TimeoutError("Direct connection timed out")
                try:
                    return operation()
                except ssl.SSLWantReadError:
                    events = select.POLLIN
                except ssl.SSLWantWriteError:
                    events = select.POLLOUT
                poll = select.poll()
                poll.register(self.sock, events)
            # A bounded wait also handles platforms where closing a descriptor doesn't wake poll.
            wait = 1 if deadline is None else min(1, max(0, deadline - time.monotonic()))
            poll.poll(round(wait * 1000))

    def recv(self, count, deadline=None):
        if self.buffer:
            data = bytes(self.buffer[:count])
            del self.buffer[:count]
            return data
        return self._io(lambda: self.sock.recv(count), deadline)

    def sendall(self, data, deadline=None):
        view = memoryview(data)
        while view:
            sent = self._io(lambda: self.sock.send(view), deadline)
            if not sent:
                raise OSError("Direct connection closed")
            view = view[sent:]

    def read_json(self, deadline):
        while True:
            end = self.buffer.find(b"\n")
            if 0 <= end < LINE_LIMIT:
                line = bytes(self.buffer[:end])
                del self.buffer[:end + 1]
                obj = json.loads(line.decode("utf-8"))
                if not isinstance(obj, dict):
                    raise ValueError("Expected a Direct Sync JSON object")
                return obj
            if len(self.buffer) >= LINE_LIMIT:
                raise ValueError("Direct Sync preamble too long")
            data = self._io(lambda: self.sock.recv(LINE_LIMIT - len(self.buffer)), deadline)
            if not data:
                raise OSError("Direct connection closed during preamble")
            self.buffer.extend(data)

    def send_json(self, obj, deadline):
        self.sendall(json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode() + b"\n", deadline)

    def close(self):
        with self.lock:
            if not self.closed:
                self.closed = True
                try:
                    self.sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


@dataclass
class _Invitation:
    token: str
    expires: float
    wrong: int = 0
    result: str = ""
    done: threading.Event = field(default_factory=threading.Event)


class DirectServer:
    def __init__(self, identity, peers, name, on_sync=None, approve=None, on_pair=None,
                 host="0.0.0.0", port=PORT, approval_timeout=APPROVAL_TIMEOUT):
        self.identity, self.peers = identity, peers
        self.name = _name(name)
        self.on_sync = on_sync
        self.approve = approve
        self.on_pair = on_pair
        self.approval_timeout = approval_timeout
        self.lock = threading.Lock()
        self.closed = threading.Event()
        self.pending = set()
        self.requests = collections.deque()
        self.invitation = None
        # Fail during startup if the TLS backend cannot set up peer authentication.
        self.identity.context(server=True)
        try:
            self.listener = socket.create_server((host, port))
        except OSError:
            if port != PORT:
                raise
            self.listener = socket.create_server((host, 0))
        self.listener.settimeout(0.25)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self._accept, daemon=True, name="clipbubble-direct")
        self.thread.start()

    def invite(self, addresses):
        invitation = _Invitation(secrets.token_hex(16), time.monotonic() + QR_TTL)
        with self.lock:
            if self.invitation:
                self.invitation.done.set()
            self.invitation = invitation
        query = {"v": 2, "id": self.identity.device, "fp": self.identity.fingerprint, "h": ",".join(addresses),
                 "p": self.port, "c": invitation.token, "n": self.name, "os": OS}
        return "clipbubble://direct?" + urlencode(query, quote_via=quote, safe=","), invitation

    def cancel(self, invitation):
        with self.lock:
            if self.invitation is invitation:
                self.invitation = None
                invitation.done.set()

    def close(self):
        self.closed.set()
        self.listener.close()
        with self.lock:
            if self.invitation:
                self.invitation.done.set()
                self.invitation = None
            for conn in self.pending:
                try:
                    conn.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                conn.close()
        self.thread.join()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def _accept(self):
        while not self.closed.is_set():
            try:
                conn, addr = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with self.lock:
                if self.closed.is_set() or len(self.pending) >= 32:
                    conn.close()
                    continue
                self.pending.add(conn)
            threading.Thread(target=self._serve, args=(conn, addr[0]), daemon=True).start()

    def _serve(self, conn, addr):
        active = conn
        stream = None
        handed_off = False
        deadline = time.monotonic() + PREAMBLE_TIMEOUT
        try:
            ctx = self.identity.context(server=True)
            with self.lock:
                if self.closed.is_set():
                    return
                tls = ctx.wrap_socket(conn, server_side=True, do_handshake_on_connect=False)
                self.pending.remove(conn)
                self.pending.add(tls)
                active = tls
            tls.settimeout(max(0.001, deadline - time.monotonic()))
            tls.do_handshake()
            ctx._msg_callback = None
            cert = tls.getpeercert(binary_form=True)
            if not cert:
                return
            fingerprint = _fingerprint(cert)
            stream = DirectStream(tls)
            request = stream.read_json(deadline)
            mode, device = request.get("mode"), request.get("device")
            if type(request.get("v")) is not int or request["v"] != 2:
                stream.send_json({"ok": False, "error": "unsupported"}, deadline)
            elif mode == "sync":
                peer = self.peers.by_fingerprint(fingerprint)
                if not peer or ("device" in request and device != peer.id) or not self.on_sync:
                    stream.send_json({"ok": False, "error": "unpaired"}, deadline)
                    return
                stream.send_json({"ok": True}, deadline)
                self.on_sync(stream, peer)
                handed_off = True
            elif mode in ("pair", "pair-qr"):
                self._pair(stream, request, fingerprint, addr, deadline)
            else:
                stream.send_json({"ok": False, "error": "unsupported"}, deadline)
        except (OSError, ValueError, TypeError, RecursionError):
            pass
        finally:
            with self.lock:
                self.pending.discard(active)
            if not handed_off:
                (stream or active).close()

    def _pair(self, stream, request, fingerprint, addr, deadline):
        device, name, os_name = request.get("device"), request.get("name"), request.get("os")
        if (not _device_id(device) or device == self.identity.device or fingerprint == self.identity.fingerprint
                or not isinstance(name, str) or not isinstance(os_name, str) or os_name not in SYSTEMS):
            stream.send_json({"ok": False, "error": "Invalid pairing request."}, deadline)
            return
        old = self.peers.by_id(device)
        endpoints = (addr, *(a for a in old.addresses if a != addr)) if old else (addr,)
        peer = DirectPeer(device, _name(name), os_name, fingerprint, endpoints, old.port if old else PORT)
        if request["mode"] == "pair":
            now = time.monotonic()
            with self.lock:
                while self.requests and now - self.requests[0] >= 60:
                    self.requests.popleft()
                limited = len(self.requests) >= 5
                if not limited:
                    self.requests.append(now)
            if limited:
                stream.send_json({"ok": False, "error": RATE_ERROR}, deadline)
                return
            allowed = self._approved(peer)
            deadline = time.monotonic() + PREAMBLE_TIMEOUT
            if not allowed or self.closed.is_set():
                stream.send_json({"ok": False, "error": f"Declined on {self.name}."}, deadline)
                return
            invitation = None
        else:
            invitation = self._consume(request.get("code"))
            if invitation is None:
                stream.send_json({"ok": False, "error": CODE_ERROR}, deadline)
                return
        try:
            self.peers.save(peer)
            if self.on_pair:
                self.on_pair(peer)
            stream.send_json({"ok": True, "device": self.identity.device, "name": self.name, "os": OS}, deadline)
            if invitation:
                invitation.result = peer.name
        finally:
            if invitation:
                invitation.done.set()

    def _consume(self, code):
        with self.lock:
            invitation = self.invitation
            if not invitation:
                return None
            expired = invitation.expires <= time.monotonic()
            if not expired and isinstance(code, str) and TOKEN.fullmatch(code) and hmac.compare_digest(code, invitation.token):
                self.invitation = None
                return invitation
            invitation.wrong += 1
            if expired or invitation.wrong >= 5:
                self.invitation = None
                invitation.done.set()
            return None

    def _approved(self, peer):
        if self.approve is None:
            return False
        finished, decision = threading.Event(), []
        expires = time.monotonic() + self.approval_timeout

        def ask():
            code = display_code(pair_code(self.identity.fingerprint, peer.fingerprint))
            try:
                decision.append(bool(self.approve(peer, code, expires)))
            except (OSError, ValueError):
                pass
            finally:
                finished.set()

        threading.Thread(target=ask, daemon=True).start()
        while not self.closed.is_set():
            remaining = expires - time.monotonic()
            if remaining <= 0:
                break
            if finished.wait(min(remaining, 0.25)):
                return bool(decision and decision[0]) and time.monotonic() < expires
        return False


def _connect(identity, addresses, port, expected=None):
    """Race endpoints through the TLS pin check, closing every losing socket."""
    deadline = time.monotonic() + PREAMBLE_TIMEOUT
    endpoints = tuple(dict.fromkeys(addresses))
    if not endpoints:
        raise DirectError("No addresses for this Direct peer.")
    condition = threading.Condition()
    result, errors = [], []
    finished = False
    ctx = identity.context()

    def dial(host):
        try:
            with socket.create_connection((host, port), timeout=max(0.001, deadline - time.monotonic())) as tcp:
                tcp.settimeout(max(0.001, deadline - time.monotonic()))
                tls = ctx.wrap_socket(tcp, do_handshake_on_connect=False)
                try:
                    tls.do_handshake()
                    fingerprint = _fingerprint(tls.getpeercert(binary_form=True))
                    if expected is not None and not hmac.compare_digest(fingerprint, expected):
                        raise HostKeyChanged("Direct peer certificate changed.")
                    with condition:
                        if not result and not finished:
                            result.append((DirectStream(tls), fingerprint, deadline))
                            tls = None
                            condition.notify()
                finally:
                    if tls is not None:
                        tls.close()
        except (OSError, ValueError) as e:
            with condition:
                errors.append(e)
                condition.notify()

    for host in endpoints:
        threading.Thread(target=dial, args=(host,), daemon=True).start()
    with condition:
        condition.wait_for(lambda: result or len(errors) == len(endpoints), max(0, deadline - time.monotonic()))
        finished = True
        if result:
            return result[0]
    mismatch = next((e for e in errors if isinstance(e, HostKeyChanged)), None)
    if mismatch:
        raise mismatch
    raise DirectError(str(errors[-1]) if errors else "Direct connection timed out.")


class DirectTunnel:
    @staticmethod
    def connect(identity, peer, nearby=None):
        attempts = [(peer.addresses, peer.port)]
        if nearby and nearby.id == peer.id and nearby.port:
            # Discovery can update routes but cannot update the pinned identity.
            if nearby.port == peer.port:
                attempts = [(nearby.addresses + peer.addresses, peer.port)]
            else:
                attempts.insert(0, (nearby.addresses, nearby.port))
        error = None
        for addresses, port in attempts:
            try:
                stream, _, deadline = _connect(identity, addresses, port, peer.fingerprint)
                break
            except OSError as e:
                if not isinstance(error, HostKeyChanged):
                    error = e
        else:
            raise error
        try:
            stream.send_json({"mode": "sync", "v": 2, "device": identity.device}, deadline)
            reply = stream.read_json(deadline)
            if reply.get("ok") is True:
                return stream
            if reply.get("error") == "unpaired":
                raise NeedsKeyAuth("Direct peer revoked this device.")
            raise DirectError("Direct peer refused sync.")
        except BaseException:
            stream.close()
            raise


def qr_target(url):
    parsed = urlsplit(url)
    if parsed.scheme != "clipbubble" or parsed.netloc != "direct" or parsed.path or parsed.fragment:
        raise ValueError("Expected a ClipBubble Direct pairing link.")
    try:
        query = parse_qs(parsed.query, max_num_fields=16)
        version, device, fp, hosts, port, code, name, system = (
            query[key][0] for key in ("v", "id", "fp", "h", "p", "c", "n", "os"))
        addresses = tuple(dict.fromkeys(hosts.split(",")))
        if (version == "2" and _device_id(device) and FINGERPRINT.fullmatch(fp) and TOKEN.fullmatch(code)
                and system in SYSTEMS and 0 < int(port) < 65536 and 0 < len(addresses) <= 32
                and all(a and len(a) <= 255 and not any(c.isspace() or c == "\0" for c in a) for a in addresses)):
            return DirectPeer(device, _name(name), system, fp, addresses, int(port)), code
    except (KeyError, ValueError):
        pass
    raise ValueError("Invalid ClipBubble Direct pairing link.")


class DirectPairingClient:
    def __init__(self, identity, peers, name, on_pair=None):
        self.identity, self.peers, self.name = identity, peers, _name(name)
        self.on_pair = on_pair

    def pair(self, target, show_code):
        if not callable(show_code):
            raise ValueError("Nearby pairing requires displaying the confirmation code.")
        return self._pair(target, {"mode": "pair"}, show_code=show_code)

    def pair_qr(self, url):
        target, code = qr_target(url)
        return self._pair(target, {"mode": "pair-qr", "code": code}, expected=target.fingerprint)

    def _pair(self, target, request, show_code=None, expected=None):
        if target.id == self.identity.device:
            raise DirectError("This pairing link belongs to this device.")
        stream, fingerprint, deadline = _connect(self.identity, target.addresses, target.port, expected)
        with stream:
            if show_code is not None:
                show_code(display_code(pair_code(self.identity.fingerprint, fingerprint)))
            request.update(v=2, device=self.identity.device, name=self.name, os=OS)
            stream.send_json(request, deadline)
            reply_deadline = deadline + (120 - PREAMBLE_TIMEOUT if show_code is not None else 0)
            reply = stream.read_json(reply_deadline)
            if reply.get("ok") is not True:
                error = reply.get("error")
                raise DirectError(error if isinstance(error, str) and error else "Direct pairing failed.")
            if (reply.get("device") != target.id or not isinstance(reply.get("name"), str)
                    or not isinstance(reply.get("os"), str) or reply["os"] not in SYSTEMS):
                raise DirectError("Invalid Direct pairing response.")
            peer = DirectPeer(target.id, _name(reply["name"]), reply["os"], fingerprint, target.addresses, target.port)
            self.peers.save(peer)
            if self.on_pair:
                self.on_pair(peer)
            return peer


_SERVICE = ("_clipbubble", "_tcp", "local")
_MDNS = ("224.0.0.251", 5353)
_PTR, _TXT, _A, _AAAA, _SRV = 12, 16, 1, 28, 33
_TTL = 120
_CACHE_LIMIT = 2048


def _dns_name(labels):
    parts = [label.encode("utf-8") for label in labels]
    return b"".join(bytes((len(part),)) + part for part in parts) + b"\0"


def _read_name(data, start):
    labels, visited = [], set()
    next_offset = None
    while True:
        if start in visited:
            raise ValueError("Cyclic DNS compression")
        visited.add(start)
        count = data[start]
        start += 1
        if count == 0:
            return tuple(labels), next_offset or start
        if count & 0xc0 == 0xc0:
            if next_offset is None:
                next_offset = start + 1
            start = (count & 0x3f) * 256 + data[start]
        elif count <= 63 and start + count <= len(data) and len(labels) < 127:
            labels.append(data[start:start + count].decode("utf-8"))
            start += count
        else:
            raise ValueError("Invalid DNS name")


def _read_dns(packet):
    _, flags, qd, an, ns, ar = struct.unpack_from("!6H", packet)
    offset = 12
    questions, records = [], []
    for _ in range(qd):
        name, offset = _read_name(packet, offset)
        kind, cls = struct.unpack_from("!HH", packet, offset)
        offset += 4
        if (cls & 0x7fff) in (1, 255):
            questions.append((name, kind))
    for _ in range(an + ns + ar):
        name, offset = _read_name(packet, offset)
        kind, cls, ttl, size = struct.unpack_from("!HHIH", packet, offset)
        start = offset + 10
        offset = start + size
        if offset > len(packet):
            raise ValueError("Truncated DNS record")
        if not flags & 0x8000 or (cls & 0x7fff) != 1:
            continue
        body = packet[start:offset]
        if kind == _PTR:
            value = _read_name(packet, start)[0]
        elif kind == _SRV:
            value = struct.unpack_from("!H", body, 4)[0], _read_name(packet, start + 6)[0]
        elif kind == _TXT:
            fields = []
            while body:
                n = body[0]
                if n >= len(body):
                    raise ValueError("Truncated DNS text record")
                fields.append(body[1:1 + n].decode("utf-8"))
                body = body[1 + n:]
            value = tuple(fields)
        elif kind == _A and len(body) == 4:
            value = socket.inet_ntop(socket.AF_INET, body)
        elif kind == _AAAA and len(body) == 16:
            value = socket.inet_ntop(socket.AF_INET6, body)
        else:
            continue
        records.append((name, kind, ttl, value))
    return questions, records


def _record(name, kind, ttl, body):
    cls = 1 if kind == _PTR else 0x8001
    return _dns_name(name) + struct.pack("!HHIH", kind, cls, ttl, len(body)) + body


def _dns_key(name):
    # DNS compares ASCII letters without regard to case, including names in compressed records.
    return tuple(label.encode("utf-8").lower().decode("utf-8") for label in name)


def _txt(identity, name):
    return ("v=2", f"id={identity.device}", f"name={name}", f"os={OS}", f"fp={identity.fingerprint[:16]}")


def _nearby(fields, addresses, port):
    txt = dict(field.split("=", 1) for field in fields if "=" in field)
    if (txt.get("v") == "2" and _device_id(txt.get("id")) and txt.get("os") in SYSTEMS and txt.get("name")
            and re.fullmatch(r"[0-9a-f]{16}", txt.get("fp", "")) and addresses and 0 < port < 65536):
        return DirectPeer(txt["id"], _name(txt["name"]), txt["os"], txt["fp"], tuple(addresses), port)
    return None


def _v4(addresses):
    ips = []
    for addr in addresses:
        try:
            socket.inet_pton(socket.AF_INET, addr)
        except OSError:
            continue
        ips.append(addr)
    return ips


class DirectDiscovery:
    """Cache resolved DNS-SD services and optionally advertise this device."""
    def __init__(self, identity=None, name="", port=0, addresses=None):
        self.identity, self.name, self.port = identity, _name(name) or "ClipBubble", port
        self.addresses = _v4(addresses or ())
        self.instance = (self.name,) + _SERVICE
        self.hostname = (f"clipbubble-{identity.device}" if identity else "clipbubble", "local")
        self.records = {}
        self.closed = threading.Event()
        self.lock = threading.Lock()
        self.publisher = None
        self.thread = threading.Thread(target=self._run, daemon=True, name="clipbubble-mdns")
        self.thread.start()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self):
        self.closed.set()
        self.thread.join()

    def nearby(self):
        active = self._active_records()
        result = {}
        for service in active[_SERVICE, _PTR]:
            config = active[service, _SRV]
            txt = active[service, _TXT]
            if config and txt:
                port, host = config[0]
                addresses = active[host, _A] + active[host, _AAAA]
                peer = _nearby(txt[0], addresses, port)
                if peer and (not self.identity or peer.id != self.identity.device):
                    result[peer.id] = peer
        return sorted(result.values(), key=lambda p: (p.name.casefold(), p.id))

    def find(self, device):
        return next((p for p in self.nearby() if p.id == device), None)

    def _active_records(self):
        now = time.monotonic()
        with self.lock:
            self.records = {key: expires for key, expires in self.records.items() if expires > now}
            active = collections.defaultdict(list)
            for (name, kind, value), _ in sorted(self.records.items(), key=lambda item: item[1], reverse=True):
                active[name, kind].append(value)
        return active

    def _query(self):
        active = self._active_records()
        questions = [(_SERVICE, _PTR)]
        for service in active[_SERVICE, _PTR][:32]:
            if not active[service, _TXT]:
                questions.append((service, _TXT))
            if not active[service, _SRV]:
                questions.append((service, _SRV))
                continue
            _, host = active[service, _SRV][0]
            if not active[host, _A] and not active[host, _AAAA]:
                questions.extend(((host, _A), (host, _AAAA)))
        return struct.pack("!6H", 0, 0, len(questions), 0, 0, 0) + b"".join(
            _dns_name(name) + struct.pack("!HH", kind, 1) for name, kind in questions)

    def _announce(self, ttl):
        fields = [field.encode("utf-8") for field in _txt(self.identity, self.name)]
        records = [
            _record(_SERVICE, _PTR, ttl, _dns_name(self.instance)),
            _record(self.instance, _SRV, ttl, struct.pack("!HHH", 0, 0, self.port) + _dns_name(self.hostname)),
            _record(self.instance, _TXT, ttl, b"".join(bytes((len(field),)) + field for field in fields)),
        ] + [_record(self.hostname, _A, ttl, socket.inet_aton(addr)) for addr in self.addresses]
        return struct.pack("!6H", 0, 0x8400, 0, len(records), 0, 0) + b"".join(records)

    def _publish_avahi(self):
        try:
            return subprocess.Popen(["avahi-publish-service", self.name, ".".join(_SERVICE[:2]), str(self.port),
                                     *_txt(self.identity, self.name)], stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            return None

    def _run(self):
        if self.identity and self.port:
            self.publisher = self._publish_avahi()
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                if hasattr(socket, "SO_REUSEPORT"):
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
                sock.bind(("", _MDNS[1]))
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
                interfaces = []
                for addr in self.addresses or ["0.0.0.0"]:
                    try:
                        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                                        socket.inet_aton(_MDNS[0]) + socket.inet_aton(addr))
                    except OSError:
                        continue
                    interfaces.append(addr)
                if interfaces:
                    sock.settimeout(0.25)
                    self._listen(sock, interfaces)
        except OSError:
            pass
        finally:
            # Avahi can coexist with our browser. Keep its advertisement alive even if a second
            # UDP socket is unavailable on this host.
            if self.publisher:
                self.closed.wait()
                if self.publisher.poll() is None:
                    self.publisher.terminate()
                    try:
                        self.publisher.wait(timeout=1)
                    except subprocess.TimeoutExpired:
                        self.publisher.kill()
                        self.publisher.wait()

    def _listen(self, sock, interfaces):
        def multicast(packet):
            for addr in interfaces:
                try:
                    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(addr))
                    sock.sendto(packet, _MDNS)
                except OSError:
                    pass

        next_query = next_ad = 0
        advertise = False
        try:
            while not self.closed.is_set():
                now = time.monotonic()
                advertise = self.identity and self.port and (not self.publisher or self.publisher.poll() is not None)
                if now >= next_query:
                    multicast(self._query())
                    next_query = now + 2
                if advertise and now >= next_ad:
                    multicast(self._announce(_TTL))
                    next_ad = now + _TTL / 2
                try:
                    packet, _ = sock.recvfrom(9000)
                    questions, records = _read_dns(packet)
                except (socket.timeout, ValueError, IndexError, struct.error):
                    continue
                instance = _dns_key(self.instance)
                if advertise and any(_dns_key(name) in (_SERVICE, instance, self.hostname) for name, _ in questions):
                    multicast(self._announce(_TTL))
                if records:
                    with self.lock:
                        for name, kind, ttl, value in records:
                            name = _dns_key(name)
                            if kind == _PTR:
                                if name != _SERVICE or _dns_key(value[1:]) != _SERVICE:
                                    continue
                                value = _dns_key(value)
                            elif kind in (_SRV, _TXT):
                                if name[1:] != _SERVICE:
                                    continue
                                if kind == _SRV:
                                    value = value[0], _dns_key(value[1])
                            if (advertise and kind == _TXT and name == instance
                                    and any(v.startswith("id=") for v in value) and f"id={self.identity.device}" not in value
                                    and len(self.instance[0].encode()) <= 48):
                                multicast(self._announce(0))
                                self.instance = (f"{self.name} ({self.identity.device[:8]})",) + _SERVICE
                                next_ad = 0
                            key = (name, kind, value)
                            if ttl:
                                if key not in self.records and len(self.records) >= _CACHE_LIMIT:
                                    self.records.pop(next(iter(self.records)))
                                self.records[key] = now + min(ttl, 4500)
                            else:
                                self.records.pop(key, None)
        finally:
            if advertise:
                multicast(self._announce(0))
