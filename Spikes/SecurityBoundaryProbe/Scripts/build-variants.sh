#!/bin/zsh
set -euo pipefail

probe_root="${0:A:h:h}"
build_root="$probe_root/.build/variants"
private_root="$(mktemp -d "${TMPDIR:-/tmp}/security-boundary-probe.XXXXXX")"
fake_vault="$private_root/FakeVault"
scratch_root="$private_root/swift-build"
codex_executable="$(command -v codex)"
service="com.example.dailyplanner.security-boundary-probe"

cleanup() {
  security delete-generic-password -s "$service" -a unsandboxed >/dev/null 2>&1 || true
  security delete-generic-password -s "$service" -a sandboxed >/dev/null 2>&1 || true
  rm -rf "$private_root"
}
trap cleanup EXIT

mkdir -p "$fake_vault/Daily"
printf 'synthetic boundary probe note\n' > "$fake_vault/Daily/2026-08-30.md"

swift build \
  --disable-index-store \
  --package-path "$probe_root" \
  --scratch-path "$scratch_root" \
  --configuration release \
  --product SecurityBoundaryProbeApp

binary="$scratch_root/release/SecurityBoundaryProbeApp"
rm -rf "$build_root"

for variant in unsandboxed sandboxed; do
  app="$build_root/$variant/SecurityBoundaryProbe.app"
  mkdir -p "$app/Contents/MacOS"
  cp "$binary" "$app/Contents/MacOS/SecurityBoundaryProbe"
  cp "$probe_root/Resources/Info.plist" "$app/Contents/Info.plist"
  xattr -cr "$app"
  if [[ "$variant" == sandboxed ]]; then
    entitlements="$probe_root/Resources/Sandbox.entitlements"
  else
    entitlements="$probe_root/Resources/Unrestricted.entitlements"
  fi
  codesign --force --sign - --entitlements "$entitlements" "$app"
  codesign --verify --deep --strict "$app"
done

for variant in unsandboxed sandboxed; do
  app_binary="$build_root/$variant/SecurityBoundaryProbe.app/Contents/MacOS/SecurityBoundaryProbe"
  set +e
  result="$("$app_binary" \
    --automated \
    --variant "$variant" \
    --fake-vault "$fake_vault" \
    --codex "$codex_executable" 2>/dev/null)"
  probe_exit=$?
  set -e
  printf '%s_status=%s\n' "$variant" "$probe_exit"
  printf '%s_result=%s\n' "$variant" "$result"
done

for account in unsandboxed sandboxed; do
  if security find-generic-password -s "$service" -a "$account" >/dev/null 2>&1; then
    printf '%s_keychain_cleanup=false\n' "$account"
  else
    printf '%s_keychain_cleanup=true\n' "$account"
  fi
done

for variant in unsandboxed sandboxed; do
  app="$build_root/$variant/SecurityBoundaryProbe.app"
  xattr -cr "$app"
  xattr -c "$app"
  codesign --verify --deep --strict "$app"
  printf '%s_signature_valid=true\n' "$variant"
done

printf 'private_artifacts_cleanup=scheduled\n'
