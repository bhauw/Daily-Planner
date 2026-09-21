#!/bin/zsh
set -euo pipefail

umask 077

repo_root="${0:A:h:h:h}"
planner_root="$repo_root/DailyPlanner"
tmp_base="${TMPDIR:-/tmp}"
tmp_base="${tmp_base%/}"
scratch="$(mktemp -d "$tmp_base/daily-planner-m2a-verify.XXXXXX")"

case "$scratch" in
  "$tmp_base"/daily-planner-m2a-verify.*) ;;
  *)
    print -u2 -r -- 'M2A verifier could not validate its scratch root'
    exit 1
    ;;
esac

planner_pid=''
planner_identity=''
planner_fallback_identity=''
planner_fallback_job_owned=0
planner_fallback_group=''
planner_fallback_known_gone=0
planner_guardian_pid=''
planner_guardian_identity=''
planner_guardian_command=''
planner_guardian_known_gone=0
planner_guardian_handshake_verified=0
planner_guardian_status=''
planner_guardian_control=''
launch_capture_pid=''
launch_capture_identity=''
launch_capture_command=''
launch_capture_fallback_identity=''
launch_capture_fallback_job_owned=0
launch_capture_fallback_group=''
launch_capture_fallback_known_gone=0
active_command_pid=''
active_command_identity=''
active_command_command=''
active_command_group=''
active_command_fallback_identity=''
active_command_fallback_command=''
active_command_fallback_job_owned=0
active_command_fallback_group=''
active_command_fallback_known_gone=0
active_command_wait_status=0
active_command_descendant_pids=()
typeset -A active_command_descendant_births
typeset -A active_command_descendant_commands
typeset -A active_command_descendant_parents
typeset -A active_command_descendant_depths
typeset -A active_command_descendant_provenance
active_capture_pid=''
active_capture_identity=''
active_capture_command=''
active_capture_fallback_identity=''
active_capture_fallback_job_owned=0
active_capture_fallback_group=''
active_capture_fallback_known_gone=0
active_capture_keepalive_fd=''
launch_capture_keepalive_fd=''
active_run_sequence=0
interruption_deferral_depth=0
pending_interruption_status=''
verifier_completed=0

process_identity() {
  local pid="$1"
  local parent
  local started

  parent="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')" || return 1
  started="$(ps -p "$pid" -o lstart= 2>/dev/null)" || return 1
  [[ -n "$parent" && -n "$started" ]] || return 1
  print -r -- "$parent|$started"
}

process_command() {
  local pid="$1"
  ps -p "$pid" -o command= 2>/dev/null
}

process_state() {
  local pid="$1"
  ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]'
}

process_group() {
  local pid="$1"
  ps -p "$pid" -o pgid= 2>/dev/null | tr -d '[:space:]'
}

process_birth() {
  local pid="$1"

  ps -p "$pid" -o lstart= 2>/dev/null
}

process_parent() {
  local pid="$1"

  ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]'
}

process_matches_expected() {
  local pid="$1"
  local identity="$2"
  local expected_command="$3"

  [[ -n "$identity" && -n "$expected_command" \
    && "$(process_identity "$pid" || true)" == "$identity" \
    && "$(process_command "$pid" || true)" == "$expected_command" ]]
}

begin_interruption_deferral() {
  ((interruption_deferral_depth += 1)) || true
}

end_interruption_deferral() {
  local requested_status

  [[ "$interruption_deferral_depth" -gt 0 ]] || return 1
  ((interruption_deferral_depth -= 1)) || true
  if [[ "$interruption_deferral_depth" -eq 0 && -n "$pending_interruption_status" ]]; then
    requested_status="$pending_interruption_status"
    pending_interruption_status=''
    exit "$requested_status"
  fi
  return 0
}

request_interruption() {
  local requested_status="$1"

  if [[ "$interruption_deferral_depth" -gt 0 ]]; then
    [[ -n "$pending_interruption_status" ]] || pending_interruption_status="$requested_status"
    return 0
  fi
  exit "$requested_status"
}

record_owned_child() {
  local pid="$1"
  local require_private_group="${2:-0}"
  local attempt
  local current_identity
  local current_command
  local current_group

  recorded_child_identity=''
  recorded_child_command=''
  recorded_child_fallback_identity=''
  recorded_child_fallback_command=''
  recorded_child_fallback_job_owned=0
  recorded_child_fallback_group=''
  recorded_child_fallback_known_gone=0
  [[ "$pid" == <-> && "$pid" -gt 1 ]] || return 1
  for attempt in {1..20}; do
    current_identity="$(process_identity "$pid" || true)"
    current_command="$(process_command "$pid" || true)"
    current_group="$(process_group "$pid" || true)"
    if is_unreaped_shell_job "$pid"; then
      recorded_child_fallback_job_owned=1
    fi
    if [[ "$current_group" == "$pid" \
      && ( "$current_identity" == "$$|"* || "$recorded_child_fallback_job_owned" -eq 1 || "$require_private_group" -eq 1 ) ]]; then
      recorded_child_fallback_group="$current_group"
    fi
    if [[ "$current_identity" == "$$|"* ]]; then
      # Retain every direct-child observation before deciding whether the
      # command observation is complete.  A deferred interruption may land
      # after this child exists but before its command becomes observable.
      recorded_child_fallback_identity="$current_identity"
      recorded_child_fallback_command="$current_command"
      if [[ -n "$current_command" \
        && ( "$require_private_group" -eq 0 || "$current_group" == "$pid" ) ]]; then
        recorded_child_identity="$current_identity"
        recorded_child_command="$current_command"
        return 0
      fi
    fi
    if [[ -z "$current_identity" ]] && ! kill -0 "$pid" 2>/dev/null; then
      recorded_child_fallback_known_gone=1
      return 2
    fi
    sleep 0.05
  done
  return 1
}

record_child_of_parent() {
  local pid="$1"
  local expected_parent="$2"
  local expected_command="$3"
  local attempt
  local current_identity
  local current_command

  recorded_child_identity=''
  recorded_child_command=''
  recorded_child_fallback_identity=''
  recorded_child_fallback_command=''
  recorded_child_fallback_job_owned=0
  recorded_child_fallback_group=''
  recorded_child_fallback_known_gone=0
  [[ "$pid" == <-> && "$pid" -gt 1 && "$expected_parent" == <-> && "$expected_parent" -gt 1 \
    && -n "$expected_command" ]] || return 1
  for attempt in {1..20}; do
    current_identity="$(process_identity "$pid" || true)"
    current_command="$(process_command "$pid" || true)"
    if [[ "$current_identity" == "$expected_parent|"* ]]; then
      recorded_child_fallback_identity="$current_identity"
      recorded_child_fallback_command="$current_command"
      if [[ "$current_command" == "$expected_command" ]]; then
        recorded_child_identity="$current_identity"
        recorded_child_command="$current_command"
        return 0
      fi
    fi
    if [[ -z "$current_identity" ]] && ! kill -0 "$pid" 2>/dev/null; then
      recorded_child_fallback_known_gone=1
      return 2
    fi
    sleep 0.05
  done
  return 1
}

is_unreaped_shell_job() {
  local pid="$1"
  local job_line
  local -a job_fields

  [[ "$pid" == <-> && "$pid" -gt 1 ]] || return 1
  while IFS= read -r job_line; do
    job_fields=(${=job_line})
    if [[ "${#job_fields}" -ge 4 && "${job_fields[3]}" == "$pid" \
      && "${job_fields[4]}" == (running|suspended) ]]; then
      return 0
    fi
  done <<< "$(jobs -p 2>/dev/null || true)"
  return 1
}

private_group_status() {
  local pid="$1"
  local group="$2"
  local current_group
  local members

  [[ "$pid" == <-> && "$pid" -gt 1 && "$group" == "$pid" ]] || return 1
  current_group="$(process_group "$pid" || true)"
  [[ -z "$current_group" || "$current_group" == "$group" ]] || return 1
  members="$(ps -ax -o pid=,pgid=,stat= 2>/dev/null \
    | awk -v expected_group="$group" '$2 == expected_group && $3 !~ /^Z/ { print $1 }')" || return 1
  [[ -n "$members" ]] && return 0
  return 2
}

fallback_child_status() {
  local pid="$1"
  local identity="$2"
  local job_owned="$3"
  local known_gone="$4"
  local group="$5"
  local current_identity
  local current_state

  [[ "$pid" == <-> && "$pid" -gt 1 ]] || return 1
  [[ "$known_gone" -eq 1 ]] && return 2
  if [[ -n "$identity" ]]; then
    current_identity="$(process_identity "$pid" || true)"
    if [[ -z "$current_identity" ]]; then
      kill -0 "$pid" 2>/dev/null && return 1
      return 2
    fi
    [[ "$current_identity" == "$identity" && "$identity" == "$$|"* ]] || return 1
    current_state="$(process_state "$pid" || true)"
    [[ "$current_state" == Z* ]] && return 2
    return 0
  fi

  if [[ -n "$group" ]]; then
    private_group_status "$pid" "$group"
    return $?
  fi

  if [[ "$job_owned" -eq 1 ]] && is_unreaped_shell_job "$pid"; then
    current_state="$(process_state "$pid" || true)"
    [[ "$current_state" == Z* ]] && return 2
    [[ -n "$current_state" ]] || return 1
    return 0
  fi
  [[ "$job_owned" -eq 1 ]] && return 2
  return 1
}

bounded_reap_fallback_child() {
  local pid="$1"
  local identity="$2"
  local job_owned="$3"
  local known_gone="$4"
  local group="$5"
  local child_status

  fallback_child_status "$pid" "$identity" "$job_owned" "$known_gone" "$group"
  child_status=$?
  case "$child_status" in
    0|1) return 1 ;;
    2)
      # wait is only reached after the exact child is gone or a zombie; it
      # cannot become an unbounded wait for a live PID.
      if [[ "$known_gone" -ne 1 ]] && is_unreaped_shell_job "$pid"; then
        wait "$pid" 2>/dev/null || true
      fi
      return 0
      ;;
  esac
  return 1
}

