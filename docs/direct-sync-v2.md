# ClipBubble Direct Sync v2 Protocol Specification

This document is the single source of truth for **ClipBubble 2.0 Direct Sync** across macOS, iOS, Linux, and Windows. All four platforms MUST follow this specification identically so any pair of devices can discover, verify, pair, and sync with zero SSH setup.

## Goals
- **Zero SSH / Zero Admin:** No macOS Remote Login, no Windows OpenSSH Server or UAC elevation, no Linux `sshd` or `sudo`.
- **AirDrop-like Discovery & Pairing:** Nearby devices appear automatically over Bonjour/mDNS (`_clipbubble._tcp`) and Apple AWDL (`includePeerToPeer = true`). Users tap a device and confirm a 6-digit code (or scan a Direct QR code as fallback).
- **End-to-End Encrypted & MITM-Proof:** Mutual TLS (mTLS) with per-device pinned self-signed ECDSA P-256 certificates. Existing SSH links remain supported alongside Direct links under **Advanced → Connect via SSH**.
- **Transport-Agnostic Core:** Reuses the existing ClipBubble sync frame protocol (`Sync.swift` / `sync.py` / `Sync.cs`) over the authenticated TLS stream.

---

## 1. Device Identity & Certificate

Every device generates one persistent **ECDSA P-256** keypair and self-signed **X.509 v3** certificate on first use:

- **Algorithm:** ECDSA on NIST P-256 (`secp256r1` / `prime256v1`) signed with `ecdsa-with-SHA256` (`1.2.840.10045.4.3.2`).
- **Subject & Issuer:** `CN=clipbubble-<device-id>` (where `<device-id>` is the lowercase UUID already stored in `device-id`).
- **Validity:** `notBefore = now - 24h` (tolerates clock skew), `notAfter = now + 20 years` (using GeneralizedTime for years >= 2050, UTCTime for years < 2050).
- **Extensions:** `BasicConstraints (CA:FALSE)`, `KeyUsage (digitalSignature)`, `ExtendedKeyUsage (serverAuth, clientAuth)`.
- **Fingerprint (`fp`):** Lowercase 64-character hex string of `SHA-256(DER(leaf_certificate))` (no colons, no spaces).
- **Storage:**
  - **macOS / iOS:** Private key + certificate stored in Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; shared App Group Keychain on iOS so main app, Share Extension, and Keyboard share one identity). Test builds may inject an ephemeral in-memory/temp store.
  - **Linux:** `<config-dir>/direct-key.pem` (`0600`) and `<config-dir>/direct-cert.pem` (`0644`).
  - **Windows:** `<app-data>/ClipBubble/direct-identity.pfx` (user-private ACL, or Windows user cert store / PKCS#12 file).

---

## 2. Discovery (Bonjour / mDNS + Apple AWDL)

- **Service Type:** `_clipbubble._tcp` (domain `local.`).
- **Service Instance Name:** `<device-name>` (or `<device-name> (<short-id>)` on collision; clients identify devices by TXT `id`, never instance name alone).
- **Listener Port:** Prefer TCP port `47822`, falling back to any ephemeral port (`0` / `.any`) if taken. Always advertise the actual bound port in SRV.
- **Apple Peer-to-Peer (AWDL):** macOS & iOS MUST set `parameters.includePeerToPeer = true` on both `NWListener` and `NWBrowser` (and `NWConnection` when dialing a discovered endpoint) so Mac ↔ iPhone works even on isolated Wi-Fi or without a router.
- **TXT Record Keys (UTF-8 key=value pairs):**
  - `v=2` — Direct protocol version (`"2"`).
  - `id=<device-id>` — Lowercase device UUID.
  - `name=<device-name>` — Display name (UTF-8, max 48 bytes).
  - `os=<os>` — One of `macos`, `ios`, `linux`, `windows`.
  - `fp=<fp16>` — First 16 lowercase hex chars of the device's `fp` (display/dedup hint only; security ALWAYS checks full 64-char `fp` over TLS).
- **iOS Behavior:** iOS browses `_clipbubble._tcp` when linking or resolving paired devices; iOS does not need to stay listening in the background (desktops listen; iPhone dials).

---

## 3. Mutual TLS (mTLS) Transport

- **TLS Version:** TLS 1.3 preferred (TLS 1.2 minimum allowed only if a platform stack such as Windows .NET Framework 4.8 SChannel negotiates TLS 1.2 with ECDHE-ECDSA-AES-GCM; macOS/iOS/Linux negotiate TLS 1.3).
- **Mutual Authentication:**
  - Server MUST request and require a client certificate.
  - Client MUST present its device certificate.
  - Both sides bypass public-CA chain validation and instead extract the peer's leaf certificate DER bytes from the verified TLS session (the TLS stack STILL cryptographically verifies the peer's `CertificateVerify` signature proving possession of the private key!) and compute `peerFP = hex(SHA-256(DER(peer_leaf_cert)))`.
- **Timeout:** Handshake + preamble MUST complete within 15 seconds (120 seconds for interactive 6-digit user confirmation in `pair` mode).

---

## 4. Application Preamble (Single-Port Multiplexing)

Immediately after the mTLS handshake succeeds, the **client** sends ONE UTF-8 JSON line terminated by `\n` (`0x0A`, max 4,096 bytes). The **server** replies with ONE UTF-8 JSON line terminated by `\n`.

