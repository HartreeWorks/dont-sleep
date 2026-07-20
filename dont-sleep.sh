#!/usr/bin/env bash
#
# dont-sleep.sh — Keep this Mac awake for a long-running job (e.g. a
# Claude Code or Codex agent in a terminal) so it keeps working after you unplug
# and drop the laptop in your bag — the situation macOS would otherwise
# force-sleep — but only while an agent is actually working, and bail out and
# force sleep if the machine starts running hot in the bag.
#
# When it HOLDS the Mac awake: whenever a local Claude Code / Codex agent has
# recorded a timestamped transcript event in the last AGENT_GRACE_MINUTES, or
# has an outstanding tool call within its time limit, AND the battery is ≥
# BATTERY_THRESHOLD. It does NOT wait for the lid to shut or for you to be on
# battery.
#
# Why not wait for the lid to shut (this is the important bit): macOS
# clamshell-sleeps within a couple of seconds of the lid closing — much faster
# than this poll loop (measured on an M-series: lid shut → asleep in ~13s, vs a
# 15s poll). A version that only armed the override *after* it observed the lid
# shut lost that race every time: the Mac was already asleep (and this script
# frozen with it) before the next poll could run `pmset disablesleep 1`. So the
# override goes on as soon as an agent is working, while the lid is still open,
# and is therefore already in force whichever order you do things — unplug then
# shut the lid, or shut the lid then unplug. (Shutting the lid while still on AC
# would otherwise clamshell-sleep immediately, before you even unplug.)
#
# When it LETS GO: the moment no agent is recent or waiting on a tool, or the
# battery drops below BATTERY_THRESHOLD. If that happens while lid-shut on
# battery, it forces sleep: clamshell sleep is edge-triggered, so merely dropping
# disablesleep after the lid-close edge does not make macOS try again. It also
# force-sleeps after two Heavy+ thermal reads with the lid shut.
#
# Trade-off: because it must arm ahead of the lid closing, it also holds the Mac
# awake on AC and with the lid open while an agent is working — it is NOT inert
# on AC / lid-open the way an earlier version was. Timestamped activity expires
# after AGENT_GRACE_MINUTES; unmatched tools expire after ten or sixty minutes.
#
# Usage:
#   dont-sleep [BATTERY_THRESHOLD] [--dry-run]     # Ctrl-C to stop
#
#   BATTERY_THRESHOLD   Battery % at/above which to stay awake. Default: 50.
#   --dry-run   Log every decision but never actually flip sleep or sleepnow.
#               Use this to watch it behave for a while before trusting it.
#
# Activity log: when LOGGING_ENABLED (default 1), each decision transition is
# appended to ~/Library/Logs/dont-sleep.log with a full date, and
# entries older than LOG_RETENTION_DAYS (default 14) are pruned at each startup.
# Set LOGGING_ENABLED=0 for stdout only. `tail -f` the file to watch history.
#
# Run at startup (always-on): install as a root LaunchDaemon so it survives
# reboots and needs no password — see dont-sleep.plist and the README in this
# repo. The daemon sets DONT_SLEEP_USER so root can find the human user's
# transcripts and log. Note: always-on means it holds the Mac awake whenever
# ANY local agent is working (desk or bag) until it idles out.
#
# Why root: overriding sleep needs `pmset disablesleep` (root), and reading
# thermal pressure needs `powermetrics` (root). The script re-execs itself with
# sudo, so you get ONE password prompt at launch.
#
# Why no raw temperature: on Apple Silicon there's no reliable °C sensor path
# (the `smc` powermetrics sampler doesn't exist on M-series). The OS's thermal
# *pressure* level is the signal: Nominal < Moderate < Heavy < Trapping < Sleeping.
#
# Why transcript state (not "is claude/codex running"): both tools leave their
# process alive at a prompt for days while idle. They append JSONL while working,
# and record calls/results with matching IDs. Recency catches normal work; an
# unmatched call catches a long quiet build or tool wait. Human-input tools are
# excluded because the agent is waiting, not working. Fast tools expire after
# ten minutes; plausible long-running tools expire after one hour.
#
# Inspired by JP Addison's keep-awake.sh:
#   https://github.com/jpaddison3/dotfiles/blob/master/keep-awake.sh
#
set -euo pipefail