terminate_fallback_owned_child() {
  local pid="$1"
  local identity="$2"
  local job_owned="$3"
  local known_gone="$4"
  local group="$5"
  local signal_name
  local attempt
  local child_status

  for signal_name in TERM KILL; do
    fallback_child_status "$pid" "$identity" "$job_owned" "$known_gone" "$group"
    child_status=$?
    case "$child_status" in
      2) bounded_reap_fallback_child "$pid" "$identity" "$job_owned" "$known_gone" "$group"; return $? ;;
      1) return 1 ;;
    esac
    if [[ -n "$group" ]]; then
      private_group_status "$pid" "$group" || return 1
      kill -"$signal_name" -"$group" 2>/dev/null || true
    else
      kill -"$signal_name" "$pid" 2>/dev/null || true
    fi
    for attempt in {1..20}; do
      fallback_child_status "$pid" "$identity" "$job_owned" "$known_gone" "$group"
      child_status=$?
      case "$child_status" in
        0) sleep 0.05 ;;
        2) bounded_reap_fallback_child "$pid" "$identity" "$job_owned" "$known_gone" "$group"; return $? ;;
        *) return 1 ;;
      esac
    done
  done

  bounded_reap_fallback_child "$pid" "$identity" "$job_owned" "$known_gone" "$group"
}

bounded_reap_exact_child() {
  local pid="$1"
  local identity="$2"
  local expected_command="$3"
  local current_identity
  local current_command
  local current_state

  if [[ "$pid" != <-> || "$pid" -le 1 || -z "$identity" || -z "$expected_command" ]]; then
    return 1
  fi

  current_identity="$(process_identity "$pid" || true)"
  if [[ -z "$current_identity" ]]; then
    kill -0 "$pid" 2>/dev/null && return 1
    wait "$pid" 2>/dev/null || true
    return 0
  fi
  [[ "$current_identity" == "$identity" ]] || return 1
  current_state="$(process_state "$pid" || true)"
  if [[ "$current_state" != Z* ]]; then
    current_command="$(process_command "$pid" || true)"
    [[ "$current_command" == "$expected_command" ]] || return 1
    return 1
  fi
  wait "$pid" 2>/dev/null || true
}

terminate_exact_owned_child() {
  local pid="$1"
  local identity="$2"
  local expected_command="$3"
  local signal_name
  local attempt
  local current_state
  local was_stopped

  for signal_name in TERM KILL; do
    if ! process_matches_expected "$pid" "$identity" "$expected_command"; then
      bounded_reap_exact_child "$pid" "$identity" "$expected_command"
      return $?
    fi
    current_state="$(process_state "$pid" || true)"
    if [[ "$current_state" == Z* ]]; then
      bounded_reap_exact_child "$pid" "$identity" "$expected_command"
      return $?
    fi
    was_stopped=0
    [[ "$current_state" == T* ]] && was_stopped=1
    kill -"$signal_name" "$pid" 2>/dev/null || true
    if [[ "$signal_name" == TERM && "$was_stopped" -eq 1 \
      && "$(process_state "$pid" || true)" != Z* ]] \
      && process_matches_expected "$pid" "$identity" "$expected_command"; then
      process_matches_expected "$pid" "$identity" "$expected_command" || return 1
      kill -CONT "$pid" 2>/dev/null || true
    fi
    for attempt in {1..20}; do
      if ! process_matches_expected "$pid" "$identity" "$expected_command"; then
        bounded_reap_exact_child "$pid" "$identity" "$expected_command"
        return $?
      fi
      current_state="$(process_state "$pid" || true)"
      if [[ "$current_state" == Z* ]]; then
        bounded_reap_exact_child "$pid" "$identity" "$expected_command"
        return $?
      fi
      sleep 0.05
    done
  done

  bounded_reap_exact_child "$pid" "$identity" "$expected_command"
}

refresh_launch_capture_command() {
  local current_identity
  local current_command

  current_identity="$(process_identity "$launch_capture_pid" || true)"
  [[ "$current_identity" == "$launch_capture_identity" ]] || return 1
  current_command="$(process_command "$launch_capture_pid" || true)"
  [[ -n "$current_command" ]] || return 1
  if [[ "$current_command" == "$launch_capture_command" ]]; then
    return 0
  fi
  if [[ "$current_command" == *"awk -v private_repo=$repo_root/"* \
    && "$current_command" == *"-v private_scratch=$scratch/"* ]]; then
    launch_capture_command="$current_command"
    return 0
  fi
  return 1
}

reset_planner_state() {
  planner_pid=''
  planner_identity=''
  planner_fallback_identity=''
  planner_fallback_job_owned=0
  planner_fallback_group=''
  planner_fallback_known_gone=0
  planner_guardian_pid=''
  planner_guardian_identity=''
  planner_guardian_command=''
  planner_guardian_known_gone=0
  planner_guardian_handshake_verified=0
  planner_guardian_status=''
  planner_guardian_control=''
}

read_planner_guardian_status() {
  local raw
  local -a fields

  planner_guardian_status_kind=''
  planner_guardian_reported_pid=''
  planner_guardian_reported_app_pid=''
  [[ -n "$planner_guardian_status" && -f "$planner_guardian_status" ]] || return 1
  raw="$(< "$planner_guardian_status")"
  fields=("${(@s/:/)raw}")
  [[ "${#fields}" -eq 3 \
    && "${fields[1]}" == (ready|acknowledged|cleaned|exited|failed) \
    && "${fields[2]}" == <-> && "${fields[2]}" -gt 1 \
    && "${fields[3]}" == <-> && "${fields[3]}" -gt 1 ]] || return 1
  planner_guardian_status_kind="${fields[1]}"
  planner_guardian_reported_pid="${fields[2]}"
  planner_guardian_reported_app_pid="${fields[3]}"
}

write_planner_guardian_control() {
  local action="$1"

  [[ "$action" == (ack|terminate) \
    && "$planner_guardian_pid" == <-> && "$planner_guardian_pid" -gt 1 \
    && "$planner_pid" == <-> && "$planner_pid" -gt 1 ]] || return 1
  case "$planner_guardian_control" in
    "$scratch"/app-guardian-control) ;;
    *) return 1 ;;
  esac
  print -r -- "$action:$planner_guardian_pid:$planner_pid" > "$planner_guardian_control"
}

await_planner_guardian_ready() {
  local attempt

  for attempt in {1..40}; do
    if read_planner_guardian_status; then
      [[ "$planner_guardian_reported_pid" == "$planner_guardian_pid" ]] || return 1
      if [[ "$planner_guardian_status_kind" == ready ]]; then
        planner_pid="$planner_guardian_reported_app_pid"
        return 0
      fi
      [[ "$planner_guardian_status_kind" == failed || "$planner_guardian_status_kind" == exited ]] && return 1
    fi
    sleep 0.05
  done
  return 1
}

await_planner_guardian_status() {
  local expected_kind="$1"
  local attempt

  for attempt in {1..40}; do
    if read_planner_guardian_status; then
      [[ "$planner_guardian_reported_pid" == "$planner_guardian_pid" \
        && "$planner_guardian_reported_app_pid" == "$planner_pid" ]] || return 1
      [[ "$planner_guardian_status_kind" == "$expected_kind" ]] && return 0
      [[ "$planner_guardian_status_kind" == failed ]] && return 1
    fi
    sleep 0.05
  done
  return 1
}

planner_app_is_gone() {
  local current_identity
  local current_state

  [[ "$planner_pid" == <-> && "$planner_pid" -gt 1 ]] || return 1
  [[ "$planner_fallback_known_gone" -eq 1 ]] && return 0
  if [[ -z "$planner_identity" ]]; then
    kill -0 "$planner_pid" 2>/dev/null && return 1
    return 0
  fi
  current_identity="$(process_identity "$planner_pid" || true)"
  if [[ -z "$current_identity" ]]; then
    kill -0 "$planner_pid" 2>/dev/null && return 1
    return 0
  fi
  [[ "$current_identity" == "$planner_identity" && "$current_identity" == "$planner_guardian_pid|"* ]] || return 1
  [[ "$(process_command "$planner_pid" || true)" == "$binary" ]] || return 1
  current_state="$(process_state "$planner_pid" || true)"
  [[ "$current_state" == Z* ]]
}

terminate_guardian_owned_app() {
  local attempt
  local guardian_status

  [[ "$planner_guardian_pid" == <-> && "$planner_guardian_pid" -gt 1 \
    && "$planner_pid" == <-> && "$planner_pid" -gt 1 ]] || return 1
  if read_planner_guardian_status; then
    [[ "$planner_guardian_reported_pid" == "$planner_guardian_pid" \
      && "$planner_guardian_reported_app_pid" == "$planner_pid" \
      && "$planner_guardian_status_kind" == (ready|acknowledged) ]] || return 1
  else
    return 1
  fi
  write_planner_guardian_control terminate || return 1
  for attempt in {1..40}; do
    if read_planner_guardian_status; then
      [[ "$planner_guardian_reported_pid" == "$planner_guardian_pid" \
        && "$planner_guardian_reported_app_pid" == "$planner_pid" ]] || return 1
      guardian_status="$planner_guardian_status_kind"
      if [[ "$guardian_status" == cleaned || "$guardian_status" == exited ]]; then
        planner_app_is_gone || return 1
        if [[ -n "$planner_guardian_identity" && -n "$planner_guardian_command" ]]; then
          terminate_exact_owned_child \
            "$planner_guardian_pid" "$planner_guardian_identity" "$planner_guardian_command" || return 1
        else
          for attempt in {1..20}; do
            kill -0 "$planner_guardian_pid" 2>/dev/null || break
            sleep 0.05
          done
          kill -0 "$planner_guardian_pid" 2>/dev/null && return 1
        fi
        reset_planner_state
        return 0
      fi
      [[ "$guardian_status" == failed ]] && return 1
    fi
    sleep 0.05
  done
  return 1
}

terminate_owned_app() {
  local current_identity
  local current_state
  local signal_name
  local attempt

  [[ -n "$planner_guardian_pid" ]] && {
    terminate_guardian_owned_app
    return $?
  }
  [[ -n "$planner_pid" ]] || return 0
  if [[ "$planner_pid" != <-> || "$planner_pid" -le 1 || -z "$planner_identity" ]]; then
    terminate_fallback_owned_child \
      "$planner_pid" "$planner_fallback_identity" "$planner_fallback_job_owned" \
      "$planner_fallback_known_gone" "$planner_fallback_group" || return 1
    reset_planner_state
    return 0
  fi

  current_identity="$(process_identity "$planner_pid" || true)"
  if process_matches_expected "$planner_pid" "$planner_identity" "$binary"; then
    current_state="$(process_state "$planner_pid" || true)"
    if [[ "$current_state" != Z* ]]; then
      for signal_name in TERM KILL; do
        process_matches_expected "$planner_pid" "$planner_identity" "$binary" || break

        current_state="$(process_state "$planner_pid" || true)"
        [[ "$current_state" == Z* ]] && break
        kill -"$signal_name" "$planner_pid" 2>/dev/null || true

        for attempt in {1..20}; do
          process_matches_expected "$planner_pid" "$planner_identity" "$binary" || break
          current_state="$(process_state "$planner_pid" || true)"
          [[ "$current_state" == Z* ]] && break
          sleep 0.05
        done
      done
    fi
  fi

  current_identity="$(process_identity "$planner_pid" || true)"
  if process_matches_expected "$planner_pid" "$planner_identity" "$binary"; then
    current_state="$(process_state "$planner_pid" || true)"
    if [[ "$current_state" != Z* ]]; then
      return 1
    fi
  fi

  bounded_reap_exact_child "$planner_pid" "$planner_identity" "$binary" || return 1
  reset_planner_state
}

