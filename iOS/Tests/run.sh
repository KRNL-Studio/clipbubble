#!/bin/zsh
set -euo pipefail
root=${0:A:h:h:h}
# App Store Connect rejects the upload (ITMS-90626) when a Shortcuts title, description or phrase names Apple products.
if grep -nEi '(IntentDescription|LocalizedStringResource|phrases:).*(iphone|ipad|apple|siri)' "$root/iOS/Sources/"*.swift; then
  echo "App Intent text must not name Apple products (ITMS-90626)." >&2
  exit 1
fi
package="$root/iOS/.build/wave3-host"
mkdir -p "$package/Sources"
cp "$root/iOS/Tests/"*.swift "$package/Sources/"
cp "$root/iOS/Shared/"{SSH,SSHChannelTransport,Pair,ShareOutbox,ShareSync,Courier}.swift "$package/Sources/"
cp "$root/Sources/"{DirectPeers,Link,Store,Sync}.swift "$package/Sources/"
# Keep dependency revisions aligned with the generated iOS project when available.
resolved="$root/iOS/ClipBubble.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [[ -f "$resolved" ]]; then cp "$resolved" "$package/Package.resolved"; fi
cat > "$package/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Wave3Tests",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh", from: "0.15.0"),
    ],
    targets: [
        .executableTarget(name: "Wave3Tests", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
        ], path: "Sources"),
    ],
    swiftLanguageModes: [.v5]
)
SWIFT
testHome=$(mktemp -d)
trap 'rm -rf "$testHome"' EXIT
CLIPBUBBLE_HOME="$testHome" swift run --package-path "$package" --jobs 6 Wave3Tests