# --- Config (edit here; BATTERY_THRESHOLD is also overridable as arg 1) -------------
BATTERY_THRESHOLD=50           # battery % at/above which to stay awake
THERMAL_TRIGGER_LEVEL="Heavy"  # thermal pressure at/above which to force sleep
HOT_READS_BEFORE_SLEEP=2       # consecutive elevated reads before forcing sleep
POLL_INTERVAL_SECONDS=15       # loop cadence
AGENT_GRACE_MINUTES=5          # keep awake only if a Claude Code / Codex transcript
                               # contains an event timestamped this recently, or an
                               # outstanding tool call (proxy for a long, quiet step)
FAST_TOOL_MAX_MINUTES=10       # unmatched fast calls (Read/Edit/Grep/etc.) expire quickly
OUTSTANDING_TOOL_MAX_MINUTES=60 # hard ceiling for every unmatched call; shell commands
                                # and subagents receive the full allowance
SESSION_DISCOVERY_INTERVAL_SECONDS=120 # full recent-session scan cadence; normal
                                       # 15s polls stop at the first recent transcript
COOLDOWN_SECONDS=300           # min gap between forced sleeps (from wake): the trigger
                               # can't fire again for this long — anti-loop safety so a
                               # still-warm Mac can't keep sleeping when you wake it
LOGGING_ENABLED=1              # 1 = append each decision transition to the activity log; 0 = stdout only
LOG_RETENTION_DAYS=14          # at startup, drop activity-log lines older than this many days (0 = keep all)
JQ_BIN="${JQ_BIN:-/usr/bin/jq}" # injectable for fail-safe tests
# ---------------------------------------------------------------------------

DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    ''|*[!0-9]*) : ;;          # non-numeric, ignore
    *) BATTERY_THRESHOLD="${arg}" ;;   # a bare number overrides the battery threshold
  esac
done

# Re-exec as root so the single sudo prompt happens now, at launch.
if [[ "${EUID}" -ne 0 ]]; then
  echo "Re-running with sudo (needed for pmset disablesleep / sleepnow and powermetrics)…"
  exec sudo "$0" "$@"
fi