finish_launch_capture() {
  local current_identity
  local current_state
  local signal_name
  local attempt

  close_launch_capture_keepalive
  [[ -n "$launch_capture_pid" ]] || return 0
  if [[ "$launch_capture_pid" != <-> || "$launch_capture_pid" -le 1 \
    || -z "$launch_capture_identity" || -z "$launch_capture_command" ]]; then
    terminate_fallback_owned_child \
      "$launch_capture_pid" "$launch_capture_fallback_identity" "$launch_capture_fallback_job_owned" \
      "$launch_capture_fallback_known_gone" "$launch_capture_fallback_group" || return 1
    launch_capture_pid=''
    launch_capture_identity=''
    launch_capture_command=''
    launch_capture_fallback_identity=''
    launch_capture_fallback_job_owned=0
    launch_capture_fallback_group=''
    launch_capture_fallback_known_gone=0
    return 0
  fi
  current_identity="$(process_identity "$launch_capture_pid" || true)"
  if [[ "$current_identity" == "$launch_capture_identity" ]]; then
    refresh_launch_capture_command || return 1
  fi
  for attempt in {1..20}; do
    process_matches_expected "$launch_capture_pid" "$launch_capture_identity" "$launch_capture_command" || break
    current_state="$(process_state "$launch_capture_pid" || true)"
    [[ "$current_state" == Z* ]] && break
    sleep 0.05
  done

  current_identity="$(process_identity "$launch_capture_pid" || true)"
  if process_matches_expected "$launch_capture_pid" "$launch_capture_identity" "$launch_capture_command"; then
    current_state="$(process_state "$launch_capture_pid" || true)"
    if [[ "$current_state" != Z* ]]; then
      for signal_name in TERM KILL; do
        process_matches_expected "$launch_capture_pid" "$launch_capture_identity" "$launch_capture_command" || break
        current_state="$(process_state "$launch_capture_pid" || true)"
        [[ "$current_state" == Z* ]] && break
        kill -"$signal_name" "$launch_capture_pid" 2>/dev/null || true
        sleep 0.05
      done
    fi
  fi

  current_identity="$(process_identity "$launch_capture_pid" || true)"
  if process_matches_expected "$launch_capture_pid" "$launch_capture_identity" "$launch_capture_command"; then
    current_state="$(process_state "$launch_capture_pid" || true)"
    [[ "$current_state" == Z* ]] || return 1
  fi
  bounded_reap_exact_child \
    "$launch_capture_pid" "$launch_capture_identity" "$launch_capture_command" || return 1
  launch_capture_pid=''
  launch_capture_identity=''
  launch_capture_command=''
  launch_capture_fallback_identity=''
  launch_capture_fallback_job_owned=0
  launch_capture_fallback_group=''
  launch_capture_fallback_known_gone=0
}

reset_active_command_state() {
  active_command_pid=''
  active_command_identity=''
  active_command_command=''
  active_command_group=''
  active_command_fallback_identity=''
  active_command_fallback_command=''
  active_command_fallback_job_owned=0
  active_command_fallback_group=''
  active_command_fallback_known_gone=0
  active_command_wait_status=0
  active_command_descendant_pids=()
  active_command_descendant_births=()
  active_command_descendant_commands=()
  active_command_descendant_parents=()
  active_command_descendant_depths=()
  active_command_descendant_provenance=()
}

reset_active_capture_state() {
  active_capture_pid=''
  active_capture_identity=''
  active_capture_command=''
  active_capture_fallback_identity=''
  active_capture_fallback_job_owned=0
  active_capture_fallback_group=''
  active_capture_fallback_known_gone=0
  active_capture_keepalive_fd=''
}

close_active_capture_keepalive() {
  if [[ -n "$active_capture_keepalive_fd" ]]; then
    exec {active_capture_keepalive_fd}>&-
    active_capture_keepalive_fd=''
  fi
}

close_launch_capture_keepalive() {
  if [[ -n "$launch_capture_keepalive_fd" ]]; then
    exec {launch_capture_keepalive_fd}>&-
    launch_capture_keepalive_fd=''
  fi
}

command_has_active_scratch_provenance() {
  local command="$1"

  [[ -n "$scratch" && "$command" == *"$scratch/"* ]]
}

active_command_leader_status() {
  local current_identity
  local current_command
  local current_group
  local current_state

  [[ "$active_command_pid" == <-> && "$active_command_pid" -gt 1 ]] || return 1
  if [[ -z "$active_command_identity" && -n "$active_command_fallback_identity" \
    && -n "$active_command_fallback_command" ]]; then
    active_command_identity="$active_command_fallback_identity"
    active_command_command="$active_command_fallback_command"
  fi
  if [[ -z "$active_command_group" && -n "$active_command_fallback_group" ]]; then
    active_command_group="$active_command_fallback_group"
  fi
  if [[ "$active_command_fallback_known_gone" -eq 1 ]]; then
    return 2
  fi
  [[ -n "$active_command_identity" && -n "$active_command_command" ]] || return 1

  current_identity="$(process_identity "$active_command_pid" || true)"
  if [[ -z "$current_identity" ]]; then
    kill -0 "$active_command_pid" 2>/dev/null && return 1
    return 2
  fi
  [[ "$current_identity" == "$active_command_identity" ]] || return 1
  current_state="$(process_state "$active_command_pid" || true)"
  [[ "$current_state" == Z* ]] && return 2
  current_group="$(process_group "$active_command_pid" || true)"
  [[ -z "$active_command_group" || "$current_group" == "$active_command_group" ]] || return 1
  current_command="$(process_command "$active_command_pid" || true)"
  [[ -n "$current_command" ]] || return 1
  active_command_command="$current_command"
  return 0
}

active_command_descendant_status() {
  local pid="$1"
  local expected_birth="${active_command_descendant_births[$pid]-}"
  local expected_command="${active_command_descendant_commands[$pid]-}"
  local current_birth
  local current_command
  local current_state

  [[ "$pid" == <-> && "$pid" -gt 1 && -n "$expected_birth" && -n "$expected_command" ]] || return 1
  current_birth="$(process_birth "$pid" || true)"
  if [[ -z "$current_birth" ]]; then
    kill -0 "$pid" 2>/dev/null && return 1
    return 2
  fi
  [[ "$current_birth" == "$expected_birth" ]] || return 2
  current_state="$(process_state "$pid" || true)"
  [[ "$current_state" == Z* ]] && return 2
  current_command="$(process_command "$pid" || true)"
  [[ "$current_command" == "$expected_command" ]] || return 1
  return 0
}

active_command_parent_depth() {
  local pid="$1"
  local descendant_status

  active_command_parent_depth_value=''
  if [[ "$pid" == "$active_command_pid" ]]; then
    active_command_leader_status
    [[ "$?" -eq 0 ]] || return 1
    active_command_parent_depth_value=0
    return 0
  fi
  [[ -n "${active_command_descendant_births[$pid]-}" ]] || return 1
  active_command_descendant_status "$pid"
  descendant_status=$?
  [[ "$descendant_status" -eq 0 ]] || return 1
  active_command_parent_depth_value="${active_command_descendant_depths[$pid]}"
}

record_active_command_descendant() {
  local pid="$1"
  local expected_parent="$2"
  local depth="$3"
  local attempt
  local birth
  local command
  local parent
  local state
  local second_birth
  local second_command
  local second_parent

  active_command_descendant_was_new=0
  [[ "$pid" == <-> && "$pid" -gt 1 && "$expected_parent" == <-> \
    && "$expected_parent" -gt 1 && "$depth" == <-> && "$depth" -gt 0 ]] || return 1
  for attempt in {1..4}; do
    birth="$(process_birth "$pid" || true)"
    command="$(process_command "$pid" || true)"
    parent="$(process_parent "$pid" || true)"
    state="$(process_state "$pid" || true)"
    if [[ -z "$birth" ]]; then
      kill -0 "$pid" 2>/dev/null || return 2
      sleep 0.02
      continue
    fi
    [[ "$parent" == "$expected_parent" ]] || return 2
    [[ "$state" != Z* ]] || return 2
    if [[ -z "$command" ]]; then
      sleep 0.02
      continue
    fi
    second_birth="$(process_birth "$pid" || true)"
    second_command="$(process_command "$pid" || true)"
    second_parent="$(process_parent "$pid" || true)"
    [[ "$second_birth" == "$birth" && "$second_command" == "$command" \
      && "$second_parent" == "$expected_parent" ]] || {
        sleep 0.02
        continue
      }

    if [[ -n "${active_command_descendant_births[$pid]-}" ]]; then
      [[ "${active_command_descendant_births[$pid]}" == "$birth" ]] || return 1
    else
      active_command_descendant_pids+=("$pid")
      active_command_descendant_was_new=1
    fi
    active_command_descendant_births[$pid]="$birth"
    active_command_descendant_commands[$pid]="$command"
    active_command_descendant_parents[$pid]="$expected_parent"
    active_command_descendant_depths[$pid]="$depth"
    if command_has_active_scratch_provenance "$command"; then
      active_command_descendant_provenance[$pid]=1
    else
      active_command_descendant_provenance[$pid]=0
    fi
    return 0
  done
  return 1
}

