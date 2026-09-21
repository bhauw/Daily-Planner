#!/bin/zsh
set -euo pipefail

# Build, sign, verify, and install Daily Planner into /Applications with a
# stable code identity so the Keychain-backed settings survive rebuilds.
# Fails closed: if signing or verification fails at any step, nothing is
# installed and the previous /Applications copy is left untouched.

planner_root="${0:A:h:h}"
build_script="$planner_root/Scripts/build-app.sh"
verify_script="$planner_root/Tests/verify-signed-app.sh"
built_app="$planner_root/.build/app/Daily Planner.app"
dest="/Applications/Daily Planner.app"

# 1. Build + sign. build-app.sh exits non-zero (fail-closed) when the real
#    signing identity is absent or signing never lands; set -e aborts here.
zsh "$build_script"

# 2. Independent gate — refuse to proceed unless the bundle is a valid,
#    non-adhoc, properly sealed, unsandboxed app with a real icon.
zsh "$verify_script"

test -d "$built_app"

# 3. Install atomically. Stage a signed copy beside the target with ditto
#    (which preserves the embedded signature), verify it at the destination
#    volume, then swap it in with a rename so a launch never observes a
#    half-copied bundle.
#
#    NOTE: ditto copies extended attributes FROM THE SOURCE, and the source
#    lives under iCloud-synced Documents/. FileProvider reattaches
#    com.apple.FinderInfo / com.apple.fileprovider.fpfs#P to the built bundle
#    in the seconds after build-app.sh signs and verifies it, so the staged
#    copy arrives carrying "Finder information" and codesign rejects it with
#    "resource fork, Finder information, or similar detritus not allowed".
#    /Applications itself is a normal APFS volume with no FileProvider, so
#    stripping xattrs on the staged copy is durable — they do not come back.
#    This strips only the staged copy; the embedded signature lives in the
#    Mach-O and _CodeSignature/, not in xattrs, so the seal is unaffected and
#    the verify below still gates the install fail-closed.
staging="/Applications/.Daily Planner.incoming.$$.app"
rm -rf "$staging"
ditto "$built_app" "$staging"
xattr -cr "$staging"
codesign --verify --deep --strict "$staging"

rm -rf "$dest"
mv "$staging" "$dest"

# 4. Post-install verification — prove the installed copy is valid and not
#    ad-hoc before declaring success.
codesign --verify --deep --strict "$dest"
if codesign -dvv "$dest" 2>&1 | grep -Eq 'Signature=adhoc|flags=[^ ]*adhoc'; then
  print -u2 "install-app.sh: installed bundle is ad-hoc signed — aborting."
  exit 1
fi

print "Installed and verified: $dest"
codesign -dvv "$dest" 2>&1 | grep -E 'Identifier=|Authority=|flags=' || true
