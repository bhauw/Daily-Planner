#!/bin/zsh
set -euo pipefail

planner_root="${0:A:h:h}"
private_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-m1-build.XXXXXX")"
# The bundle is assembled AND signed here, in a plain /tmp scratch that is NOT
# part of the iCloud-synced Documents/ tree. See sign_generated_app() for why.
staging_app="$private_scratch/Daily Planner.app"
app="$planner_root/.build/app/Daily Planner.app"
trap 'rm -rf "$private_scratch"' EXIT

# Stable code identity — the app's Keychain items are keyed to the app's
# designated requirement. An ad-hoc signature's requirement is a per-build
# cdhash, so it changes on every rebuild and the Keychain rejects the item
# ("Settings are unavailable."). Signing with a real, named identity gives a
# certificate-based requirement that survives rebuilds. Look the identity up by
# name so no certificate hash is baked into the repo; fail closed if it is gone
# rather than silently degrading to ad-hoc.
signing_identity_name="Daily Planner Local Development"
identity_line="$(security find-identity -v -p codesigning \
  | grep -F "\"$signing_identity_name\"" | head -n1 || true)"
if [[ -z "$identity_line" ]]; then
  print -u2 "build-app.sh: signing identity \"$signing_identity_name\" not found."
  print -u2 "  Available code-signing identities:"
  security find-identity -v -p codesigning >&2 || true
  print -u2 "  Refusing to fall back to ad-hoc signing — the Keychain item would"
  print -u2 "  break on the next rebuild. Create/import the identity and retry."
  exit 1
fi
# Pull the 40-char hex SHA-1 fingerprint out of the `find-identity` line. Do NOT
# word-split on whitespace: the line begins "  1) <hash> ..." and shell tokenisers
# treat the ")" as its own token, so positional indexing silently grabs ")" and
# codesign then fuzzy-matches the wrong identity (errSecInternalComponent,
# "unable to build chain to self-signed root"). Match the fingerprint directly.
signing_identity_hash="$(print -r -- "$identity_line" | grep -oE '[0-9A-Fa-f]{40}' | head -n1)"
if [[ -z "$signing_identity_hash" ]]; then
  print -u2 "build-app.sh: could not parse a code-signing fingerprint from:"
  print -u2 "  $identity_line"
  exit 1
fi

swift build \
  --package-path "$planner_root" \
  --scratch-path "$private_scratch/swift" \
  --configuration debug \
  --product DailyPlannerApp

binary_path="$(swift build --package-path "$planner_root" --scratch-path "$private_scratch/swift" --configuration debug --show-bin-path)/DailyPlannerApp"
mkdir -p "$staging_app/Contents/MacOS"
mkdir -p "$staging_app/Contents/Resources"
cp "$binary_path" "$staging_app/Contents/MacOS/DailyPlanner"
cp "$planner_root/Resources/Info.plist" "$staging_app/Contents/Info.plist"
cp "$planner_root/Resources/AppIcon.icns" "$staging_app/Contents/Resources/AppIcon.icns"

# The UI for this milestone IS the web app: AppComposition.bundledWebRoot() looks
# for Contents/Resources/web (then .../dist) and, finding neither, serves the
# "web UI bundle has not been built yet" placeholder. Copying the built bundle in
# here — BEFORE signing — is what makes the shipped app show the real React shell
# and seals the assets into the signature. ditto then xattr -c because web/dist
# lives under iCloud-synced Documents/ and its FileProvider xattrs would
# otherwise make codesign reject the bundle as "Finder information".
web_dist="$planner_root/../web/dist"
if [[ -d "$web_dist" && -f "$web_dist/index.html" ]]; then
  ditto "$web_dist" "$staging_app/Contents/Resources/web"
  xattr -cr "$staging_app/Contents/Resources/web"
else
  print -u2 "build-app.sh: WARNING — no built web UI at $web_dist"
  print -u2 "  The app will ship WITHOUT its interface and fall back to the"
  print -u2 "  placeholder page. Run 'npm run build' in web/ and rebuild."
fi

wait_for_quiet_signing_window() {
  # Concurrent Swift compiles (swiftc / swift-frontend / swift-driver) or another
  # codesign — e.g. a second fleet worker building at the same time — contend
  # with securityd and make codesign fail intermittently with
  # errSecInternalComponent ("unable to build chain to self-signed root").
  # Verified: with the machine quiet, this exact bundle+identity signs 10/10; the
  # only failures coincide with a parallel build. This also honours the brief's
  # "serial builds only" rule. Wait (bounded, ~5 min) for a quiet window; if it
  # never comes, fall through and let the retry loop try anyway.
  local waited=0
  while (( waited < 300 )); do
    if [[ -z "$(pgrep -x swiftc || true)$(pgrep -x swift-frontend || true)$(pgrep -f swift-driver || true)$(pgrep -x codesign || true)" ]]; then
      return 0
    fi
    sleep 3
    waited=$(( waited + 3 ))
  done
  return 0
}

sign_generated_app() {
  # The repo lives in iCloud-synced Documents/; FileProvider keeps reattaching
  # xattrs (com.apple.FinderInfo / provenance / quotas) onto any bundle under
  # that tree between our xattr-clear and codesign's read. Under a real (non
  # ad-hoc) identity that trips codesign with "resource fork ... detritus not
  # allowed" or errSecInternalComponent and burns every attempt — verified: the
  # same bundle signs cleanly on the FIRST try in a plain /tmp scratch. So we
  # assemble and sign in $private_scratch (outside iCloud) here; the caller then
  # relocates the already-signed bundle into .build/app. Wait for a quiet
  # securityd window (see above), then retry clear/sign/verify a bounded number
  # of times with linear backoff to absorb any residual flake.
  # Load-bearing — do not remove the loop.
  local target="$1"
  local attempt
  for attempt in {1..8}; do
    wait_for_quiet_signing_window
    xattr -cr "$target"
    xattr -c "$target"
    if codesign --force --sign "$signing_identity_hash" "$target" \
       && codesign --verify --deep --strict "$target"; then
      return 0
    fi
    # Linear backoff (0.5s, 1.0s, ... up to 4.0s). The rapid 0.1s retries used
    # to burn all attempts inside a single iCloud xattr burst.
    sleep "$(printf '%.1f' "$(( attempt * 0.5 ))")"
  done
  return 1
}

if ! sign_generated_app "$staging_app"; then
  print -u2 "build-app.sh: signing failed after 8 attempts — refusing to emit an"
  print -u2 "  unsigned or invalidly-signed bundle."
  exit 1
fi

# Relocate the fully-signed bundle into .build/app for downstream consumers
# (install-app.sh, verify-signed-app.sh). ditto preserves the embedded code
# signature; the destination is under iCloud, so defensively clear reattached
# xattrs and re-verify (never re-sign) until the seal reads clean at rest.
rm -rf "$app"
mkdir -p "${app:h}"
ditto "$staging_app" "$app"
for attempt in {1..8}; do
  xattr -cr "$app"
  xattr -c "$app"
  if codesign --verify --deep --strict "$app"; then
    break
  fi
  if (( attempt == 8 )); then
    print -u2 "build-app.sh: relocated bundle failed verification at rest."
    exit 1
  fi
  sleep "$(printf '%.1f' "$(( attempt * 0.5 ))")"
done
