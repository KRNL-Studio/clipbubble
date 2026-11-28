#!/usr/bin/env bash
# Run both directions across real Apple/Python TLS sockets on macOS.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Direct interop needs macOS with swiftc (Apple Network and Security frameworks)." >&2
    exit 1
fi

supports_python_tls() {
    "$1" -c 'import ssl; assert ssl.OPENSSL_VERSION.startswith("OpenSSL ") and ssl.HAS_TLSv1_3 and hasattr(ssl.SSLContext, "_msg_callback")' >/dev/null 2>&1
}

python=${PYTHON:-python3}
if [[ -z "${PYTHON:-}" ]] && ! supports_python_tls "$python" && command -v uv >/dev/null; then
    python=$(uv python find --no-python-downloads '>=3.9') || python=python3
fi
if ! supports_python_tls "$python"; then
    echo "Set PYTHON to a CPython executable backed by OpenSSL with TLS 1.3 and _msg_callback." >&2
    exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/clipbubble-direct-interop.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
# The unique executable name also isolates the standard macOS preferences domain.
swift_driver="$work/direct-interop-${work##*.}"
sources=()
for source in Sources/*.swift; do
    if [[ "$source" != Sources/main.swift ]]; then
        sources+=("$source")
    fi
done
swiftc -swift-version 5 "${sources[@]}" Tests/DirectInterop/Driver.swift -o "$swift_driver"

export PYTHONPATH="$PWD/Linux"
export PYTHONDONTWRITEBYTECODE=1
status=0
for swift_role in client server; do
    CLIPBUBBLE_HOME="$work/$swift_role/python-home" \
        CLIPBUBBLE_DOWNLOADS="$work/$swift_role/python-home/Downloads" \
        "$python" -u Tests/DirectInterop/run.py "$swift_role" "$swift_driver" "$work/$swift_role" || status=1
done
exit "$status"
