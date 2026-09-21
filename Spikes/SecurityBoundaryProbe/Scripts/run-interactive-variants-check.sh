#!/bin/zsh
set -euo pipefail

probe_root="${0:A:h:h}"
private_root="$(mktemp -d "${TMPDIR:-/tmp}/security-boundary-panel-check.XXXXXX")"
fake_vault="$private_root/FakeVault"
service="com.example.dailyplanner.security-boundary-probe"
active_pid=""

cleanup() {
  if [[ -n "$active_pid" ]]; then
    kill -TERM "$active_pid" >/dev/null 2>&1 || true
    wait "$active_pid" >/dev/null 2>&1 || true
  fi
  for variant in unsandboxed sandboxed; do
    app_binary="$probe_root/.build/variants/$variant/SecurityBoundaryProbe.app/Contents/MacOS/SecurityBoundaryProbe"
    if [[ -x "$app_binary" ]]; then
      "$app_binary" --interactive-cleanup --variant "$variant" >/dev/null 2>&1 || true
    fi
    security delete-generic-password -s "$service" -a "$variant" >/dev/null 2>&1 || true
  done
  rm -rf "$private_root"
}
stop_on_signal() {
  exit 130
}
trap cleanup EXIT
trap stop_on_signal INT TERM HUP

if [[ ! -x "$probe_root/.build/variants/unsandboxed/SecurityBoundaryProbe.app/Contents/MacOS/SecurityBoundaryProbe" || \
      ! -x "$probe_root/.build/variants/sandboxed/SecurityBoundaryProbe.app/Contents/MacOS/SecurityBoundaryProbe" ]]; then
  "$probe_root/Scripts/build-variants.sh"
fi

mkdir -p "$fake_vault/Daily"
printf 'synthetic boundary probe note\n' > "$fake_vault/Daily/2026-08-30.md"

for variant in unsandboxed sandboxed; do
  app_binary="$probe_root/.build/variants/$variant/SecurityBoundaryProbe.app/Contents/MacOS/SecurityBoundaryProbe"
  selection_artifact="$private_root/$variant-selection.json"
  resolve_artifact="$private_root/$variant-resolve.json"

  printf '%s: select only the generated FakeVault folder.\n' "$variant"
  "$app_binary" \
    --interactive-select \
    --variant "$variant" \
    --fake-vault "$fake_vault" \
    >"$selection_artifact" 2>/dev/null &
  active_pid=$!
  wait "$active_pid"
  active_pid=""

  selection_status="$(plutil -extract status raw -o - "$selection_artifact")"
  printf '%s_selection=%s\n' "$variant" "$(<"$selection_artifact")"
  rm "$selection_artifact"
  if [[ "$selection_status" != saved ]]; then
    printf '%s_relaunch=notAttempted\n' "$variant"
    continue
  fi

  "$app_binary" \
    --interactive-resolve \
    --variant "$variant" \
    >"$resolve_artifact" 2>/dev/null &
  active_pid=$!
  wait "$active_pid"
  active_pid=""

  printf '%s_relaunch=%s\n' "$variant" "$(<"$resolve_artifact")"
  rm "$resolve_artifact"
done

printf 'interactive_private_artifacts_deleted=true\n'
