#!/bin/zsh
set -euo pipefail
probe_root="${0:A:h:h}"
app="$probe_root/.build/ToolchainProbe.app"
test -x "$app/Contents/MacOS/ToolchainProbe"

# Documents/File Provider can attach Finder metadata to the bundle after launch.
# These attributes are not part of the signed contents, but codesign rejects them.
xattr -cr "$app"
xattr -c "$app"

if [[ "${1:-}" == "--launch-cycle" ]]; then
  "$app/Contents/MacOS/ToolchainProbe" >/dev/null 2>&1 &
  launch_pid=$!
  launch_seen=false
  for _ in {1..50}; do
    if kill -0 "$launch_pid" 2>/dev/null; then
      launch_seen=true
      break
    fi
    sleep 0.1
  done
  [[ "$launch_seen" == true ]]

  kill "$launch_pid"
  exited=false
  for _ in {1..50}; do
    if kill -0 "$launch_pid" 2>/dev/null; then
      sleep 0.1
    else
      exited=true
      break
    fi
  done
  if [[ "$exited" != true ]]; then
    kill -KILL "$launch_pid" 2>/dev/null || true
    for _ in {1..50}; do
      if kill -0 "$launch_pid" 2>/dev/null; then
        sleep 0.1
      else
        exited=true
        break
      fi
    done
  fi
  wait "$launch_pid" 2>/dev/null || true
  [[ "$exited" == true ]]
  xattr -cr "$app"
  xattr -c "$app"
fi

codesign --verify --deep --strict "$app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" \
  | rg -xq 'com.example.dailyplanner.toolchain-probe'