### 4.1 Mode `"sync"` (Trusted Peers Only)
Client sends:
```json
{"mode":"sync","v":2,"device":"<client-device-id>"}
```
Server checks:
1. `peerFP` MUST match a trusted peer in `DirectPeers` (and if `device` is provided, it MUST match that trusted peer's stored `deviceId`).
2. If NOT trusted: server replies `{"ok":false,"error":"unpaired"}\n` and closes immediately. **An untrusted peer MUST NEVER reach `SyncEngine.begin(session)`.**
3. If trusted: server replies `{"ok":true}\n` and immediately hands the TLS byte stream to `Session` (existing ClipBubble binary sync frames: `hello`, `summary`, `put`, `chunk`, etc.).

Client checks:
1. Before sending `{"mode":"sync",...}`, client MUST verify `serverFP == expectedPeerFP`. If mismatched, abort immediately (report `hostKeyChanged`).
2. Wait for `{"ok":true}\n`. If `{"ok":false,"error":"unpaired"}`, report `needsKeyAuth` (peer revoked this device). Otherwise hand the TLS byte stream to `Session`.

### 4.2 Mode `"pair"` (Nearby 6-Digit SAS Confirmation)
Used when the user taps a discovered nearby device (no QR code needed).

**6-Digit Short Authentication String (SAS) Formula (MUST match identically on all 4 platforms):**
```text
lo = min(localFP, peerFP)   // ASCII lexicographical compare of 64-char lowercase hex strings
hi = max(localFP, peerFP)
digest = SHA-256(UTF8("clipbubble-pair-v2:" + lo + ":" + hi))
num = big_endian_uint32(digest[0..4]) % 1_000_000
code = zero_pad_6_digits(num)  // e.g. "048291", displayed as "048 291"
```

Flow:
1. Client connects over mTLS to the discovered peer, computes `code` from `(clientFP, serverFP)`, displays `code` to the user, and sends:
   ```json
   {"mode":"pair","v":2,"device":"<client-id>","name":"<client-name>","os":"<client-os>"}
   ```
2. Server checks rate limit (**max 5 pairing requests per 60 seconds**; if exceeded, replies `{"ok":false,"error":"Too many pairing requests. Wait a moment and try again."}\n` and closes).
3. Server computes the exact same `code` from `(serverFP, clientFP)` and prompts the local user:
   - Shows requester's `name`, `os`, and `code` (`"048 291"`).
   - User clicks **Allow** or **Decline** (times out after 90 seconds).
4. If **Decline** or timeout: server replies `{"ok":false,"error":"Declined on <server-name>."}\n` and closes.
5. If **Allow**:
   - Server persists `DirectPeer(id: clientDevice, name: clientName, os: clientOS, fingerprint: clientFP, ...)` into `DirectPeers` and enables `direct:<client-id>` (or accepts incoming sync from it).
   - Server replies:
     ```json
     {"ok":true,"device":"<server-id>","name":"<server-name>","os":"<server-os>"}
     ```
   - Client persists `DirectPeer(id: serverDevice, name: serverName, os: serverOS, fingerprint: serverFP, ...)` and enables `direct:<server-id>` in `SyncEngine.enabledHosts`.
   - Both close the pairing connection; client immediately connects in `"sync"` mode.

### 4.3 Mode `"pair-qr"` (Direct QR Fallback — Zero SSH)
Used when mDNS is blocked (corporate/university Wi-Fi) or for instant 1-scan linking without matching 6 digits.

**QR URL format:**
```text
clipbubble://direct?v=2&id=<server-id>&fp=<64-char-server-fp>&h=<addr1,addr2>&p=<port>&c=<32-hex-token>&n=<url-encoded-name>&os=<os>
```

Flow:
1. Server generates a one-time random 128-bit hex token `c` (valid 10 minutes, max 5 wrong guesses before invalidating).
2. Client parses QR URL, connects over mTLS to `h:p` (racing addresses like existing `Pair.swift`), and **STRICTLY verifies `serverFP == qr.fp` BEFORE sending `c`!** (If `serverFP != qr.fp`, abort immediately — prevents leaking `c` to a MITM.)
3. Client sends:
   ```json
   {"mode":"pair-qr","v":2,"code":"<32-hex-token>","device":"<client-id>","name":"<client-name>","os":"<client-os>"}
   ```
4. Server verifies `code` matches active token and has not expired:
   - On failure: increment wrong counter (invalidate token at 5), reply `{"ok":false,"error":"Invalid or expired pairing code."}\n` and close.
   - On success: invalidate one-time token, save `DirectPeer` for client's `clientFP`, reply:
     ```json
     {"ok":true,"device":"<server-id>","name":"<server-name>","os":"<server-os>"}
     ```
5. Client saves `DirectPeer` (with `addresses = h`, `port = p`, `fingerprint = qr.fp`), enables `direct:<server-id>`, and connects in `"sync"` mode.

---

## 5. Peer Alias & Coexistence with SSH

- Direct peers use alias format: **`direct:<device-id>`** (lowercase UUID).
- Stored in `DirectPeers` (`sync.directPeers` in `Platform.defaults` on Apple; `<config-dir>/direct-peers.json` on Linux/Windows).
- `SyncEngine.enabledHosts` holds BOTH legacy SSH aliases (`you@host`, `clipbubble-...`) AND Direct aliases (`direct:<device-id>`).
- `Platform.dial(alias, ...)` dispatches `direct:*` aliases to `DirectTunnel` and everything else to existing SSH transport.
- Simultaneous dial deduplication (`device < h.device` in `SyncEngine.handle(.hello)`) works identically for Direct peers!
- When a Direct peer is unlinked/removed, `DirectPeers.remove(id)` removes its trusted fingerprint AND closes any active session from that peer (`SyncEngine.dropDirect(deviceId)` or `dropUntrusted()`).