refresh_active_command_descendant_ledger() {
  local discovery_pass
  local line
  local child_pid
  local parent_pid
  local parent_depth
  local record_status
  local new_count
  local process_pairs
  local -a fields
  local -A live_parent_depths

  active_command_leader_status
  record_status=$?
  case "$record_status" in
    0) ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
  for discovery_pass in {1..24}; do
    live_parent_depths=()
    live_parent_depths[$active_command_pid]=0
    for parent_pid in "${active_command_descendant_pids[@]}"; do
      active_command_descendant_status "$parent_pid"
      [[ "$?" -eq 0 ]] || continue
      live_parent_depths[$parent_pid]="${active_command_descendant_depths[$parent_pid]}"
    done
    process_pairs="$(ps -ax -o pid=,ppid= 2>/dev/null)" || return 1
    new_count=0
    while IFS= read -r line; do
      fields=(${=line})
      [[ "${#fields}" -eq 2 ]] || continue
      child_pid="${fields[1]}"
      parent_pid="${fields[2]}"
      [[ -n "${live_parent_depths[$parent_pid]-}" ]] || continue
      [[ "$child_pid" != "$active_command_pid" ]] || continue
      parent_depth="${live_parent_depths[$parent_pid]}"
      record_active_command_descendant "$child_pid" "$parent_pid" "$((parent_depth + 1))"
      record_status=$?
      case "$record_status" in
        0) new_count=$((new_count + active_command_descendant_was_new)) ;;
        2) ;;
        *) return 1 ;;
      esac
    done <<< "$process_pairs"
    [[ "$new_count" -eq 0 ]] && return 0
  done
  return 1
}

stop_exact_active_command_descendant() {
  local pid="$1"
  local descendant_status
  local current_state

  active_command_descendant_status "$pid"
  descendant_status=$?
  case "$descendant_status" in
    2) return 0 ;;
    0) ;;
    *) return 1 ;;
  esac
  current_state="$(process_state "$pid" || true)"
  [[ "$current_state" == T* ]] && return 0
  active_command_descendant_status "$pid" || return 1
  kill -STOP "$pid" 2>/dev/null || true
  active_command_descendant_status "$pid"
  descendant_status=$?
  [[ "$descendant_status" == (0|2) ]]
}

signal_active_command_descendants_at_depth() {
  local depth="$1"
  local signal_name="$2"
  local pid
  local descendant_status
  local current_state
  local was_stopped

  [[ "$depth" == <-> && "$depth" -gt 0 && "$signal_name" == (TERM|KILL) ]] || return 1
  for pid in "${active_command_descendant_pids[@]}"; do
    [[ "${active_command_descendant_depths[$pid]-0}" -eq "$depth" ]] || continue
    active_command_descendant_status "$pid"
    descendant_status=$?
    case "$descendant_status" in
      2) continue ;;
      0) ;;
      *) return 1 ;;
    esac
    current_state="$(process_state "$pid" || true)"
    was_stopped=0
    [[ "$current_state" == T* ]] && was_stopped=1
    active_command_descendant_status "$pid" || return 1
    kill -"$signal_name" "$pid" 2>/dev/null || true
    if [[ "$signal_name" == TERM && "$was_stopped" -eq 1 ]]; then
      active_command_descendant_status "$pid"
      descendant_status=$?
      case "$descendant_status" in
        2) ;;
        0)
          active_command_descendant_status "$pid" || return 1
          kill -CONT "$pid" 2>/dev/null || true
          ;;
        *) return 1 ;;
      esac
    fi
  done
}

active_command_descendants_at_depth_status() {
  local depth="$1"
  local pid
  local descendant_status
  local live_count=0

  for pid in "${active_command_descendant_pids[@]}"; do
    [[ "${active_command_descendant_depths[$pid]-0}" -eq "$depth" ]] || continue
    active_command_descendant_status "$pid"
    descendant_status=$?
    case "$descendant_status" in
      0) live_count=$((live_count + 1)) ;;
      2) ;;
      *) return 1 ;;
    esac
  done
  [[ "$live_count" -eq 0 ]] && return 2
  return 0
}

await_active_command_descendants_at_depth_gone() {
  local depth="$1"
  local attempt
  local depth_status

  for attempt in {1..20}; do
    active_command_descendants_at_depth_status "$depth"
    depth_status=$?
    case "$depth_status" in
      0) sleep 0.05 ;;
      2) return 0 ;;
      *) return 1 ;;
    esac
  done
  return 2
}

quiesce_active_command_tree() {
  local leader_identity
  local leader_command
  local leader_group
  local stable_passes=0
  local attempt
  local pid
  local line
  local child_pid
  local parent_pid
  local parent_depth
  local record_status
  local new_count
  local process_pairs
  local -a fields
  local -A live_parent_depths

  refresh_active_command_descendant_ledger || return 1
  active_command_leader_status
  [[ "$?" -eq 0 ]] || return 1
  leader_identity="$active_command_identity"
  leader_command="$active_command_command"
  leader_group="$(process_group "$active_command_pid" || true)"
  [[ -z "$active_command_group" || "$leader_group" == "$active_command_group" ]] || return 1
  process_matches_expected "$active_command_pid" "$leader_identity" "$leader_command" || return 1
  kill -STOP "$active_command_pid" 2>/dev/null || true
  process_matches_expected "$active_command_pid" "$leader_identity" "$leader_command" || return 1

  for pid in "${active_command_descendant_pids[@]}"; do
    active_command_descendant_status "$pid"
    case "$?" in
      0)
        if [[ "${active_command_descendant_provenance[$pid]-0}" -ne 1 ]]; then
          parent_pid="$(process_parent "$pid" || true)"
          active_command_parent_depth "$parent_pid" || return 1
        fi
        stop_exact_active_command_descendant "$pid" || return 1
        ;;
      2) ;;
      *) return 1 ;;
    esac
  done

  for attempt in {1..40}; do
    live_parent_depths=()
    live_parent_depths[$active_command_pid]=0
    for pid in "${active_command_descendant_pids[@]}"; do
      active_command_descendant_status "$pid"
      [[ "$?" -eq 0 ]] || continue
      live_parent_depths[$pid]="${active_command_descendant_depths[$pid]}"
    done
    process_pairs="$(ps -ax -o pid=,ppid= 2>/dev/null)" || return 1
    new_count=0
    while IFS= read -r line; do
      fields=(${=line})
      [[ "${#fields}" -eq 2 ]] || continue
      child_pid="${fields[1]}"
      parent_pid="${fields[2]}"
      [[ -n "${live_parent_depths[$parent_pid]-}" ]] || continue
      [[ "$child_pid" != "$active_command_pid" ]] || continue
      parent_depth="${live_parent_depths[$parent_pid]}"
      if [[ -n "${active_command_descendant_births[$child_pid]-}" ]]; then
        active_command_descendant_status "$child_pid"
        record_status=$?
        case "$record_status" in
          0) stop_exact_active_command_descendant "$child_pid" || return 1 ;;
          2) ;;
          *)
            record_active_command_descendant "$child_pid" "$parent_pid" "$((parent_depth + 1))" || return 1
            stop_exact_active_command_descendant "$child_pid" || return 1
            ;;
        esac
      else
        record_active_command_descendant "$child_pid" "$parent_pid" "$((parent_depth + 1))"
        record_status=$?
        case "$record_status" in
          0)
            new_count=$((new_count + active_command_descendant_was_new))
            stop_exact_active_command_descendant "$child_pid" || return 1
            ;;
          2) ;;
          *) return 1 ;;
        esac
      fi
    done <<< "$process_pairs"
    if [[ "$new_count" -eq 0 ]]; then
      stable_passes=$((stable_passes + 1))
      [[ "$stable_passes" -ge 3 ]] && return 0
    else
      stable_passes=0
    fi
    sleep 0.05
  done
  return 1
}

terminate_exact_active_command_descendant() {
  local pid="$1"
  local signal_name
  local attempt
  local descendant_status

  for signal_name in TERM KILL; do
    active_command_descendant_status "$pid"
    descendant_status=$?
    case "$descendant_status" in
      2) return 0 ;;
      0) ;;
      *) return 1 ;;
    esac
    active_command_descendant_status "$pid" || return 1
    kill -"$signal_name" "$pid" 2>/dev/null || true
    for attempt in {1..20}; do
      active_command_descendant_status "$pid"
      descendant_status=$?
      case "$descendant_status" in
        0) sleep 0.05 ;;
        2) return 0 ;;
        *) return 1 ;;
      esac
    done
  done
  active_command_descendant_status "$pid"
  [[ "$?" -eq 2 ]]
}

terminate_recorded_active_command_descendants() {
  local pid
  local depth
  local max_depth=0
  local depth_status

  for pid in "${active_command_descendant_pids[@]}"; do
    depth="${active_command_descendant_depths[$pid]-0}"
    (( depth > max_depth )) && max_depth="$depth"
  done
  for (( depth = max_depth; depth >= 1; depth -= 1 )); do
    for pid in "${active_command_descendant_pids[@]}"; do
      [[ "${active_command_descendant_depths[$pid]-0}" -eq "$depth" ]] || continue
      active_command_descendant_status "$pid"
      depth_status=$?
      case "$depth_status" in
        2) ;;
        0)
          [[ "${active_command_tree_was_live:-0}" -eq 1 \
            || "${active_command_descendant_provenance[$pid]-0}" -eq 1 ]] || return 1
          ;;
        *) return 1 ;;
      esac
    done
    signal_active_command_descendants_at_depth "$depth" TERM || return 1
    await_active_command_descendants_at_depth_gone "$depth"
    depth_status=$?
    case "$depth_status" in
      0) ;;
      2)
        signal_active_command_descendants_at_depth "$depth" KILL || return 1
        await_active_command_descendants_at_depth_gone "$depth" || return 1
        ;;
      *) return 1 ;;
    esac
  done
}

await_recorded_active_command_descendants_absent() {
  local attempt
  local pid
  local remaining
  local current_birth

  for attempt in {1..20}; do
    remaining=0
    for pid in "${active_command_descendant_pids[@]}"; do
      current_birth="$(process_birth "$pid" || true)"
      [[ -n "$current_birth" && "$current_birth" == "${active_command_descendant_births[$pid]-}" ]] \
        && remaining=$((remaining + 1))
    done
    [[ "$remaining" -eq 0 ]] && return 0
    sleep 0.05
  done
  return 1
}

wait_for_active_command() {
  local current_identity
  local current_state
  local tracking_status
  local wait_status

  active_command_wait_status=0
  while true; do
    current_identity="$(process_identity "$active_command_pid" || true)"
    if [[ -z "$current_identity" ]]; then
      kill -0 "$active_command_pid" 2>/dev/null && return 1
      break
    fi
    [[ -n "$active_command_identity" && "$current_identity" == "$active_command_identity" ]] || return 1
    current_state="$(process_state "$active_command_pid" || true)"
    [[ "$current_state" == Z* ]] && break
    active_command_leader_status
    tracking_status=$?
    case "$tracking_status" in
      0) ;;
      2) break ;;
      *)
        current_identity="$(process_identity "$active_command_pid" || true)"
        if [[ -z "$current_identity" ]] && ! kill -0 "$active_command_pid" 2>/dev/null; then
          break
        fi
        return 1
        ;;
    esac
    refresh_active_command_descendant_ledger
    tracking_status=$?
    case "$tracking_status" in
      0) ;;
      2) break ;;
      *) return 1 ;;
    esac
    sleep 0.05
  done
  wait "$active_command_pid"
  wait_status=$?
  active_command_wait_status="$wait_status"
  return 0
}

