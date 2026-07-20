#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/dont-sleep.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dont-sleep-tests.XXXXXX")"
failures=0

cleanup() {
  if command -v trash >/dev/null 2>&1; then
    trash "${TEST_TMP}" >/dev/null 2>&1 || true
  else
    /bin/rm -R "${TEST_TMP}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s: %s\n' "$1" "$2" >&2; failures=$((failures + 1)); }

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then pass "${name}"; else fail "${name}" "expected '${expected}', got '${actual}'"; fi
}

make_stale() {
  local path="$1" minutes="$2" stamp
  if date -v-"${minutes}"M '+%Y%m%d%H%M.%S' >/dev/null 2>&1; then
    stamp="$(date -v-"${minutes}"M '+%Y%m%d%H%M.%S')"
    touch -t "${stamp}" "${path}"
  else
    touch -d "${minutes} minutes ago" "${path}"
  fi
}

set_mtime_epoch() {
  local path="$1" epoch="$2" stamp
  stamp="$(date -r "${epoch}" '+%Y%m%d%H%M.%S')"
  touch -t "${stamp}" "${path}"
}

write_fixture() {
  local path="$1" kind="$2" timestamp="${FIXTURE_TIMESTAMP:-2023-11-14T22:08:20Z}"
  case "${kind}" in
    claude-pending)
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"${FIXTURE_TOOL_NAME:-Bash}\",\"input\":{}}]}}" > "${path}"
      ;;
    claude-complete)
      write_fixture "${path}" claude-pending
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"done\"}]}}" >> "${path}"
      ;;
    claude-abandoned)
      write_fixture "${path}" claude-pending
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"new prompt\"}}" >> "${path}"
      ;;
    claude-parallel-one-pending)
      write_fixture "${path}" claude-pending
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_2\",\"name\":\"Bash\",\"input\":{}}]}}" >> "${path}"
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_2\",\"content\":\"done\"}]}}" >> "${path}"
      ;;
    claude-waiting-for-user)
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_ask\",\"name\":\"AskUserQuestion\",\"input\":{}}]}}" > "${path}"
      ;;
    claude-meta-during-tool)
      write_fixture "${path}" claude-pending
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"user\",\"isMeta\":true,\"message\":{\"role\":\"user\",\"content\":\"internal metadata\"}}" >> "${path}"
      ;;
    codex-pending)
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}" > "${path}"
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"call_id\":\"call_1\",\"name\":\"${FIXTURE_TOOL_NAME:-exec}\",\"status\":\"completed\"}}" >> "${path}"
      ;;
    codex-complete)
      write_fixture "${path}" codex-pending
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call_output\",\"call_id\":\"call_1\",\"output\":\"done\"}}" >> "${path}"
      ;;
    codex-task-complete)
      write_fixture "${path}" codex-pending
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}" >> "${path}"
      ;;
    codex-waiting-for-user)
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}" > "${path}"
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"call_ask\",\"name\":\"request_user_input\"}}" >> "${path}"
      ;;
    codex-generic-pending)
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}" > "${path}"
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"response_item\",\"payload\":{\"type\":\"local_shell_call\",\"call_id\":\"call_shell\",\"name\":\"shell\"}}" >> "${path}"
      ;;
    codex-generic-complete)
      write_fixture "${path}" codex-generic-pending
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"response_item\",\"payload\":{\"type\":\"local_shell_call_output\",\"call_id\":\"call_shell\",\"output\":\"done\"}}" >> "${path}"
      ;;
    codex-fast-pending)
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}" > "${path}"
      printf '%s\n' "{\"timestamp\":\"${timestamp}\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"call_fast\",\"name\":\"view_image\"}}" >> "${path}"
      ;;
  esac
}

