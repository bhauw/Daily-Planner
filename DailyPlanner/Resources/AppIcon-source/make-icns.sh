#!/bin/zsh
# Regenerate Resources/AppIcon.icns from the procedural master art.
# Run this after editing make-icon.py; the resulting AppIcon.icns is committed
# and consumed verbatim by build-app.sh.
set -euo pipefail

here="${0:A:h}"
resources="${here:h}"
master="$here/AppIcon-1024.png"

python3 "$here/make-icon.py"

iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"

# All sizes macOS requires: 16/32/128/256/512 at @1x and @2x.
for spec in \
  "16:icon_16x16.png" \
  "32:icon_16x16@2x.png" \
  "32:icon_32x32.png" \
  "64:icon_32x32@2x.png" \
  "128:icon_128x128.png" \
  "256:icon_128x128@2x.png" \
  "256:icon_256x256.png" \
  "512:icon_256x256@2x.png" \
  "512:icon_512x512.png" \
  "1024:icon_512x512@2x.png"; do
  px="${spec%%:*}"
  name="${spec##*:}"
  sips -z "$px" "$px" "$master" --out "$iconset/$name" >/dev/null
done

iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"
rm -rf "${iconset:h}"
echo "wrote $resources/AppIcon.icns"