establish_active_command_group() {
  local attempt
  local current_identity
  local current_command
  local current_group

  for attempt in {1..20}; do
    current_identity="$(process_identity "$active_command_pid" || true)"
    current_command="$(process_command "$active_command_pid" || true)"
    current_group="$(process_group "$active_command_pid" || true)"
    if [[ "$current_identity" == "$$|"* && -n "$current_command" \
      && "$current_group" == "$active_command_pid" ]]; then
      active_command_identity="$current_identity"
      active_command_command="$current_command"
      active_command_group="$current_group"
      return 0
    fi
    if [[ -z "$current_identity" ]]; then
      # A just-started child can briefly be absent from ps.  Treat it as
      # completed only after the kernel also says that its PID is gone.
      if kill -0 "$active_command_pid" 2>/dev/null; then
        sleep 0.05
        continue
      fi
      return 2
    fi
    sleep 0.05
  done
  return 1
}

active_command_group_status() {
  local current_identity
  local current_command
  local current_group
  local current_state
  local members

  if [[ "$active_command_pid" != <-> || "$active_command_pid" -le 1 \
    || "$active_command_group" != <-> || "$active_command_group" -le 1 ]]; then
    return 1
  fi

  current_identity="$(process_identity "$active_command_pid" || true)"
  if [[ -n "$active_command_identity" && -n "$active_command_command" && -n "$current_identity" ]]; then
    [[ "$current_identity" == "$active_command_identity" ]] || return 1
    current_group="$(process_group "$active_command_pid" || true)"
    [[ "$current_group" == "$active_command_group" ]] || return 1
    current_state="$(process_state "$active_command_pid" || true)"
    if [[ "$current_state" != Z* ]]; then
      current_command="$(process_command "$active_command_pid" || true)"
      [[ -n "$current_command" ]] || return 1
      active_command_command="$current_command"
    fi
  elif [[ -n "$active_command_identity" && -n "$active_command_command" ]]; then
    # The exact leader may already be gone while its private-group
    # descendants still need bounded cleanup below.
    kill -0 "$active_command_pid" 2>/dev/null && return 1
  else
    fallback_child_status \
      "$active_command_pid" "$active_command_fallback_identity" "$active_command_fallback_job_owned" \
      "$active_command_fallback_known_gone" "$active_command_fallback_group"
    case "$?" in
      0)
        current_group="$(process_group "$active_command_pid" || true)"
        [[ "$current_group" == "$active_command_group" ]] || return 1
        ;;
      2) ;;
      *) return 1 ;;
    esac
  fi

  members="$(ps -ax -o pid=,pgid=,stat= 2>/dev/null \
    | awk -v group="$active_command_group" '$2 == group && $3 !~ /^Z/ { print $1 }')" || return 1
  [[ -n "$members" ]] || return 2
  return 0
}

terminate_active_command_group() {
  local leader_status

  [[ -n "$active_command_pid" ]] || return 0
  active_command_tree_was_live=0
  active_command_leader_status
  leader_status=$?
  case "$leader_status" in
    0)
      active_command_tree_was_live=1
      quiesce_active_command_tree || return 1
      ;;
    2) ;;
    *) return 1 ;;
  esac

  terminate_recorded_active_command_descendants || return 1
  if [[ "$active_command_tree_was_live" -eq 1 ]]; then
    process_matches_expected \
      "$active_command_pid" "$active_command_identity" "$active_command_command" || return 1
    terminate_exact_owned_child \
      "$active_command_pid" "$active_command_identity" "$active_command_command" || return 1
  fi
  await_recorded_active_command_descendants_absent
}

reap_active_command() {
  [[ -n "$active_command_pid" ]] || return 0
  if [[ "$active_command_pid" != <-> || "$active_command_pid" -le 1 ]]; then
    return 1
  fi
  if [[ -n "$active_command_identity" && -n "$active_command_command" ]]; then
    bounded_reap_exact_child \
      "$active_command_pid" "$active_command_identity" "$active_command_command" || return 1
  else
    bounded_reap_fallback_child \
      "$active_command_pid" "$active_command_fallback_identity" "$active_command_fallback_job_owned" \
      "$active_command_fallback_known_gone" "$active_command_fallback_group" || return 1
  fi
  await_recorded_active_command_descendants_absent || return 1
  reset_active_command_state
}

refresh_active_capture_command() {
  local current_identity
  local current_command

  current_identity="$(process_identity "$active_capture_pid" || true)"
  [[ "$current_identity" == "$active_capture_identity" ]] || return 1
  current_command="$(process_command "$active_capture_pid" || true)"
  [[ -n "$current_command" ]] || return 1
  if [[ "$current_command" == "$active_capture_command" ]]; then
    return 0
  fi
  if [[ "$current_command" == *"awk -v private_repo=$repo_root/"* \
    && "$current_command" == *"-v private_scratch=$scratch/"* ]]; then
    active_capture_command="$current_command"
    return 0
  fi
  return 1
}

finish_active_capture() {
  local current_identity
  local current_state
  local signal_name
  local attempt
  local capture_status

  close_active_capture_keepalive
  [[ -n "$active_capture_pid" ]] || return 0
  if [[ "$active_capture_pid" != <-> || "$active_capture_pid" -le 1 \
    || -z "$active_capture_identity" || -z "$active_capture_command" ]]; then
    terminate_fallback_owned_child \
      "$active_capture_pid" "$active_capture_fallback_identity" "$active_capture_fallback_job_owned" \
      "$active_capture_fallback_known_gone" "$active_capture_fallback_group" || return 1
    reset_active_capture_state
    return 0
  fi

  current_identity="$(process_identity "$active_capture_pid" || true)"
  if [[ "$current_identity" == "$active_capture_identity" ]]; then
    refresh_active_capture_command || return 1
  fi

  for attempt in {1..20}; do
    process_matches_expected "$active_capture_pid" "$active_capture_identity" "$active_capture_command" || break
    current_state="$(process_state "$active_capture_pid" || true)"
    [[ "$current_state" == Z* ]] && break
    sleep 0.05
  done

  current_identity="$(process_identity "$active_capture_pid" || true)"
  if process_matches_expected "$active_capture_pid" "$active_capture_identity" "$active_capture_command"; then
    current_state="$(process_state "$active_capture_pid" || true)"
    if [[ "$current_state" != Z* ]]; then
      for signal_name in TERM KILL; do
        process_matches_expected "$active_capture_pid" "$active_capture_identity" "$active_capture_command" || break
        current_state="$(process_state "$active_capture_pid" || true)"
        [[ "$current_state" == Z* ]] && break
        kill -"$signal_name" "$active_capture_pid" 2>/dev/null || true
        sleep 0.05
      done
    fi
  fi

  current_identity="$(process_identity "$active_capture_pid" || true)"
  if process_matches_expected "$active_capture_pid" "$active_capture_identity" "$active_capture_command"; then
    current_state="$(process_state "$active_capture_pid" || true)"
    [[ "$current_state" == Z* ]] || return 1
  fi
  bounded_reap_exact_child \
    "$active_capture_pid" "$active_capture_identity" "$active_capture_command"
  capture_status=$?
  reset_active_capture_state
  return "$capture_status"
}

scratch_owned_processes_absent() {
  local attempt
  local pid
  local current_command
  local current_state
  local found
  local process_ids

  for attempt in {1..20}; do
    found=0
    process_ids="$(ps -ax -o pid= 2>/dev/null)" || return 1
    while IFS= read -r pid; do
      pid="${pid//[[:space:]]/}"
      [[ "$pid" == <-> && "$pid" -gt 1 && "$pid" != "$$" ]] || continue
      current_state="$(process_state "$pid" || true)"
      [[ -n "$current_state" && "$current_state" != Z* ]] || continue
      current_command="$(process_command "$pid" || true)"
      if command_has_active_scratch_provenance "$current_command"; then
        found=1
        break
      fi
    done <<< "$process_ids"
    [[ "$found" -eq 0 ]] && return 0
    sleep 0.05
  done
  return 1
}

remove_exact_scratch_after_quiet_window() {
  local removal_attempt
  local quiet_check
  local recreated

  case "$scratch" in
    "$tmp_base"/daily-planner-m2a-verify.*) ;;
    *) return 1 ;;
  esac

  for removal_attempt in {1..3}; do
    [[ ! -d "$scratch" ]] || rm -rf -- "$scratch" >/dev/null 2>&1 || true
    recreated=0
    for quiet_check in {1..20}; do
      sleep 0.05
      if [[ -e "$scratch" ]]; then
        recreated=1
        break
      fi
    done
    [[ "$recreated" -eq 1 ]] || return 0
  done
  return 1
}