test_activity_signal() {
  local functions claude_dir="${TEST_TMP}/claude" codex_dir="${TEST_TMP}/codex" fixture
  mkdir -p "${claude_dir}" "${codex_dir}"
  functions="$(awk '
    /^read_transcript_tail\(\)/ { capture=1 }
    /^parse_latest_event_epoch\(\)/ { capture=1 }
    /^session_has_recent_event\(\)/ { capture=1 }
    /^session_has_outstanding_tool\(\)/ { capture=1 }
    /^track_session_file\(\)/ { capture=1 }
    /^agents_active\(\)/ { capture=1 }
    capture { print }
    capture && /^}/ { capture=0 }
  ' "${SCRIPT}")"
  eval "${functions}"
  if ! declare -F session_has_outstanding_tool >/dev/null; then
    fail "activity helper exists" "session_has_outstanding_tool is missing"
    return
  fi

  CLAUDE_SESSIONS_DIR="${claude_dir}"
  CODEX_SESSIONS_DIR="${codex_dir}"
  AGENT_GRACE_MINUTES=5
  FAST_TOOL_MAX_MINUTES=10
  OUTSTANDING_TOOL_MAX_MINUTES=60
  SESSION_DISCOVERY_INTERVAL_SECONDS=120
  JQ_BIN=/usr/bin/jq
  ACTIVITY_TRACKER_SEEDED=1
  last_session_discovery=0
  TRACKED_SESSION_FILES=()
  ACTIVE_PENDING_FILE=""
  ACTIVE_PENDING_MTIME=""
  ACTIVE_PENDING_UNTIL=0
  ACTIVE_AGENT_REASON=""
  RECENT_EVENT_CACHE_FILES=()
  RECENT_EVENT_CACHE_MTIMES=()
  RECENT_EVENT_CACHE_EPOCHS=()
  now=1700000000

  fixture="${claude_dir}/pending.jsonl"
  write_fixture "${fixture}" claude-pending
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && pass "Claude pending tool is active" || fail "Claude pending tool is active" "reported inactive"
  TRACKED_SESSION_FILES=("${fixture}")
  agents_active && pass "stale Claude transcript with pending tool is active" || fail "stale Claude transcript with pending tool is active" "reported inactive"

  mv "${fixture}" "${fixture}.used"
  fixture="${claude_dir}/complete.jsonl"
  write_fixture "${fixture}" claude-complete
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && fail "Claude completed tool is inactive" "reported active" || pass "Claude completed tool is inactive"

  fixture="${claude_dir}/abandoned.jsonl"
  write_fixture "${fixture}" claude-abandoned
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && fail "Claude new prompt clears abandoned tool" "reported active" || pass "Claude new prompt clears abandoned tool"

  fixture="${claude_dir}/parallel.jsonl"
  write_fixture "${fixture}" claude-parallel-one-pending
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && pass "Claude parallel calls retain unfinished call" || fail "Claude parallel calls retain unfinished call" "reported inactive"

  fixture="${claude_dir}/waiting.jsonl"
  write_fixture "${fixture}" claude-waiting-for-user
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && fail "Claude user-input tool is inactive" "reported active" || pass "Claude user-input tool is inactive"

  fixture="${claude_dir}/meta-during-tool.jsonl"
  write_fixture "${fixture}" claude-meta-during-tool
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && pass "Claude metadata does not clear pending tool" || fail "Claude metadata does not clear pending tool" "reported inactive"

  fixture="${claude_dir}/expired-edit.jsonl"
  FIXTURE_TIMESTAMP=2023-11-14T22:02:20Z FIXTURE_TOOL_NAME=Edit write_fixture "${fixture}" claude-pending
  touch "${fixture}"
  session_has_outstanding_tool "${fixture}" && fail "fast Claude tool expires after ten minutes" "reported active" || pass "fast Claude tool expires after ten minutes"

  fixture="${claude_dir}/active-edit.jsonl"
  FIXTURE_TIMESTAMP=2023-11-14T22:06:20.123Z FIXTURE_TOOL_NAME=Edit write_fixture "${fixture}" claude-pending
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && pass "fast Claude tool remains active for seven minutes" || fail "fast Claude tool remains active for seven minutes" "reported inactive"

  fixture="${claude_dir}/long-bash.jsonl"
  FIXTURE_TIMESTAMP=2023-11-14T21:43:20Z FIXTURE_TOOL_NAME=Bash write_fixture "${fixture}" claude-pending
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && pass "long Claude tool remains active for thirty minutes" || fail "long Claude tool remains active for thirty minutes" "reported inactive"

  fixture="${claude_dir}/long-subagent.jsonl"
  FIXTURE_TIMESTAMP=2023-11-14T21:43:20Z FIXTURE_TOOL_NAME=Task write_fixture "${fixture}" claude-pending
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && pass "Claude subagent remains active for thirty minutes" || fail "Claude subagent remains active for thirty minutes" "reported inactive"

  fixture="${claude_dir}/expired-bash.jsonl"
  FIXTURE_TIMESTAMP=2023-11-14T21:12:20Z FIXTURE_TOOL_NAME=Bash write_fixture "${fixture}" claude-pending
  touch "${fixture}"
  session_has_outstanding_tool "${fixture}" && fail "all tools expire after one hour" "reported active" || pass "all tools expire after one hour"

  fixture="${codex_dir}/pending.jsonl"
  write_fixture "${fixture}" codex-pending
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && pass "Codex pending tool is active" || fail "Codex pending tool is active" "reported inactive"

  fixture="${codex_dir}/long-exec.jsonl"
  FIXTURE_TIMESTAMP=2023-11-14T21:43:20Z write_fixture "${fixture}" codex-pending
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && pass "Codex exec remains active for thirty minutes" || fail "Codex exec remains active for thirty minutes" "reported inactive"

  fixture="${codex_dir}/long-shell.jsonl"
  FIXTURE_TIMESTAMP=2023-11-14T21:43:20Z write_fixture "${fixture}" codex-generic-pending
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && pass "Codex shell call remains active for thirty minutes" || fail "Codex shell call remains active for thirty minutes" "reported inactive"

  fixture="${codex_dir}/expired-fast.jsonl"
  FIXTURE_TIMESTAMP=2023-11-14T22:02:20Z write_fixture "${fixture}" codex-fast-pending
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && fail "fast Codex tool expires after ten minutes" "reported active" || pass "fast Codex tool expires after ten minutes"

  fixture="${codex_dir}/complete.jsonl"
  write_fixture "${fixture}" codex-complete
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && fail "Codex completed tool is inactive" "reported active" || pass "Codex completed tool is inactive"

  fixture="${codex_dir}/task-complete.jsonl"
  write_fixture "${fixture}" codex-task-complete
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && fail "Codex task completion clears pending tool" "reported active" || pass "Codex task completion clears pending tool"

  fixture="${codex_dir}/waiting.jsonl"
  write_fixture "${fixture}" codex-waiting-for-user
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && fail "Codex user-input tool is inactive" "reported active" || pass "Codex user-input tool is inactive"

  fixture="${codex_dir}/generic-pending.jsonl"
  write_fixture "${fixture}" codex-generic-pending
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && pass "future Codex paired call is active" || fail "future Codex paired call is active" "reported inactive"

  fixture="${codex_dir}/generic-complete.jsonl"
  write_fixture "${fixture}" codex-generic-complete
  make_stale "${fixture}" 10
  session_has_outstanding_tool "${fixture}" && fail "future Codex paired output clears call" "reported active" || pass "future Codex paired output clears call"

  fixture="${codex_dir}/malformed.jsonl"
  printf '%s\n' '{"type":"response_item","payload":' > "${fixture}"
  set_mtime_epoch "${fixture}" $((now - 30 * 60))
  session_has_outstanding_tool "${fixture}" && pass "malformed transcript fails safe active" || fail "malformed transcript fails safe active" "reported inactive"
  now=$((now + 31 * 60))
  session_has_outstanding_tool "${fixture}" && fail "malformed transcript fallback expires after one hour" "reported active" || pass "malformed transcript fallback expires after one hour"
  now=$((now - 31 * 60))

  JQ_BIN=/not/installed/jq
  fixture="${codex_dir}/missing-jq.jsonl"
  write_fixture "${fixture}" codex-complete
  set_mtime_epoch "${fixture}" $((now - 30 * 60))
  session_has_outstanding_tool "${fixture}" && pass "missing jq fails safe active" || fail "missing jq fails safe active" "reported inactive"
  now=$((now + 31 * 60))
  session_has_outstanding_tool "${fixture}" && fail "missing jq fallback expires after one hour" "reported active" || pass "missing jq fallback expires after one hour"
  now=$((now - 31 * 60))
  JQ_BIN=/usr/bin/jq

  fixture="${codex_dir}/unreadable.jsonl"
  write_fixture "${fixture}" codex-pending
  set_mtime_epoch "${fixture}" $((now - 30 * 60))
  original_read_transcript_tail="$(declare -f read_transcript_tail)"
  read_transcript_tail() { return 1; }
  session_has_recent_event "${fixture}" && pass "unreadable recent transcript fails safe active" || fail "unreadable recent transcript fails safe active" "reported inactive"
  session_has_outstanding_tool "${fixture}" && pass "unreadable pending transcript fails safe active" || fail "unreadable pending transcript fails safe active" "reported inactive"
  now=$((now + 31 * 60))
  session_has_outstanding_tool "${fixture}" && fail "unreadable transcript fallback expires after one hour" "reported active" || pass "unreadable transcript fallback expires after one hour"
  now=$((now - 31 * 60))
  eval "${original_read_transcript_tail}"

  fixture="${claude_dir}/old-event-new-mtime.jsonl"
  FIXTURE_TIMESTAMP=2023-11-14T20:13:20Z write_fixture "${fixture}" claude-complete
  touch "${fixture}"
  CLAUDE_SESSIONS_DIR="${claude_dir}"
  CODEX_SESSIONS_DIR="${TEST_TMP}/no-codex"
  ACTIVITY_TRACKER_SEEDED=1
  last_session_discovery="${now}"
  TRACKED_SESSION_FILES=()
  ACTIVE_PENDING_FILE=""
  ACTIVE_PENDING_MTIME=""
  ACTIVE_PENDING_UNTIL=0
  agents_active && fail "metadata-only file touch is inactive" "reported active" || pass "metadata-only file touch is inactive"

  fixture="${claude_dir}/recent-event.jsonl"
  FIXTURE_TIMESTAMP=2023-11-14T22:08:20.123Z write_fixture "${fixture}" claude-complete
  touch "${fixture}"
  agents_active && pass "fractional timestamped recent event is active" || fail "fractional timestamped recent event is active" "reported inactive"
  make_stale "${fixture}" 10

  fixture="${claude_dir}/recent-cache.jsonl"
  FIXTURE_TIMESTAMP=2023-11-14T22:08:20Z write_fixture "${fixture}" claude-complete
  make_stale "${fixture}" 10
  original_parse_latest_event_epoch="$(declare -f parse_latest_event_epoch)"
  recent_parse_calls=0
  parse_latest_event_epoch() {
    recent_parse_calls=$((recent_parse_calls + 1))
    SESSION_LATEST_EVENT_EPOCH="${now}"
  }
  RECENT_EVENT_CACHE_FILES=()
  RECENT_EVENT_CACHE_MTIMES=()
  RECENT_EVENT_CACHE_EPOCHS=()
  session_has_recent_event "${fixture}"
  session_has_recent_event "${fixture}"
  assert_eq "unchanged recent transcript is parsed once" 1 "${recent_parse_calls}"
  touch "${fixture}"
  session_has_recent_event "${fixture}"
  assert_eq "changed recent transcript invalidates cache" 2 "${recent_parse_calls}"
  eval "${original_parse_latest_event_epoch}"
  RECENT_EVENT_CACHE_FILES=()
  RECENT_EVENT_CACHE_MTIMES=()
  RECENT_EVENT_CACHE_EPOCHS=()
  make_stale "${fixture}" 10

  restart_dir="${TEST_TMP}/restart"
  mkdir -p "${restart_dir}"
  fixture="${restart_dir}/pending.jsonl"
  write_fixture "${fixture}" codex-pending
  make_stale "${fixture}" 10
  CLAUDE_SESSIONS_DIR="${restart_dir}/no-claude"
  CODEX_SESSIONS_DIR="${restart_dir}"
  ACTIVITY_TRACKER_SEEDED=0
  last_session_discovery=0
  TRACKED_SESSION_FILES=()
  ACTIVE_PENDING_FILE=""
  ACTIVE_PENDING_MTIME=""
  agents_active && pass "restart discovers stale pending tool" || fail "restart discovers stale pending tool" "reported inactive"
  assert_eq "restart caches discovered pending file" "${fixture}" "${ACTIVE_PENDING_FILE}"

  CLAUDE_SESSIONS_DIR="${claude_dir}"
  CODEX_SESSIONS_DIR="${codex_dir}"
  ACTIVITY_TRACKER_SEEDED=1
  last_session_discovery="${now}"

  fixture="${codex_dir}/expired-pending.jsonl"
  FIXTURE_TIMESTAMP=2023-11-14T21:12:20Z write_fixture "${fixture}" codex-pending
  touch "${fixture}"
  TRACKED_SESSION_FILES=("${fixture}")
  ACTIVE_PENDING_FILE=""
  ACTIVE_PENDING_MTIME=""
  ACTIVE_PENDING_UNTIL=0
  agents_active && fail "expired pending tools are inactive" "reported active" || pass "expired pending tools are inactive"

  make_stale "${claude_dir}/parallel.jsonl" 10
  TRACKED_SESSION_FILES=("${claude_dir}/parallel.jsonl")
  ACTIVE_PENDING_FILE=""
  ACTIVE_PENDING_MTIME=""
  ACTIVE_PENDING_UNTIL=0
  parse_calls=0
  stub_expiry=$((now + 60))
  session_has_outstanding_tool() {
    parse_calls=$((parse_calls + 1))
    SESSION_PENDING_UNTIL="${stub_expiry}"
    (( now <= stub_expiry ))
  }
  agents_active
  agents_active
  assert_eq "unchanged pending transcript is parsed once" 1 "${parse_calls}"

  now=$((now + 61))
  agents_active && fail "cached pending tool expires without a file write" "reported active" || pass "cached pending tool expires without a file write"
}

