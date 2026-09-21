#!/bin/zsh
set -euo pipefail

probe_root="${0:A:h:h}"
app_binary="$probe_root/.build/variants/unsandboxed/SecurityBoundaryProbe.app/Contents/MacOS/SecurityBoundaryProbe"
private_root="$(mktemp -d "${TMPDIR:-/tmp}/security-boundary-lock-check.XXXXXX")"
artifact="$private_root/readability.txt"
service="com.example.dailyplanner.security-boundary-lock-check"
account="after-first-unlock"

cleanup() {
  security delete-generic-password -s "$service" -a "$account" >/dev/null 2>&1 || true
  rm -rf "$private_root"
}
trap cleanup EXIT

if [[ ! -x "$app_binary" ]]; then
  "$probe_root/Scripts/build-variants.sh"
fi

printf 'Press Return, then lock the Mac within 10 seconds. The helper samples after 15 seconds; unlock normally afterward.\n'
read -r

"$app_binary" \
  --lock-helper \
  --artifact "$artifact" \
  --delay-seconds 15 &
helper_pid=$!
wait "$helper_pid"

result="$(<"$artifact")"
rm "$artifact"
printf '%s\n' "$result"
printf 'private_artifact_deleted=true\n'
