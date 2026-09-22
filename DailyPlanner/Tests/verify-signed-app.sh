#!/bin/zsh
set -euo pipefail

planner_root="${0:A:h:h}"
app="$planner_root/.build/app/Daily Planner.app"
binary="$app/Contents/MacOS/DailyPlanner"

test -x "$binary"

# The repo lives in iCloud-synced Documents/; FileProvider keeps reattaching
# xattrs (com.apple.FinderInfo / provenance) onto the bundle between our
# xattr-clear and codesign's read, which trips "resource fork ... detritus not
# allowed" on a single-shot verify. build-app.sh guards its own signing with a
# bounded loop for the same reason; mirror it here so this verifier is not
# itself flaky. Same assertion (codesign --verify --deep --strict must pass),
# just made resilient to the reattachment race — bounded, never re-signs.
verify_seal_at_rest() {
  local attempt
  for attempt in {1..8}; do
    xattr -cr "$app"
    xattr -c "$app"
    if codesign --verify --deep --strict "$app"; then
      return 0
    fi
    sleep "$(printf '%.1f' "$(( attempt * 0.5 ))")"
  done
  return 1
}
if ! verify_seal_at_rest; then
  print -u2 "verify-signed-app.sh: bundle failed codesign --verify --deep --strict."
  exit 1
fi

/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" \
  | grep -xq 'com\.braxton\.dailyplanner'

if codesign -d --entitlements :- "$app" 2>&1 \
  | grep -q 'com[.]apple[.]security[.]app-sandbox'; then
  exit 1
fi

# --- Stable-identity assertions (added for the packaging/signing milestone) ---
# codesign -dvv writes its display to stderr, so redirect it.
sig_info="$(codesign -dvv "$app" 2>&1)"

# The signature must NOT be ad-hoc — an ad-hoc requirement is a per-build cdhash
# that changes on every rebuild and breaks the Keychain-backed settings.
if print -r -- "$sig_info" | grep -Eq 'Signature=adhoc|flags=[^ ]*adhoc'; then
  print -u2 "verify-signed-app.sh: signature is ad-hoc."
  exit 1
fi

# A real signing authority must be present (a named identity, not ad-hoc). Local
# development certs carry no TeamIdentifier, so assert on the Authority chain.
if ! print -r -- "$sig_info" | grep -q '^Authority='; then
  print -u2 "verify-signed-app.sh: no signing authority present."
  exit 1
fi

# CFBundleIconFile must resolve to a file that actually exists in the bundle.
icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist")"
if [[ -z "$icon_name" ]]; then
  print -u2 "verify-signed-app.sh: CFBundleIconFile is unset."
  exit 1
fi
if [[ ! -f "$app/Contents/Resources/$icon_name" \
   && ! -f "$app/Contents/Resources/$icon_name.icns" ]]; then
  print -u2 "verify-signed-app.sh: icon file for CFBundleIconFile '$icon_name' is missing."
  exit 1
fi
