#!/bin/zsh
# Renders the App Store screenshots: index.html is one 9240×2868 panorama, cut into seven 1320×2868 (6.9-inch) slides.
# The raw captures in img/ come from a debug build on the 6.9-inch simulator launched with -demo YES (see Model.init),
# a seeded history, light appearance except the keyboard shot (dark), and a 9:41 status bar.
# Needs Google Chrome and network access for the Instrument Serif font.
set -e
cd "${0:A:h}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=1 --allow-file-access-from-files --virtual-time-budget=8000 --window-size=9240,2868 \
  --user-data-dir="$tmp/chrome" --screenshot="$tmp/pano.png" "file://$PWD/index.html" 2>/dev/null
swiftc -O slice.swift -o "$tmp/slice"
"$tmp/slice" "$tmp/pano.png" "$tmp"
names=(1-mac-to-iphone 2-link-in-one-tap 3-keyboard 4-library 5-share 6-peek 7-private)
for i in {1..7}; do mv "$tmp/$i.png" "../screenshots/${names[$i]}.png"; done
echo "Wrote ${#names} screenshots to iOS/AppStore/screenshots"
