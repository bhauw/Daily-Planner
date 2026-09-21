#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h:h}"
planner_root="$repo_root/DailyPlanner"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-m1-verify.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

swift test --package-path "$planner_root" --scratch-path "$scratch/swift" --no-parallel
zsh "$planner_root/Scripts/build-app.sh"
zsh "$planner_root/Tests/verify-signed-app.sh"
git -C "$repo_root" diff --check

assert_no_source_match() {
  local source_root="$1"
  local pattern="$2"
  if rg -l "$pattern" "$source_root"; then
    return 1
  fi
}

verify_source_hygiene() {
  local source_root="$1"
  local package_file="$2"
  local allowed_private_io="$source_root/DailyPlannerPersistence/EncryptedPrivateSettingsStore.swift"
  local allowed_bookmark_creator="$source_root/DailyPlannerPlatform/MacVaultFolderPicker.swift"
  local private_io_callers
  local bookmark_creators

  assert_no_source_match "$source_root" 'URLSession|URLRequest|import[[:space:]]+Network|NW(Connection|Listener)|CFNetwork|Process[[:space:]]*[(]|NSTask|NSFileCoordinator|startAccessingSecurityScopedResource|resolvingBookmarkData|FileHandle' || return 1
  assert_no_source_match "$source_root" 'gmail[.]googleapis[.]com|calendar/v3|tasks/v1|oauth2[.]googleapis[.]com|codex app-server' || return 1
  assert_no_source_match "$source_root" '(^|[^A-Za-z])(print|debugPrint|dump|NSLog|os_log|fatalError|preconditionFailure|assertionFailure)[[:space:]]*[(]|Logger[[:space:]]*[(]' || return 1

  private_io_callers="$(rg -l 'Data[[:space:]]*[(]contentsOf:|String[[:space:]]*[(]contentsOf:|[.]write[[:space:]]*[(]to:|createDirectory[[:space:]]*[(]|contentsOfDirectory|enumerator[[:space:]]*[(]|contents[[:space:]]*[(]atPath:' "$source_root" || true)"
  [[ -z "$private_io_callers" || "$private_io_callers" == "$allowed_private_io" ]] || return 1

  bookmark_creators="$(rg -l 'bookmarkData[[:space:]]*[(]' "$source_root" || true)"
  [[ "$bookmark_creators" == "$allowed_bookmark_creator" ]] || return 1

  ! rg -l '[.]package[[:space:]]*[(]' "$package_file" || return 1
  ! rg -il 'name:[[:space:]]*"[^"]*(Google|Codex|VaultAdapter|Helper|Broker|Updater|Executor)' "$package_file" || return 1
}

verify_source_hygiene "$planner_root/Sources" "$planner_root/Package.swift"

cp -R "$planner_root/Sources" "$scratch/hygiene-sources"
cp "$planner_root/Package.swift" "$scratch/hygiene-Package.swift"
print 'let syntheticForbiddenCanary = URLSession.shared' > "$scratch/hygiene-sources/ForbiddenCanary.swift"
if verify_source_hygiene "$scratch/hygiene-sources" "$scratch/hygiene-Package.swift" >/dev/null 2>&1; then
  exit 1
fi

binary="$planner_root/.build/app/Daily Planner.app/Contents/MacOS/DailyPlanner"
"$binary" >/dev/null 2>&1 &
planner_pid=$!
alive=0
for _ in {1..10}; do
  if kill -0 "$planner_pid" 2>/dev/null; then
    alive=1
    break
  fi
  sleep 0.1
done
[[ "$alive" -eq 1 ]]
kill "$planner_pid"
wait "$planner_pid" 2>/dev/null || true
if kill -0 "$planner_pid" 2>/dev/null; then
  exit 1
fi
zsh "$planner_root/Tests/verify-signed-app.sh"