cleanup() {
  local exit_status=$?
  local cleanup_failed=0
  local preserve_scratch=0

  trap - EXIT HUP INT TERM
  close_active_capture_keepalive
  close_launch_capture_keepalive
  if ! terminate_active_command_group; then
    print -u2 -r -- 'M2A verifier could not terminate its exact owned active command group'
    cleanup_failed=1
    [[ -n "$active_command_pid" ]] && preserve_scratch=1
  elif ! reap_active_command; then
    print -u2 -r -- 'M2A verifier could not reap its exact owned active command leader'
    cleanup_failed=1
    [[ -n "$active_command_pid" ]] && preserve_scratch=1
  fi
  if ! finish_active_capture; then
    print -u2 -r -- 'M2A verifier could not terminate and reap its exact owned active output capture process'
    cleanup_failed=1
    [[ -n "$active_capture_pid" ]] && preserve_scratch=1
  fi
  if ! terminate_owned_app; then
    print -u2 -r -- 'M2A verifier could not terminate and reap its exact owned app process'
    cleanup_failed=1
    [[ -n "$planner_pid" ]] && preserve_scratch=1
  fi
  if ! finish_launch_capture; then
    print -u2 -r -- 'M2A verifier could not terminate and reap its exact owned output capture process'
    cleanup_failed=1
    [[ -n "$launch_capture_pid" ]] && preserve_scratch=1
  fi

  if ! scratch_owned_processes_absent; then
    print -u2 -r -- 'M2A verifier found an owned scratch process after bounded cleanup'
    cleanup_failed=1
    preserve_scratch=1
  fi

  if [[ "$preserve_scratch" -eq 1 ]]; then
    print -u2 -r -- 'M2A verifier retained its scratch root because owned cleanup could not be proven complete'
    cleanup_failed=1
  elif ! remove_exact_scratch_after_quiet_window; then
    print -u2 -r -- 'M2A verifier could not remove its exact scratch root'
    cleanup_failed=1
  fi

  if [[ "$cleanup_failed" -ne 0 ]]; then
    exit_status=1
  elif [[ "$exit_status" -eq 0 && "$verifier_completed" -eq 1 ]]; then
    print -r -- 'M2A verifier passed: 207-test suite, signed lifecycle, four inverse canaries, evidence scan, worktree preservation, exact PID cleanup, and scratch cleanup'
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'request_interruption 129' HUP
trap 'request_interruption 130' INT
trap 'request_interruption 143' TERM

evidence_root="$scratch/evidence"
state_root="$evidence_root/worktree-state"
mkdir -p "$evidence_root" "$state_root"

sanitizer_command=(
  awk
  -v "private_repo=$repo_root/"
  -v "private_scratch=$scratch/"
  '
    function replace_fixed(value, needle, replacement, position) {
      while ((position = index(value, needle)) != 0) {
        value = substr(value, 1, position - 1) replacement substr(value, position + length(needle))
      }
      return value
    }
    {
      line = replace_fixed($0, private_repo, "")
      line = replace_fixed(line, private_scratch, "verifier-scratch/")
      print line
    }
  '
)

run_with_evidence() {
  local output_file="$1"
  local relative_output="${output_file#$evidence_root/}"
  local output_pipe
  local command_status
  local capture_status
  local capture_registration_status
  local command_registration_status
  local group_status
  shift

  setopt localoptions noerrexit
  ((active_run_sequence += 1))
  output_pipe="$scratch/command-output-$active_run_sequence.pipe"
  mkfifo "$output_pipe"
  exec {active_capture_keepalive_fd}<>"$output_pipe"

  begin_interruption_deferral
  (
    exec {active_capture_keepalive_fd}>&-
    exec perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' -- \
      "${sanitizer_command[@]}" "$output_pipe" > "$output_file"
  ) &
  active_capture_pid=$!
  record_owned_child "$active_capture_pid" 1
  capture_registration_status=$?
  active_capture_fallback_identity="$recorded_child_fallback_identity"
  active_capture_fallback_job_owned="$recorded_child_fallback_job_owned"
  active_capture_fallback_group="$recorded_child_fallback_group"
  active_capture_fallback_known_gone="$recorded_child_fallback_known_gone"
  if [[ "$capture_registration_status" -eq 0 ]]; then
    active_capture_identity="$recorded_child_identity"
    active_capture_command="$recorded_child_command"
  fi
  end_interruption_deferral
  if [[ "$capture_registration_status" -ne 0 ]]; then
    print -u2 -r -- "M2A verifier could not establish its exact owned command output capture process; evidence: $relative_output"
    return 1
  fi

  begin_interruption_deferral
  (
    exec {active_capture_keepalive_fd}>&-
    exec perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' -- "$@" > "$output_pipe" 2>&1
  ) &
  active_command_pid=$!
  record_owned_child "$active_command_pid" 1
  command_registration_status=$?
  active_command_fallback_identity="$recorded_child_fallback_identity"
  active_command_fallback_command="$recorded_child_fallback_command"
  active_command_fallback_job_owned="$recorded_child_fallback_job_owned"
  active_command_fallback_group="$recorded_child_fallback_group"
  active_command_fallback_known_gone="$recorded_child_fallback_known_gone"
  if [[ "$command_registration_status" -eq 0 ]]; then
    active_command_identity="$recorded_child_identity"
    active_command_command="$recorded_child_command"
    establish_active_command_group
    group_status=$?
  else
    group_status="$command_registration_status"
  fi
  if [[ -z "$active_command_group" && -n "$active_command_fallback_group" ]]; then
    active_command_group="$active_command_fallback_group"
  fi
  end_interruption_deferral
  if [[ "$command_registration_status" -eq 1 ]]; then
    print -u2 -r -- "M2A verifier could not establish its exact owned active command leader; evidence: $relative_output"
    return 1
  fi
  if [[ "$group_status" -eq 1 ]]; then
    print -u2 -r -- "M2A verifier could not establish its exact owned active command group; evidence: $relative_output"
    return 1
  fi

  if ! wait_for_active_command; then
    print -u2 -r -- "M2A verifier could not track its exact owned active command tree; evidence: $relative_output"
    return 1
  fi
  command_status="$active_command_wait_status"
  if ! terminate_active_command_group; then
    print -u2 -r -- "M2A verifier could not terminate its exact owned active command tree; evidence: $relative_output"
    return 1
  fi
  reset_active_command_state
  finish_active_capture
  capture_status=$?
  if [[ "$capture_status" -ne 0 ]]; then
    print -u2 -r -- "M2A evidence sanitization failed; evidence: $relative_output"
    return 1
  fi
  if [[ "$command_status" -ne 0 ]]; then
    print -u2 -r -- "M2A verification command failed; evidence: $relative_output"
    return "$command_status"
  fi
}

hash_untracked_state() {
  local relative_path
  local absolute

  git -C "$repo_root" ls-files --others --exclude-standard -z \
    | while IFS= read -r -d '' relative_path; do
        absolute="$repo_root/$relative_path"
        print -rn -- "$relative_path"
        print -rn -- $'\0'
        if [[ -L "$absolute" ]]; then
          print -rn -- 'symlink'
          print -rn -- $'\0'
          readlink "$absolute" | shasum -a 256
        elif [[ -f "$absolute" ]]; then
          print -rn -- 'file'
          print -rn -- $'\0'
          stat -f '%Lp:%z' "$absolute"
          shasum -a 256 < "$absolute"
        else
          print -rn -- 'other'
          print -rn -- $'\0'
          stat -f '%HT:%Lp:%z' "$absolute"
        fi
      done \
    | shasum -a 256
}

capture_worktree_state() {
  local label="$1"

  git -C "$repo_root" status --porcelain=v1 -z --untracked-files=all \
    | shasum -a 256 > "$state_root/worktree-$label-status.sha256"
  git -C "$repo_root" diff --binary --no-ext-diff \
    | shasum -a 256 > "$state_root/worktree-$label-unstaged.sha256"
  git -C "$repo_root" diff --cached --binary --no-ext-diff \
    | shasum -a 256 > "$state_root/worktree-$label-staged.sha256"
  hash_untracked_state > "$state_root/worktree-$label-untracked.sha256"
}

is_known_hygiene_class() {
  case "$1" in
    'network capability outside DailyPlannerGoogle' \
      |'AppKit browser opening outside MacSystemBrowser.swift' \
      |'provider write scope' \
      |'Gmail write route' \
      |'Calendar or Tasks mutation capability' \
      |'provider mutation method' \
      |'provider POST outside OAuth allowlist' \
      |'unexpected provider host' \
      |'Codex or process launch capability' \
      |'vault bookmark resolution' \
      |'vault bookmark creation outside MacVaultFolderPicker.swift' \
      |'content I/O outside encrypted private-settings storage' \
      |'notification capability' \
      |'timer, scheduler, or login capability' \
      |'dynamic logging capability' \
      |'external Swift package declaration') return 0 ;;
    *) return 1 ;;
  esac
}

