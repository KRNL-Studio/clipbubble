# New-Mac SSH sync onboarding and diagnostics

Status: proposed; specification only. Based on the 2026-11-12 migration, with ClipBubble 1.6.1 and source `a2316d7`. P1 means setup-blocking; P2 means recoverable friction. Examples below are synthetic.

## Evidence and boundaries

A new Mac had no SSH config or saved sync peers. Connecting an existing Mac and Linux workstation required external preparation of aliases, the correct remote usernames, a dedicated key, independently verified host keys, and restricted remote authorization. Both peers linked successfully after that preparation. Both also reconnected after a normal app restart, with Open at login enabled.

This did **not** establish a clipboard transport, reconnect, or encryption defect. A wrong remote username, missing authorized key, and unpinned host key are configuration failures. The product gap is that the UI cannot guide a user through them. No clipboard content is included in this report.

## CB-MIG-01 — Guided setup for a new computer (P1, observed setup gap)

**Current behavior:** Settings offers an empty-host message pointing at `~/.ssh/config`. The session needed shell work and another computer's operator before any useful connection could be enabled.

**Reproduction:** Start with a clean synthetic macOS account, no SSH config, and two existing peers with different usernames. Open Settings → Sync over SSH.

**Required behavior:** Add a peer flow that captures its name, address, remote username, and existing SSH identity or a dedicated ClipBubble identity. Show the effective connection before saving. Prefer least-privilege `--peer` authorization; do not imply that a clipboard key grants a general shell. If remote administration is unavailable, produce a concise public-key installation handoff with the expected peer command and a return-to-setup check.

**Acceptance:**

- A user can configure one Mac and one Linux peer without manually writing SSH syntax.
- Per-host usernames survive save/restart; an authentication failure names the effective user and host without exposing credentials.
- Existing config, Include files, keys, and authorized-key entries are preserved. A saved alias never silently replaces another connection.
- Creating or selecting an identity does not transfer any private key. The handoff contains public material only.
- Nothing syncs until the user enables that peer and sees which clipboard, screenshot, and file data will be shared.
- Open at login is an explicit choice, and setup reports its actual registration state.

## CB-MIG-02 — Separate trust, authentication, and application failures (P1, observed gap plus source finding)

**Evidence:** The session had distinct host-key and user-key prerequisites. `LinkState.unknownHost` currently tells the user to connect once in Terminal; `HostLink.exited()` classifies the generic `Host key verification failed` text. That is insufficient to distinguish a first connection from a changed host key. The existing states for missing app, stopped app, and incompatible version should remain distinct.

**Required behavior:** Present a staged diagnostic: network → host identity → SSH user authentication → peer executable → protocol handshake. An unknown host offers independent fingerprint verification. A changed key is a hard stop with recovery guidance, not the same first-connection instruction. Show a retry action once an external prerequisite has been fixed.

**Acceptance:** Synthetic tests cover unknown key, changed key, wrong username, unauthorized key, offline peer, missing app, stopped app, and incompatible protocol. No repair sets `StrictHostKeyChecking=no`, replaces a pin silently, broadens a forced-command key, or displays private key bytes.

## CB-MIG-03 — Safe verification without opening clipboard history (P2, observed diagnostic gap)

**Evidence:** Verification used a carefully bounded SSH hello probe, then the settings link states. Opening the ordinary clipboard panel to find settings risks displaying unrelated history.

**Required behavior:** Provide a direct settings entry and a supported metadata-only `doctor` or equivalent status interface. Report peer label, negotiated protocol/version, link state, last successful connection, enabled state, and launch-at-login state. It must not fetch, print, log, or serialize history payloads. Do not implement diagnostics by dumping the first arbitrary bytes of the sync stream.

**Acceptance:** A synthetic end-to-end test links both platforms, restarts the app, verifies automatic reconnect, and checks that diagnostics contain no seeded clipboard text, images, screenshots, file contents, or authentication material. Distinguish “handshake passed” from “sample item delivered”; an optional transfer test must use an explicitly created disposable item.

## Implementation map and completion

- [Sync settings](../../Sources/UI.swift): empty state, peer setup, diagnostic entry, launch-at-login result.
- [SSH transport and config](../../Sources/MacLink.swift): effective connection and trust diagnostics.
- [Link state and reconnect](../../Sources/Link.swift): classified errors and metadata-only health.
- [Remote setup](../../Sources/Setup.swift) and [protocol](../sync-protocol.md): restricted authorization and diagnostic contract.

The migration workaround is complete; the product changes above remain open. General-purpose SSH access is outside this spec. Keep key restrictions and clipboard privacy intact.