# Resolve the invoking (non-root) user's home. We're root now, so $HOME points
# at root's home — but the agent transcripts live under the human user's home.
# The `|| true` matters: dscl exits non-zero for an unknown user and, under
# `set -euo pipefail`, that would abort the script before the fallback runs.
# DONT_SLEEP_USER lets a launchd daemon (which has no SUDO_USER) name the human
# user whose transcripts/log live under /Users/<name>. Falls back to sudo/USER.
INVOKING_USER="${DONT_SLEEP_USER:-${SUDO_USER:-${USER:-}}}"
USER_HOME="$(dscl . -read "/Users/${INVOKING_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
USER_HOME="${USER_HOME:-/Users/${INVOKING_USER}}"
CLAUDE_SESSIONS_DIR="${USER_HOME}/.claude/projects"   # Claude Code transcripts
CODEX_SESSIONS_DIR="${USER_HOME}/.codex/sessions"     # Codex rollout transcripts

# If neither dir resolved, the agent check would silently always say "no agent"
# (Mac just sleeps as normal) — warn so a misconfiguration isn't invisible.
if [[ ! -d "${CLAUDE_SESSIONS_DIR}" && ! -d "${CODEX_SESSIONS_DIR}" ]]; then
  echo "WARNING: no Claude/Codex session dir found under ${USER_HOME} (user '${INVOKING_USER:-?}')." >&2
  echo "         Agent-activity will always read 'none' → the Mac will sleep as usual." >&2
fi

# --- Persistent activity log ------------------------------------------------
# When LOGGING_ENABLED, append every decision transition (with a full date) to a
# logfile, so a multi-day, multi-run history is reviewable later — e.g. "did the
# thermal guard ever fire?" or "how often did it actually hold sleep off?". We
# run as root, so create the file and hand ownership to the human user, who can
# then read/tail it without sudo. Path overridable via the LOG_FILE env var.
# LOG_FILE="" is the sentinel for "logging off" that log() checks each call.
LOG_FILE="${LOG_FILE:-${USER_HOME}/Library/Logs/dont-sleep.log}"
if (( LOGGING_ENABLED )); then
  mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
  # Retention: drop lines older than LOG_RETENTION_DAYS so the file can't grow
  # without bound. Lines start with an ISO date; ISO dates sort lexically, so a
  # string >= compare against the cutoff is correct. Dateless lines are kept.
  if [[ -f "${LOG_FILE}" ]] && (( LOG_RETENTION_DAYS > 0 )); then
    cutoff="$(date -v-"${LOG_RETENTION_DAYS}"d '+%Y-%m-%d' 2>/dev/null || true)"
    if [[ -n "${cutoff}" ]]; then
      tmp="${LOG_FILE}.prune.$$"
      if awk -v c="${cutoff}" '{ if (match($0,/[0-9]{4}-[0-9]{2}-[0-9]{2}/)) { if (substr($0,RSTART,10) >= c) print } else print }' \
           "${LOG_FILE}" > "${tmp}" 2>/dev/null; then
        mv "${tmp}" "${LOG_FILE}" 2>/dev/null || rm -f "${tmp}" 2>/dev/null
      else
        rm -f "${tmp}" 2>/dev/null || true
      fi
    fi
  fi
  touch "${LOG_FILE}" 2>/dev/null && chown "${INVOKING_USER}" "${LOG_FILE}" 2>/dev/null || true
  { echo; echo "===== started $(date '+%Y-%m-%d %H:%M:%S')  pid=$$  threshold=${BATTERY_THRESHOLD}%$( ((DRY_RUN)) && printf ' DRY-RUN')"; } >> "${LOG_FILE}" 2>/dev/null || true
else
  LOG_FILE=""   # logging disabled → log() writes to stdout only
fi

# --- Signal readers ---------------------------------------------------------

on_battery() {            # true when running on battery (not AC)
  pmset -g batt | grep -q "Battery Power"
}

lid_closed() {            # true when the clamshell is shut
  local s
  s="$(ioreg -r -k AppleClamshellState -d 4 2>/dev/null \
        | awk -F'= ' '/"AppleClamshellState"/{gsub(/[^A-Za-z]/,"",$2); print $2; exit}')"
  [[ "${s}" == "Yes" ]]
}

battery_pct() {           # e.g. "83"; empty if unreadable
  # grep -m1 (not head) avoids a SIGPIPE that pipefail would treat as failure.
  pmset -g batt | grep -Eom1 '[0-9]+%' | tr -d '%' || true
}

thermal_level() {         # "Nominal"/"Moderate"/"Heavy"/... ; empty if unreadable
  powermetrics -n 1 -i 200 --samplers thermal 2>/dev/null \
    | awk -F': ' '/Current pressure level/{print $2; exit}'
}

# Read separately from jq so a permissions/TCC failure cannot be mistaken for
# valid JSON with no activity. Callers choose their bounded fail-safe behavior.
read_transcript_tail() {
  TRANSCRIPT_TAIL=""
  TRANSCRIPT_TAIL="$(tail -n 5000 "$1" 2>/dev/null)"
}

parse_latest_event_epoch() {
  local transcript="$1" output status
  SESSION_LATEST_EVENT_EPOCH=0
  read_transcript_tail "${transcript}" || return 2
  output="$(printf '%s\n' "${TRANSCRIPT_TAIL}" | "${JQ_BIN}" -n -e -r '
      def event_epoch:
        (.timestamp // "")
        | if type == "string" and length > 0 then
            try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null
          else null end;
      [inputs | event_epoch | select(. != null)] | max // 0
    ' 2>/dev/null)"
  status=$?
  TRANSCRIPT_TAIL=""
  (( status == 0 )) || return 3
  SESSION_LATEST_EVENT_EPOCH="${output}"
}

# Check timestamped transcript content rather than trusting file mtime: Claude
# metadata maintenance can touch old JSONL files without recording agent work.
# Cache the parsed timestamp by path+mtime, but compare it with today's cutoff on
# every poll so an unchanged file still becomes inactive at the right time.
session_has_recent_event() {
  local transcript="$1" activity_now cutoff mtime cached_epoch="" i status
  [[ -x "${JQ_BIN}" ]] || return 0
  activity_now="${now:-$(date +%s)}"
  cutoff=$((activity_now - AGENT_GRACE_MINUTES * 60))
  mtime="$(stat -f '%m' "${transcript}" 2>/dev/null || true)"

  for ((i = 0; i < ${#RECENT_EVENT_CACHE_FILES[@]}; i++)); do
    if [[ "${RECENT_EVENT_CACHE_FILES[$i]}" == "${transcript}" &&
          "${RECENT_EVENT_CACHE_MTIMES[$i]}" == "${mtime}" ]]; then
      cached_epoch="${RECENT_EVENT_CACHE_EPOCHS[$i]}"
      break
    fi
  done

  if [[ -z "${cached_epoch}" ]]; then
    if parse_latest_event_epoch "${transcript}"; then
      cached_epoch="${SESSION_LATEST_EVENT_EPOCH}"
    else
      status=$?
      (( status == 2 )) && return 0  # unreadable recent candidate: bounded by find -mmin
      cached_epoch=-1               # malformed candidate: active only during recency window
    fi

    if [[ -n "${mtime}" ]]; then
      if (( ${#RECENT_EVENT_CACHE_FILES[@]} >= 100 )); then
        RECENT_EVENT_CACHE_FILES=()
        RECENT_EVENT_CACHE_MTIMES=()
        RECENT_EVENT_CACHE_EPOCHS=()
      fi
      RECENT_EVENT_CACHE_FILES+=("${transcript}")
      RECENT_EVENT_CACHE_MTIMES+=("${mtime}")
      RECENT_EVENT_CACHE_EPOCHS+=("${cached_epoch}")
    fi
  fi

  (( cached_epoch < 0 )) && return 0
  (( cached_epoch >= cutoff ))
}

# Parse the tail of one transcript as a small state machine. Claude records a
# tool_use followed by tool_result; Codex uses matching call_id values. A new
# turn/completion clears abandoned calls. The call's timestamp determines its
# deadline, so neither file touches nor an unchanged cache can extend it.
session_has_outstanding_tool() {
  local transcript="$1" status output activity_now mtime
  SESSION_PENDING_TOOL=""
  SESSION_PENDING_AGE_MINUTES=""
  SESSION_PENDING_UNTIL=0
  activity_now="${now:-$(date +%s)}"

  if [[ ! -x "${JQ_BIN}" ]]; then
    mtime="$(stat -f '%m' "${transcript}" 2>/dev/null || printf '0')"
    SESSION_PENDING_TOOL="unparseable transcript"
    SESSION_PENDING_UNTIL=$((mtime + OUTSTANDING_TOOL_MAX_MINUTES * 60))
    (( activity_now <= SESSION_PENDING_UNTIL ))
    return
  fi

  if ! read_transcript_tail "${transcript}"; then
    mtime="$(stat -f '%m' "${transcript}" 2>/dev/null || printf '0')"
    SESSION_PENDING_TOOL="unreadable transcript"
    SESSION_PENDING_UNTIL=$((mtime + OUTSTANDING_TOOL_MAX_MINUTES * 60))
    (( activity_now <= SESSION_PENDING_UNTIL ))
    return
  fi

  output="$(printf '%s\n' "${TRANSCRIPT_TAIL}" | "${JQ_BIN}" -n -e -r \
    --argjson now "${activity_now}" \
    --argjson fast_minutes "${FAST_TOOL_MAX_MINUTES}" \
    --argjson max_minutes "${OUTSTANDING_TOOL_MAX_MINUTES}" '
    def event_epoch:
      (.timestamp // "")
      | if type == "string" and length > 0 then
          try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null
        else null end;
    def waits_for_human:
      . == "AskUserQuestion" or . == "request_user_input";
    def long_running($name; $kind):
      (["Bash", "bash", "Task", "TaskOutput", "Agent", "Explore", "Workflow",
        "Monitor", "ScheduleWakeup", "exec", "exec_command", "wait", "wait_agent",
        "spawn_agent", "followup_task"] | index($name)) != null
      or ($kind | test("(^|_)shell_call$"));

    reduce inputs as $e (
      {pending: {}};
      ($e | event_epoch) as $at |
      if ($e.type == "event_msg" and
          (["task_started", "task_complete", "turn_aborted"] | index($e.payload.type))) then
        .pending = {}
      elif ($e.type == "assistant" and $e.message.role == "assistant") then
        reduce ($e.message.content[]? |
                select(.type == "tool_use" and .id != null and
                       ((.name // "") | waits_for_human | not))) as $call
          (. ; .pending[$call.id] = {
            name: ($call.name // "unknown"), kind: "claude_tool_use", at: $at,
            limit_minutes: (if long_running(($call.name // ""); "claude_tool_use")
                            then $max_minutes else $fast_minutes end)
          })
      elif ($e.type == "user" and $e.message.role == "user" and
            (($e.isMeta // false) | not) and
            (([$e.message.content[]? | select(.type == "tool_result")] | length) == 0)) then
        .pending = {}
      elif ($e.type == "user" and $e.message.role == "user") then
        reduce ($e.message.content[]? | select(.type == "tool_result" and .tool_use_id != null)) as $result
          (. ; del(.pending[$result.tool_use_id]))
      elif ($e.type == "response_item" and
            (($e.payload.type // "") | endswith("_call")) and
            $e.payload.call_id != null and
            (($e.payload.name // "") | waits_for_human | not)) then
        .pending[$e.payload.call_id] = {
          name: ($e.payload.name // $e.payload.type // "unknown"),
          kind: ($e.payload.type // "unknown"), at: $at,
          limit_minutes: (if long_running(($e.payload.name // ""); ($e.payload.type // ""))
                          then $max_minutes else $fast_minutes end)
        }
      elif ($e.type == "response_item" and
            ((($e.payload.type // "") | endswith("_call_output")) or
             $e.payload.type == "tool_search_output") and
            $e.payload.call_id != null) then
        del(.pending[$e.payload.call_id])
      elif ($e.type == "response_item" and $e.payload.type == "image_generation_call" and
            $e.payload.id != null and $e.payload.status == "generating") then
        .pending[$e.payload.id] = {
          name: "image_generation", kind: "image_generation_call", at: $at,
          limit_minutes: $fast_minutes
        }
      elif ($e.type == "response_item" and $e.payload.type == "image_generation_call" and
            $e.payload.id != null) then
        del(.pending[$e.payload.id])
      else . end
    )
    | [.pending | to_entries[]
       | .value + {id: .key}
       | select(.at != null)
       | . + {age_seconds: ($now - .at)}
       | select(.age_seconds >= 0)
       | select(.age_seconds <= (([.limit_minutes, $max_minutes] | min) * 60))]
    | sort_by(.at)
    | if length == 0 then false
      else .[0]
        | [.name, ((.age_seconds / 60) | floor),
           (.at + (([.limit_minutes, $max_minutes] | min) * 60))]
        | @tsv
      end
  ' 2>/dev/null)"
  status=$?
  TRANSCRIPT_TAIL=""
  if (( status == 0 )); then
    IFS=$'\t' read -r SESSION_PENDING_TOOL SESSION_PENDING_AGE_MINUTES SESSION_PENDING_UNTIL <<< "${output}"
    return 0
  fi
  (( status == 1 )) && return 1

  # Fail safe for malformed input, but never beyond the one-hour hard ceiling
  # measured from the file write that exposed the parse failure.
  mtime="$(stat -f '%m' "${transcript}" 2>/dev/null || printf '0')"
  SESSION_PENDING_TOOL="unparseable transcript"
  SESSION_PENDING_UNTIL=$((mtime + OUTSTANDING_TOOL_MAX_MINUTES * 60))
  (( activity_now <= SESSION_PENDING_UNTIL ))
}

# Track recently seen files in memory. The initial one-hour scan covers a daemon
# restart during a long tool call; once the machine is quiet, completed files
# are discarded so subsequent 15-second checks only revisit pending sessions.
TRACKED_SESSION_FILES=()
ACTIVITY_TRACKER_SEEDED=0
last_session_discovery=0
ACTIVE_PENDING_FILE=""
ACTIVE_PENDING_MTIME=""
ACTIVE_PENDING_UNTIL=0
ACTIVE_PENDING_REASON=""
ACTIVE_AGENT_REASON=""
RECENT_EVENT_CACHE_FILES=()
RECENT_EVENT_CACHE_MTIMES=()
RECENT_EVENT_CACHE_EPOCHS=()

track_session_file() {
  local candidate="$1" tracked
  for tracked in "${TRACKED_SESSION_FILES[@]:-}"; do
    [[ "${tracked}" == "${candidate}" ]] && return
  done
  TRACKED_SESSION_FILES+=("${candidate}")
}

agents_active() {
  local dir hit recent=0 mtime activity_now session_name
  activity_now="${now:-$(date +%s)}"
  ACTIVE_AGENT_REASON=""

  if (( ! ACTIVITY_TRACKER_SEEDED )); then
    for dir in "${CLAUDE_SESSIONS_DIR}" "${CODEX_SESSIONS_DIR}"; do
      [[ -d "${dir}" ]] || continue
      while IFS= read -r -d "" hit; do track_session_file "${hit}"; done \
        < <(find "${dir}" -name '*.jsonl' -mmin "-${OUTSTANDING_TOOL_MAX_MINUTES}" -print0 2>/dev/null)
    done
    ACTIVITY_TRACKER_SEEDED=1
    last_session_discovery="${activity_now}"
  fi

  if (( activity_now - last_session_discovery >= SESSION_DISCOVERY_INTERVAL_SECONDS )); then
    for dir in "${CLAUDE_SESSIONS_DIR}" "${CODEX_SESSIONS_DIR}"; do
      [[ -d "${dir}" ]] || continue
      while IFS= read -r -d "" hit; do
        track_session_file "${hit}"
        if session_has_recent_event "${hit}"; then
          recent=1
          session_name="$(basename "${hit}")"
          ACTIVE_AGENT_REASON="recent transcript event in ${session_name}"
        fi
      done < <(find "${dir}" -name '*.jsonl' -mmin "-${AGENT_GRACE_MINUTES}" -print0 2>/dev/null)
    done
    last_session_discovery="${activity_now}"
  else
    for dir in "${CLAUDE_SESSIONS_DIR}" "${CODEX_SESSIONS_DIR}"; do
      [[ -d "${dir}" ]] || continue
      while IFS= read -r -d "" hit; do
        if session_has_recent_event "${hit}"; then
          recent=1
          session_name="$(basename "${hit}")"
          ACTIVE_AGENT_REASON="recent transcript event in ${session_name}"
          break
        fi
      done < <(find "${dir}" -name '*.jsonl' -mmin "-${AGENT_GRACE_MINUTES}" -print0 2>/dev/null)
    done
  fi
  (( recent )) && return 0

  if [[ -n "${ACTIVE_PENDING_FILE}" && -f "${ACTIVE_PENDING_FILE}" &&
        "${activity_now}" -le "${ACTIVE_PENDING_UNTIL}" ]]; then
    mtime="$(stat -f '%m' "${ACTIVE_PENDING_FILE}" 2>/dev/null || true)"
    if [[ -n "${mtime}" && "${mtime}" == "${ACTIVE_PENDING_MTIME}" ]]; then
      ACTIVE_AGENT_REASON="${ACTIVE_PENDING_REASON}"
      return 0
    fi
  fi
  ACTIVE_PENDING_FILE=""
  ACTIVE_PENDING_MTIME=""
  ACTIVE_PENDING_UNTIL=0
  ACTIVE_PENDING_REASON=""

  for hit in "${TRACKED_SESSION_FILES[@]:-}"; do
    [[ -f "${hit}" ]] || continue
    [[ -n "$(find "${hit}" -mmin "-${OUTSTANDING_TOOL_MAX_MINUTES}" -print -quit 2>/dev/null)" ]] || continue
    if session_has_outstanding_tool "${hit}"; then
      ACTIVE_PENDING_FILE="${hit}"
      ACTIVE_PENDING_MTIME="$(stat -f '%m' "${hit}" 2>/dev/null || true)"
      ACTIVE_PENDING_UNTIL="${SESSION_PENDING_UNTIL}"
      session_name="$(basename "${hit}")"
      ACTIVE_PENDING_REASON="pending ${SESSION_PENDING_TOOL} tool (${SESSION_PENDING_AGE_MINUTES:-unknown}m) in ${session_name}"
      ACTIVE_AGENT_REASON="${ACTIVE_PENDING_REASON}"
      return 0
    fi
  done
  TRACKED_SESSION_FILES=()
  return 1
}

rank_of() {               # order the pressure levels; unknown/empty → 0 (fail-safe)
  case "$1" in
    Nominal)  echo 0 ;;
    Moderate) echo 1 ;;
    Heavy)    echo 2 ;;
    Trapping) echo 3 ;;
    Sleeping) echo 4 ;;
    *)        echo 0 ;;
  esac
}

# Read the OS's actual disablesleep value so we reconcile to reality rather
# than a cached memory of what we last set. Empty (key absent) means 0.
current_disablesleep() {
  local v
  v="$(pmset -g | awk '/SleepDisabled/{print $2; exit}')"
  echo "${v:-0}"
}

set_sleep() {             # $1: 1 = override sleep (stay awake), 0 = normal
  (( DRY_RUN )) && { log "[dry-run] would: pmset -a disablesleep $1"; return 0; }
  pmset -a disablesleep "$1"
}

# Print to stdout (short time, for live watching) AND append to the persistent
# logfile (full date, for later review). Logging must never abort the script.
log() {
  echo "$(date '+%-I:%M%p') — $*"
  [[ -n "${LOG_FILE}" ]] && printf '%s — %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

# Always restore normal sleep on exit (Ctrl-C / kill / natural end). Guarded so
# the EXIT+INT double-fire runs it once (also keeps the logfile tidy).
cleanup() {
  [[ -n "${_CLEANED:-}" ]] && return; _CLEANED=1
  echo
  echo "Exiting — restoring normal sleep behavior…"
  pmset -a disablesleep 0 2>/dev/null || true
  echo "Done — the Mac can sleep normally again."
  echo "===== stopped $(date '+%Y-%m-%d %H:%M:%S')  pid=$$ =====" >> "${LOG_FILE:-/dev/null}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- Main loop --------------------------------------------------------------

THERMAL_TRIGGER_RANK="$(rank_of "${THERMAL_TRIGGER_LEVEL}")"
hot_count=0
cooldown_until=0
last_logged=""

log "Watching. Holds this Mac awake while a Claude/Codex agent is recent or has a tool call within its ${FAST_TOOL_MAX_MINUTES}m/${OUTSTANDING_TOOL_MAX_MINUTES}m timeout AND battery ≥ ${BATTERY_THRESHOLD}% — any lid/power state, so the override is armed before the lid shuts. Forces sleep on release when lid-shut on battery, or on thermal ${THERMAL_TRIGGER_LEVEL}+ (x${HOT_READS_BEFORE_SLEEP}).$( ((DRY_RUN)) && printf ' [DRY-RUN]' )"

while true; do
  now="$(date +%s)"
  pct="$(battery_pct)"

  # Do we want to hold the Mac awake? An agent is working AND the battery is high
  # enough. Deliberately NOT gated on lid or power state: the override has to be
  # in force *before* the lid closes (in either power state), because macOS
  # clamshell-sleeps within a couple of seconds of the lid shutting — faster than
  # this poll — so a lid-gated design loses the race and sleeps before it can act.
  want_awake=0
  if [[ -n "${pct}" ]] && (( pct >= BATTERY_THRESHOLD )) && agents_active; then
    want_awake=1
  fi

  # Thermal safety net — only meaningful with the lid shut, where a closed laptop
  # in a bag can't shed heat. If we'd otherwise hold it awake but it's running hot
  # for HOT_READS_BEFORE_SLEEP reads, DROP the override AND force an immediate
  # sleep. (Dropping alone would eventually clamshell-sleep it, since the lid is
  # shut; forcing guarantees it sleeps *now* to cool down, and also covers the
  # docked case — external display — where a lid-shut Mac wouldn't sleep on its
  # own.) Suppressed during the post-sleep cooldown window. Only read powermetrics
  # when it could matter (want-awake + lid shut) to avoid needless wakeups/cost.
  level=""
  if (( want_awake )) && lid_closed && (( now >= cooldown_until )); then
    level="$(thermal_level)"
    if (( $(rank_of "${level:-}") >= THERMAL_TRIGGER_RANK )); then
      hot_count=$(( hot_count + 1 ))
    else
      hot_count=0
    fi
    if (( hot_count >= HOT_READS_BEFORE_SLEEP )); then
      log "thermal ${level} (x${hot_count}), lid shut — forcing sleep to cool down"
      thermal_sleep_succeeded=0
      if (( DRY_RUN )); then
        log "[dry-run] would: pmset -a disablesleep 0 && pmset sleepnow"
        thermal_sleep_succeeded=1
      else
        set_sleep 0                 # must drop the override first, or sleepnow is ignored
        if pmset sleepnow; then
          sleep 3                   # let it actually go down and come back
          thermal_sleep_succeeded=1
        else
          log "pmset sleepnow failed during thermal guard — will retry next poll"
          hot_count=$((HOT_READS_BEFORE_SLEEP - 1))
        fi
      fi
      if (( thermal_sleep_succeeded )); then
        hot_count=0
        cooldown_until=$(( $(date +%s) + COOLDOWN_SECONDS )) # measured from wake
      fi
      last_logged=""                # force a fresh state log next tick
      continue
    fi
  else
    hot_count=0
  fi

  # Decide the override state, plus whether release must recreate the suppressed
  # clamshell edge. Never force-sleep lid-open (someone may be using it) or on AC
  # (it may be driving a docked display). The cooldown suppresses DarkWake churn.
  force_release_sleep=0
  if (( want_awake )); then
    desired=1
    if on_battery; then power="battery"; else power="AC"; fi
    if lid_closed; then lid="lid shut"; else lid="lid open"; fi
    reason="${lid}, on ${power}, battery ${pct}% (≥${BATTERY_THRESHOLD}%), agent active${ACTIVE_AGENT_REASON:+ (${ACTIVE_AGENT_REASON})}${level:+, thermal ${level}}: keeping awake"
  else
    desired=0
    if [[ -n "${pct}" ]] && lid_closed && on_battery && (( now >= cooldown_until )); then
      force_release_sleep=1
    fi
    if [[ -z "${pct}" ]]; then
      reason="battery unreadable: normal macOS sleep"
    elif (( pct < BATTERY_THRESHOLD )); then
      reason="battery ${pct}% (<${BATTERY_THRESHOLD}%)"
    else
      reason="no active agent (no recent transcript or outstanding tool call)"
    fi
    if (( force_release_sleep )); then
      reason="${reason}, lid shut on battery: forcing sleep"
    else
      reason="${reason}: normal macOS sleep (hands off)"
    fi
  fi

  # Apply only when the OS isn't already there (also repairs external changes).
  [[ "$(current_disablesleep)" == "${desired}" ]] || set_sleep "${desired}"

  # Log only when the decision changes — and dedup on the *state*, not the exact
  # battery %, so a charging/discharging battery doesn't spam a line per 1%.
  # Stripping digits collapses "battery 95% (≥50%)" and "…96%…" to one key while
  # still distinguishing real changes (lid/power/agent/thermal, threshold cross).
  statekey="${reason//[0-9]/}"
  if [[ "${statekey}" != "${last_logged}" ]]; then
    log "${reason}"
    last_logged="${statekey}"
  fi

  if (( force_release_sleep )); then
    release_sleep_succeeded=0
    if (( DRY_RUN )); then
      log "[dry-run] would: pmset sleepnow"
      release_sleep_succeeded=1
    elif pmset sleepnow; then
      sleep 3
      release_sleep_succeeded=1
    else
      log "pmset sleepnow failed — will retry next poll"
    fi
    if (( release_sleep_succeeded )); then
      cooldown_until=$(( $(date +%s) + COOLDOWN_SECONDS ))
      last_logged=""
    fi
  fi

  sleep "${POLL_INTERVAL_SECONDS}"
done