report_hygiene_rejection() {
  local classification="$1"
  local source_root="$2"
  local files="$3"
  local file
  local relative

  if ! is_known_hygiene_class "$classification"; then
    print -u2 -r -- 'M2A hygiene reject: invalid rejection class'
    return 1
  fi
  print -u2 -r -- "M2A hygiene reject: $classification"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    case "$file" in
      "$source_root"/*) relative="${file#$source_root/}" ;;
      "$source_root") relative='Sources' ;;
      *) relative='unresolved-source-file' ;;
    esac
    print -u2 -r -- "  file: $relative"
  done <<< "$files"
  return 1
}

source_match_files() {
  local source_root="$1"
  local pattern="$2"
  local files
  local rg_status=0

  files="$(rg -l --glob '*.swift' -- "$pattern" "$source_root" 2>/dev/null)" || rg_status=$?
  if [[ "$rg_status" -gt 1 ]]; then
    print -u2 -r -- 'M2A hygiene reject: source scan failed'
    return 2
  fi
  print -r -- "$files"
}

source_match_values() {
  local source_file="$1"
  local pattern="$2"
  local values
  local rg_status=0

  values="$(rg -o -- "$pattern" "$source_file" 2>/dev/null)" || rg_status=$?
  if [[ "$rg_status" -gt 1 ]]; then
    print -u2 -r -- 'M2A hygiene reject: source scan failed'
    return 2
  fi
  print -r -- "$values"
}

source_match_lines() {
  local source_file="$1"
  local pattern="$2"
  local lines
  local rg_status=0

  lines="$(rg -N -- "$pattern" "$source_file" 2>/dev/null)" || rg_status=$?
  if [[ "$rg_status" -gt 1 ]]; then
    print -u2 -r -- 'M2A hygiene reject: source scan failed'
    return 2
  fi
  print -r -- "$lines"
}

reject_source_matches() {
  local classification="$1"
  local source_root="$2"
  local pattern="$3"
  local files

  files="$(source_match_files "$source_root" "$pattern")" || return 1
  [[ -z "$files" ]] || report_hygiene_rejection "$classification" "$source_root" "$files"
}

allow_source_matches_only_within() {
  local classification="$1"
  local source_root="$2"
  local pattern="$3"
  local allowed_root="$4"
  local files
  local file

  files="$(source_match_files "$source_root" "$pattern")" || return 1
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if [[ "$file" != "$allowed_root" && "$file" != "$allowed_root"/* ]]; then
      report_hygiene_rejection "$classification" "$source_root" "$file"
      return 1
    fi
  done <<< "$files"
}

allow_source_matches_only_in_file() {
  local classification="$1"
  local source_root="$2"
  local pattern="$3"
  local allowed_file="$4"
  local files
  local file

  files="$(source_match_files "$source_root" "$pattern")" || return 1
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if [[ "$file" != "$allowed_file" ]]; then
      report_hygiene_rejection "$classification" "$source_root" "$file"
      return 1
    fi
  done <<< "$files"
}

verify_provider_scopes() {
  local source_root="$1"
  local files
  local file
  local scopes
  local scope

  files="$(source_match_files "$source_root" 'https://www[.]googleapis[.]com/auth/')" || return 1
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    scopes="$(source_match_values "$file" 'https://www[.]googleapis[.]com/auth/[A-Za-z0-9._/-]+')" || return 1
    scopes="$(print -r -- "$scopes" | sort -u)"
    while IFS= read -r scope; do
      [[ -n "$scope" ]] || continue
      case "$scope" in
        'https://www.googleapis.com/auth/gmail.readonly' \
          |'https://www.googleapis.com/auth/calendar.readonly' \
          |'https://www.googleapis.com/auth/tasks.readonly') ;;
        *)
          report_hygiene_rejection 'provider write scope' "$source_root" "$file"
          return 1
          ;;
      esac
    done <<< "$scopes"
  done <<< "$files"
}

verify_provider_posts() {
  local source_root="$1"
  local files
  local file
  local relative
  local lines
  local line

  files="$(source_match_files "$source_root" '"POST"')" || return 1
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    relative="${file#$source_root/}"
    lines="$(source_match_lines "$file" '"POST"')" || return 1
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      case "$relative|$line" in
        'DailyPlannerGoogle/GoogleReadOnlyConnectionController.swift|request.httpMethod = "POST"') ;;
        'DailyPlannerGoogle/GoogleNetworkPolicy.swift|case ("POST", "oauth2.googleapis.com", "/token", nil),') ;;
        'DailyPlannerGoogle/GoogleNetworkPolicy.swift|("POST", "oauth2.googleapis.com", "/revoke", nil):') ;;
        *)
          report_hygiene_rejection 'provider POST outside OAuth allowlist' "$source_root" "$file"
          return 1
          ;;
      esac
    done <<< "$lines"
  done <<< "$files"
}

verify_provider_hosts() {
  local source_root="$1"
  local files
  local file
  local hosts
  local host

  files="$(source_match_files "$source_root" '([A-Za-z0-9-]+([.][A-Za-z0-9-]+)*)[.]googleapis[.]com|accounts[.]google[.]com')" || return 1
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    hosts="$(source_match_values "$file" '([A-Za-z0-9-]+([.][A-Za-z0-9-]+)*)[.]googleapis[.]com|accounts[.]google[.]com')" || return 1
    hosts="$(print -r -- "$hosts" | sort -u)"
    while IFS= read -r host; do
      [[ -n "$host" ]] || continue
      case "$host" in
        accounts.google.com|oauth2.googleapis.com|gmail.googleapis.com|www.googleapis.com|tasks.googleapis.com) ;;
        *)
          report_hygiene_rejection 'unexpected provider host' "$source_root" "$file"
          return 1
          ;;
      esac
    done <<< "$hosts"
  done <<< "$files"
}

verify_m2a_source_hygiene() {
  local source_root="$1"
  local package_file="$2"
  local google_root="$source_root/DailyPlannerGoogle"
  local settings_store="$source_root/DailyPlannerPersistence/EncryptedPrivateSettingsStore.swift"
  local bookmark_creator="$source_root/DailyPlannerPlatform/MacVaultFolderPicker.swift"
  local browser_opener="$source_root/DailyPlannerPlatform/MacSystemBrowser.swift"

  allow_source_matches_only_within \
    'network capability outside DailyPlannerGoogle' \
    "$source_root" \
    '(^|[^A-Za-z0-9_])URLSession([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])URLRequest([^A-Za-z0-9_]|$)|import[[:space:]]+Network|NW(Connection|Listener)|CFNetwork' \
    "$google_root" || return 1
  allow_source_matches_only_in_file \
    'AppKit browser opening outside MacSystemBrowser.swift' \
    "$source_root" \
    'NSWorkspace[.]shared[.]open[[:space:]]*[(]' \
    "$browser_opener" || return 1

  verify_provider_scopes "$source_root" || return 1
  reject_source_matches \
    'Gmail write route' \
    "$source_root" \
    'gmail/v[0-9]+[^"[:space:]]*(messages/([^"[:space:]]+/(send|modify|trash|untrash)|(send|modify|trash|untrash|insert|batchModify|batchDelete))|threads/[^"[:space:]]+/(modify|trash|untrash)|drafts/[^"[:space:]]*/send|settings/(sendAs|delegates|filters|forwardingAddresses|vacation))' || return 1
  reject_source_matches \
    'Calendar or Tasks mutation capability' \
    "$source_root" \
    '(calendar/v[0-9]+[^"[:space:]]*(events/[^"[:space:]]+/(move|watch)|calendars/[^"[:space:]]+/clear|acl/[^"[:space:]]+/watch|channels/stop)|tasks/v[0-9]+[^"[:space:]]*(lists/[^"[:space:]]+/clear|tasks/[^"[:space:]]+/move))' || return 1
  reject_source_matches \
    'provider mutation method' \
    "$source_root" \
    '"(PUT|PATCH|DELETE)"' || return 1
  verify_provider_posts "$source_root" || return 1
  verify_provider_hosts "$source_root" || return 1

  reject_source_matches \
    'Codex or process launch capability' \
    "$source_root" \
    'Codex|codex[[:space:]-]|Process[[:space:]]*[(]|NSTask|posix_spawn|launchPath[[:space:]]*=|executableURL' || return 1
  reject_source_matches \
    'vault bookmark resolution' \
    "$source_root" \
    'startAccessingSecurityScopedResource|resolvingBookmarkData|URL[[:space:]]*[(][[:space:]]*resolvingBookmarkData' || return 1
  allow_source_matches_only_in_file \
    'vault bookmark creation outside MacVaultFolderPicker.swift' \
    "$source_root" \
    'bookmarkData[[:space:]]*[(]' \
    "$bookmark_creator" || return 1
  allow_source_matches_only_in_file \
    'content I/O outside encrypted private-settings storage' \
    "$source_root" \
    'Data[[:space:]]*[(][[:space:]]*contentsOf:|String[[:space:]]*[(][[:space:]]*contentsOf:|FileHandle|NSFileCoordinator|contentsOfDirectory|enumerator[[:space:]]*[(]|contents[[:space:]]*[(]atPath:|[.]write[[:space:]]*[(][[:space:]]*to:' \
    "$settings_store" || return 1
  reject_source_matches \
    'notification capability' \
    "$source_root" \
    'UNUserNotificationCenter|NSUserNotification|UserNotifications' || return 1
  reject_source_matches \
    'timer, scheduler, or login capability' \
    "$source_root" \
    'Timer[.]scheduledTimer|DispatchSource[.]makeTimerSource|RunLoop[.]main[.]add|schedule[[:space:]]*[(]|Scheduler|SMAppService|LaunchAtLogin|LSSharedFileList|launchd' || return 1
  reject_source_matches \
    'dynamic logging capability' \
    "$source_root" \
    '(^|[^A-Za-z0-9_])(print|debugPrint|dump|NSLog|os_log|fatalError|preconditionFailure|assertionFailure)[[:space:]]*[(]|Logger[[:space:]]*[(]' || return 1

  if rg -q -- '[.]package[[:space:]]*[(]' "$package_file"; then
    report_hygiene_rejection 'external Swift package declaration' "$source_root" "$source_root/Package.swift"
  fi
}

make_canary_root() {
  local name="$1"
  local canary_root="$scratch/canaries/$name"

  mkdir -p "$canary_root"
  cp -R "$planner_root/Sources" "$canary_root/Sources"
  cp "$planner_root/Package.swift" "$canary_root/Package.swift"
  print -r -- "$canary_root"
}

expect_hygiene_rejection() {
  local classification="$1"
  local canary_root="$2"
  local injected_file="$3"
  local output_file="$4"

  if verify_m2a_source_hygiene "$canary_root/Sources" "$canary_root/Package.swift" > "$output_file" 2>&1; then
    print -u2 -r -- "M2A inverse canary unexpectedly passed: $classification"
    return 1
  fi
  if ! rg -Fq -- "M2A hygiene reject: $classification" "$output_file"; then
    print -u2 -r -- "M2A inverse canary reported the wrong rejection class: $classification"
    return 1
  fi
  if ! rg -Fxq -- "  file: $injected_file" "$output_file"; then
    print -u2 -r -- "M2A inverse canary did not name its relative injected file: $classification"
    return 1
  fi
  print -r -- "M2A inverse canary passed: $classification"
}

require_executed_test() {
  local test_name="$1"
  local test_log="$2"

  if ! rg -Fq -- "$test_name" "$test_log"; then
    print -u2 -r -- "M2A verifier required executable test did not run: $test_name"
    return 1
  fi
}

require_full_test_result() {
  local test_log="$1"

  if ! rg -Fq -- 'Executed 207 tests, with 0 failures (0 unexpected)' "$test_log"; then
    print -u2 -r -- 'M2A verifier did not observe the required 207-test zero-failure result'
    return 1
  fi
}

verify_generated_evidence() {
  local files
  local path_files
  local generic_path_files
  local matched_files
  local file
  local relative

  print -r -- 'generated-evidence secret and private-path scan passed' > "$evidence_root/evidence-scan.log"
  files="$(scan_evidence_files -- \
    'synthetic-(credential|access-token|refresh-token|authorization-code|authorization-url|provider-content)|https://accounts[.]google[.]com/o/oauth2/v2/auth|Bearer[[:space:]]|access_token|refresh_token|authorization[[:space:]_-]+(code|url)|provider[-_[:space:]]+content' \
    )" || return 1
  path_files="$(scan_evidence_files -F -e "$repo_root" -e "$scratch")" || return 1
  generic_path_files="$(scan_evidence_files -- '/Users/|/home/')" || return 1
  if [[ -n "$files" || -n "$path_files" || -n "$generic_path_files" ]]; then
    print -u2 -r -- 'M2A verifier found a credential, authorization URL, provider-content sentinel, or private path in generated evidence'
    for matched_files in "$files" "$path_files" "$generic_path_files"; do
      while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        relative="${file#$evidence_root/}"
        print -u2 -r -- "  file: $relative"
      done <<< "$matched_files"
    done
    return 1
  fi
}

scan_evidence_files() {
  local files
  local rg_status=0

  setopt localoptions noerrexit
  files="$(rg -l "$@" "$evidence_root" 2>/dev/null)" || rg_status=$?
  case "$rg_status" in
    0) print -r -- "$files" ;;
    1) ;;
    *)
      print -u2 -r -- 'M2A verifier could not scan generated evidence'
      return 1
      ;;
  esac
}