run_loop_case() {
  local name="$1" lid_state="$2" battery_state="$3" pct_value="$4" agent_state="$5" cooldown="$6"
  local expected_sleep="$7" expected_set="$8" expected_desired="$9" sleepnow_status="${10:-0}" expected_cooldown="${11:-$6}"
  local current_sleep="${12:-1}" thermal_value="${13:-Nominal}" initial_hot_count="${14:-0}"
  local body output
  body="$(awk '/^while true; do$/ { capture=1; next } capture && /^  sleep "\$\{POLL_INTERVAL_SECONDS\}"$/ { exit } capture { print }' "${SCRIPT}")"
  output="$({
    BATTERY_THRESHOLD=50 THERMAL_TRIGGER_RANK=2 HOT_READS_BEFORE_SLEEP=2 COOLDOWN_SECONDS=300 DRY_RUN=0
    AGENT_GRACE_MINUTES=5 POLL_INTERVAL_SECONDS=15 LOG_FILE=""
    hot_count="${initial_hot_count}" cooldown_until="${cooldown}" last_logged="" slept=0 set_calls=""
    date() { [[ "${1:-}" == "+%s" ]] && printf '1000\n' || command date "$@"; }
    battery_pct() { printf '%s\n' "${pct_value}"; }
    agents_active() { (( agent_state )); }
    lid_closed() { (( lid_state )); }
    on_battery() { (( battery_state )); }
    thermal_level() { printf '%s\n' "${thermal_value}"; }
    rank_of() { [[ "$1" == "Nominal" ]] && printf '0\n' || printf '2\n'; }
    current_disablesleep() { printf '%s\n' "${current_sleep}"; }
    set_sleep() { set_calls="${set_calls}$1"; }
    pmset() { if [[ "${1:-}" == "sleepnow" ]]; then slept=1; return "${sleepnow_status}"; fi; }
    log() { :; }
    sleep() { :; }
    for _iteration in 1; do eval "${body}"; done
    printf 'slept=%s set=%s desired=%s cooldown=%s\n' "${slept}" "${set_calls}" "${desired:-unset}" "${cooldown_until}"
  } 2>&1)"
  assert_eq "${name}" "slept=${expected_sleep} set=${expected_set} desired=${expected_desired} cooldown=${expected_cooldown}" "${output}"
}

test_release_truth_table() {
  run_loop_case "active, lid shut, battery: keep awake" 1 1 80 1 0 0 "" 1 0 0
  run_loop_case "idle, lid shut, battery: force sleep" 1 1 80 0 0 1 0 0 0 1300
  run_loop_case "idle, lid open, battery: release only" 0 1 80 0 0 0 0 0 0 0
  run_loop_case "idle, lid shut, AC: release only" 1 0 80 0 0 0 0 0 0 0
  run_loop_case "low battery, lid shut: force sleep" 1 1 40 1 0 1 0 0 0 1300
  run_loop_case "failed sleepnow: retry without cooldown" 1 1 80 0 0 1 0 0 1 0
  run_loop_case "already released after DarkWake: force sleep" 1 1 80 0 0 1 "" 0 0 1300 0
  run_loop_case "failed thermal sleepnow: retry without cooldown" 1 1 80 1 0 1 0 unset 1 0 1 Heavy 1
  run_loop_case "unreadable battery, lid shut: release only" 1 1 "" 1 0 0 0 0 0 0
  run_loop_case "release during cooldown: release only" 1 1 80 0 1100 0 0 0 0 1100
}

test_activity_signal
test_release_truth_table

if (( failures > 0 )); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nAll tests passed\n'