verify_worktree_preserved() {
  local output_file="$evidence_root/worktree-check.log"

  capture_worktree_state after
  if ! cmp -s "$state_root/worktree-before-status.sha256" "$state_root/worktree-after-status.sha256" \
    || ! cmp -s "$state_root/worktree-before-unstaged.sha256" "$state_root/worktree-after-unstaged.sha256" \
    || ! cmp -s "$state_root/worktree-before-staged.sha256" "$state_root/worktree-after-staged.sha256" \
    || ! cmp -s "$state_root/worktree-before-untracked.sha256" "$state_root/worktree-after-untracked.sha256"; then
    print -u2 -r -- 'M2A verifier changed the Git worktree from its captured baseline'
    return 1
  fi
  print -r -- 'staged, unstaged, status, and untracked-content fingerprints preserved' > "$output_file"
}

capture_worktree_state before

run_with_evidence "$evidence_root/swift-test.log" \
  swift test --package-path "$planner_root" --scratch-path "$scratch/swift" --no-parallel
require_executed_test \
  'GoogleOAuthRequestTests testReadOnlyScopesHaveTheApprovedFiveValuesInOrder' \
  "$evidence_root/swift-test.log"
require_executed_test \
  'GoogleOAuthKeychainTests testClientIdentifierAndRefreshTokenUseOnlyExactDeviceLocalRecords' \
  "$evidence_root/swift-test.log"
require_full_test_result "$evidence_root/swift-test.log"

build_tmp="$scratch/build-app-tmp"
mkdir -p "$build_tmp"
run_with_evidence "$evidence_root/build-app.log" \
  env TMPDIR="$build_tmp" zsh "$planner_root/Scripts/build-app.sh"
run_with_evidence "$evidence_root/sign-before-launch.log" \
  zsh "$planner_root/Tests/verify-signed-app.sh"
run_with_evidence "$evidence_root/diff-check.log" \
  git -C "$repo_root" diff --check
verify_m2a_source_hygiene "$planner_root/Sources" "$planner_root/Package.swift"

write_scope_root="$(make_canary_root write-scope)"
print -r -- 'let canaryWriteScope = "https://www.googleapis.com/auth/gmail.modify"' \
  > "$write_scope_root/Sources/DailyPlannerGoogle/CanaryWriteScope.swift"
expect_hygiene_rejection \
  'provider write scope' \
  "$write_scope_root" \
  'DailyPlannerGoogle/CanaryWriteScope.swift' \
  "$evidence_root/canary-write-scope.log"

delete_root="$(make_canary_root provider-delete)"
print -r -- 'let canaryMethod = "DELETE"
var canaryRequest = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
canaryRequest.httpMethod = canaryMethod' \
  > "$delete_root/Sources/DailyPlannerGoogle/CanaryProviderDelete.swift"
expect_hygiene_rejection \
  'provider mutation method' \
  "$delete_root" \
  'DailyPlannerGoogle/CanaryProviderDelete.swift' \
  "$evidence_root/canary-provider-delete.log"
print -r -- 'let canaryModifyRoute = "https://gmail.googleapis.com/gmail/v1/users/me/messages/canary/modify"' \
  > "$delete_root/Sources/DailyPlannerGoogle/CanaryGmailModify.swift"
expect_hygiene_rejection \
  'Gmail write route' \
  "$delete_root" \
  'DailyPlannerGoogle/CanaryGmailModify.swift' \
  "$evidence_root/canary-provider-delete-route.log"

host_root="$(make_canary_root unexpected-provider-host)"
print -r -- 'let canaryProviderHost = "unexpected.googleapis.com"' \
  > "$host_root/Sources/DailyPlannerGoogle/CanaryProviderHost.swift"
expect_hygiene_rejection \
  'unexpected provider host' \
  "$host_root" \
  'DailyPlannerGoogle/CanaryProviderHost.swift' \
  "$evidence_root/canary-unexpected-provider-host.log"

log_root="$(make_canary_root dynamic-log)"
print -r -- 'print("canary")' \
  > "$log_root/Sources/DailyPlannerGoogle/CanaryDynamicLog.swift"
expect_hygiene_rejection \
  'dynamic logging capability' \
  "$log_root" \
  'DailyPlannerGoogle/CanaryDynamicLog.swift' \
  "$evidence_root/canary-dynamic-log.log"

app="$planner_root/.build/app/Daily Planner.app"
binary="$app/Contents/MacOS/DailyPlanner"
[[ -x "$binary" && -f "$binary" ]]

launch_pipe="$scratch/launch-output.pipe"
mkfifo "$launch_pipe"
exec {launch_capture_keepalive_fd}<>"$launch_pipe"
begin_interruption_deferral
(
  exec {launch_capture_keepalive_fd}>&-
  exec perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' -- \
    "${sanitizer_command[@]}" "$launch_pipe" > "$evidence_root/launch.log"
) &
launch_capture_pid=$!
if record_owned_child "$launch_capture_pid" 1; then
  launch_capture_registration_status=0
else
  launch_capture_registration_status=$?
fi
launch_capture_fallback_identity="$recorded_child_fallback_identity"
launch_capture_fallback_job_owned="$recorded_child_fallback_job_owned"
launch_capture_fallback_group="$recorded_child_fallback_group"
launch_capture_fallback_known_gone="$recorded_child_fallback_known_gone"
if [[ "$launch_capture_registration_status" -eq 0 ]]; then
  launch_capture_identity="$recorded_child_identity"
  launch_capture_command="$recorded_child_command"
fi
end_interruption_deferral
if [[ "$launch_capture_registration_status" -ne 0 ]]; then
  print -u2 -r -- 'M2A verifier could not establish its exact owned output capture process'
  exit 1
fi

planner_guardian_status="$scratch/app-guardian-status"
planner_guardian_control="$scratch/app-guardian-control"
: > "$planner_guardian_control"
begin_interruption_deferral
(
  exec {launch_capture_keepalive_fd}>&-
  exec zsh -f -c '
  setopt noerrexit
  binary_path="$1"
  status_path="$2"
  control_path="$3"
  guardian_pid="$$"
  app_pid=""

  write_status() {
    print -r -- "$1:$guardian_pid:$app_pid" > "$status_path"
  }

  child_is_gone_or_zombie() {
    local child_state
    if ! kill -0 "$app_pid" 2>/dev/null; then
      return 0
    fi
    child_state="$(ps -p "$app_pid" -o stat= 2>/dev/null | tr -d "[:space:]")"
    [[ "$child_state" == Z* ]]
  }

  reap_gone_child() {
    child_is_gone_or_zombie || return 1
    wait "$app_pid" 2>/dev/null || true
  }

  clean_child() {
    local signal_name
    local attempt

    reap_gone_child && return 0
    for signal_name in TERM KILL; do
      kill -"$signal_name" "$app_pid" 2>/dev/null || true
      for attempt in {1..20}; do
        reap_gone_child && return 0
        sleep 0.05
      done
    done
    return 1
  }

  finish_cleanup() {
    if clean_child; then
      write_status cleaned
      exit 0
    fi
    write_status failed
    exit 1
  }

  # The verifier sends an explicit control record for interruption.  Ignore
  # inherited job-control HUP so an unacknowledged guardian reaches its own
  # bounded child-cleanup deadline instead of disappearing mid-cleanup.
  trap "" HUP
  trap finish_cleanup INT TERM
  "$binary_path" &
  app_pid=$!
  write_status ready
  for attempt in {1..40}; do
    control_value="$(< "$control_path")"
    if [[ "$control_value" == "terminate:$guardian_pid:$app_pid" ]]; then
      finish_cleanup
    fi
    if [[ "$control_value" == "ack:$guardian_pid:$app_pid" ]]; then
      write_status acknowledged
      break
    fi
    if reap_gone_child; then
      write_status exited
      exit 0
    fi
    sleep 0.05
  done
  [[ "$control_value" == "ack:$guardian_pid:$app_pid" ]] || finish_cleanup
  while true; do
    control_value="$(< "$control_path")"
    [[ "$control_value" == "terminate:$guardian_pid:$app_pid" ]] && finish_cleanup
    if reap_gone_child; then
      write_status exited
      exit 0
    fi
    sleep 0.05
  done
' -- "$binary" "$planner_guardian_status" "$planner_guardian_control" > "$launch_pipe" 2>&1
) &
planner_guardian_pid=$!
planner_pid=''
planner_identity=''
if record_owned_child "$planner_guardian_pid"; then
  planner_guardian_registration_status=0
else
  planner_guardian_registration_status=$?
fi
planner_guardian_known_gone="$recorded_child_fallback_known_gone"
if [[ "$planner_guardian_registration_status" -eq 0 ]]; then
  planner_guardian_identity="$recorded_child_identity"
  planner_guardian_command="$recorded_child_command"
fi
if await_planner_guardian_ready; then
  planner_guardian_ready_status=0
else
  planner_guardian_ready_status=$?
fi
if [[ "$planner_guardian_ready_status" -eq 0 ]]; then
  if record_child_of_parent "$planner_pid" "$planner_guardian_pid" "$binary"; then
    planner_registration_status=0
  else
    planner_registration_status=$?
  fi
  planner_fallback_identity="$recorded_child_fallback_identity"
  planner_fallback_known_gone="$recorded_child_fallback_known_gone"
  if [[ "$planner_registration_status" -eq 0 ]]; then
    planner_identity="$recorded_child_identity"
  fi
  if write_planner_guardian_control ack && await_planner_guardian_status acknowledged; then
    planner_guardian_handshake_verified=1
  fi
else
  planner_registration_status=1
fi
end_interruption_deferral
if [[ "$planner_guardian_registration_status" -ne 0 || "$planner_guardian_ready_status" -ne 0 \
  || "$planner_registration_status" -ne 0 || -z "$planner_identity" \
  || "$planner_guardian_handshake_verified" -ne 1 ]]; then
  print -u2 -r -- 'M2A verifier could not observe its exact owned app process alive'
  exit 1
fi
print -r -- 'exact owned app process observed alive' > "$evidence_root/lifecycle.log"
refresh_launch_capture_command

if ! terminate_owned_app; then
  print -u2 -r -- 'M2A verifier could not terminate and reap its exact owned app process'
  exit 1
fi
print -r -- 'exact owned app process terminated and reaped' >> "$evidence_root/lifecycle.log"
if ! finish_launch_capture; then
  print -u2 -r -- 'M2A verifier could not terminate and reap its exact owned output capture process'
  exit 1
fi

run_with_evidence "$evidence_root/sign-after-launch.log" \
  zsh "$planner_root/Tests/verify-signed-app.sh"
verify_worktree_preserved
verify_generated_evidence
if [[ -n "$(jobs -p)" ]]; then
  print -u2 -r -- 'M2A verifier retained an owned background job after lifecycle cleanup'
  exit 1
fi

verifier_completed=1
exit 0
