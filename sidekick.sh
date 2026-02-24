#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Sidekick – autonomous repo task runner
# ─────────────────────────────────────────────────────────────────────────────
# Usage:  ./run.sh
#
# Environment variables (optional, will use defaults for now):
#   SIDEKICK_CONTROL_PLANE_URL – base URL for the control plane API
#   SIDEKICK_API_TOKEN         – bearer token for control plane auth
#   SIDEKICK_ID                – unique id for this sidekick instance
#   SIDEKICK_REPOS_DIR         – directory to clone repos into
#   SIDEKICK_POLL_INTERVAL     – seconds between task polls (default: 10)
#   SIDEKICK_AGENT             – coding agent to use: codex | opencode | claude (default: codex)
#   SIDEKICK_PID_FILE          – path to pid file (default: ./sidekick.pid)
#   SIDEKICK_LOG_FILE          – path to log file (default: ./sidekick.log)
# ─────────────────────────────────────────────────────────────────────────────

CONTROL_PLANE_URL="${SIDEKICK_CONTROL_PLANE_URL:-http://localhost:3000/api}"
API_TOKEN="${SIDEKICK_API_TOKEN:-mock-token}"
SIDEKICK_ID="${SIDEKICK_ID:-sidekick-001}"
REPOS_DIR="${SIDEKICK_REPOS_DIR:-$(pwd)/repos}"
POLL_INTERVAL="${SIDEKICK_POLL_INTERVAL:-10}"
AGENT="${SIDEKICK_AGENT:-codex}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="${SIDEKICK_PID_FILE:-${SCRIPT_DIR}/sidekick.pid}"
LOG_FILE="${SIDEKICK_LOG_FILE:-${SCRIPT_DIR}/sidekick.log}"

# ─── sidekick identity (populated by register_sidekick) ─────────────────────
SIDEKICK_NAME="sidekick"       # fallback until registration
SIDEKICK_PURPOSE=""
STARTED_AT=$(date +%s)
TASKS_COMPLETED=0
TASKS_FAILED=0
CURRENT_STATUS="booting"
CURRENT_RUN_ID=""
CURRENT_TASK_ID=""
DETACH=0
NO_DETACH=0
ACTION="run"
LOG_JSONL=0

# ─── logging (always to stderr so it never pollutes captured stdout) ─────────
json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

emit_log() {
  local level="$1" event="$2" message="$3"
  local ts
  ts=$(date -Iseconds)
  local rendered_line

  if [[ ${LOG_JSONL} -eq 1 ]]; then
    rendered_line=$(printf '{"ts":"%s","level":"%s","event":"%s","sidekick_id":"%s","sidekick_name":"%s","status":"%s","message":"%s"}' \
      "$(json_escape "$ts")" \
      "$(json_escape "$level")" \
      "$(json_escape "$event")" \
      "$(json_escape "$SIDEKICK_ID")" \
      "$(json_escape "$SIDEKICK_NAME")" \
      "$(json_escape "$CURRENT_STATUS")" \
      "$(json_escape "$message")")
  else
    rendered_line=$(printf '[%s] %s %s' "${SIDEKICK_NAME}" "$(date '+%H:%M:%S')" "${message}")
  fi

  printf '%s\n' "$rendered_line" >&2
  send_run_log "$rendered_line"
}

log()      { emit_log "info"  "runtime" "$*"; }
log_ok()   { emit_log "info"  "runtime" "$*"; }
log_warn() { emit_log "warn"  "runtime" "$*"; }
log_err()  { emit_log "error" "runtime" "$*"; }

send_run_log() {
  local line="$1"

  if [[ -z "${CURRENT_TASK_ID}" || -z "${CURRENT_RUN_ID}" ]]; then
    return 0
  fi

  local payload
  payload=$(jq -cn \
    --arg id "${CURRENT_TASK_ID}" \
    --arg runId "${CURRENT_RUN_ID}" \
    --arg message "${line}" \
    '{id: $id, runId: $runId, message: $message}')

  curl -sf -X POST "${CONTROL_PLANE_URL}/sidekick/task/log" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${payload}" > /dev/null 2>&1 || true
}

log_status() {
  local task_id="$1" status="$2" detail="${3:-}"
  emit_log "info" "task_status" "task=${task_id} status=${status} detail=${detail}"

  if [[ -z "${CURRENT_RUN_ID}" ]]; then
    log_warn "Missing run id for task status update: task=${task_id} status=${status}"
    return 0
  fi

  curl -sf -X POST "${CONTROL_PLANE_URL}/sidekick/task/status" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"${task_id}\",\"runId\":\"${CURRENT_RUN_ID}\",\"status\":\"${status}\",\"message\":\"${detail}\"}" \
    > /dev/null || log_warn "Status update failed to send"
}

usage() {
  cat <<EOF
Usage:
  ./run.sh [run] [-d|--detach] [--log-file PATH]
  ./run.sh status
  ./run.sh stop

Options:
  -d, --detach       Run in background with minimal output
      --no-detach    Internal flag used for detached re-exec
      --log-file     Log file path in detached mode (default: ${LOG_FILE})
  -h, --help         Show this help
EOF
}

read_pid_file() {
  [[ -f "${PID_FILE}" ]] || return 1
  local pid
  pid=$(cat "${PID_FILE}" 2>/dev/null || true)
  [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] || return 1
  echo "${pid}"
}

is_running() {
  local pid
  pid=$(read_pid_file) || return 1
  kill -0 "${pid}" 2>/dev/null
}

cleanup_pid_file() {
  local pid
  pid=$(read_pid_file || true)
  if [[ -n "${pid}" && "${pid}" == "$$" ]]; then
    rm -f "${PID_FILE}"
  fi
}

write_pid_file() {
  mkdir -p "$(dirname "${PID_FILE}")"
  echo "$$" > "${PID_FILE}"
}

ensure_single_instance() {
  local existing_pid
  existing_pid=$(read_pid_file || true)

  if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
    if [[ "${existing_pid}" != "$$" ]]; then
      echo "sidekick already running (pid ${existing_pid})" >&2
      exit 1
    fi
  fi

  write_pid_file
  trap cleanup_pid_file EXIT INT TERM
}

start_detached() {
  if is_running; then
    local existing_pid
    existing_pid=$(read_pid_file)
    echo "sidekick already running (pid ${existing_pid})"
    return 0
  fi

  mkdir -p "$(dirname "${LOG_FILE}")"
  nohup "$0" --no-detach run --log-file "${LOG_FILE}" >"${LOG_FILE}" 2>&1 < /dev/null &
  local pid=$!
  echo "${pid}" > "${PID_FILE}"
  sleep 0.2

  if kill -0 "${pid}" 2>/dev/null; then
    echo "sidekick started in background (pid ${pid})"
    echo "logs: ${LOG_FILE}"
    return 0
  fi

  rm -f "${PID_FILE}"
  echo "sidekick failed to start; check logs: ${LOG_FILE}" >&2
  return 1
}

status_sidekick() {
  if is_running; then
    local pid
    pid=$(read_pid_file)
    echo "sidekick is running (pid ${pid})"
    return 0
  fi

  if [[ -f "${PID_FILE}" ]]; then
    echo "sidekick is not running (stale pid file: ${PID_FILE})"
    return 1
  fi

  echo "sidekick is not running"
  return 1
}

stop_sidekick() {
  local pid
  pid=$(read_pid_file || true)

  if [[ -z "${pid}" ]]; then
    echo "sidekick is not running"
    rm -f "${PID_FILE}"
    return 0
  fi

  if ! kill -0 "${pid}" 2>/dev/null; then
    echo "sidekick is not running (removing stale pid file)"
    rm -f "${PID_FILE}"
    return 0
  fi

  kill "${pid}" 2>/dev/null || true
  for _ in {1..100}; do
    if ! kill -0 "${pid}" 2>/dev/null; then
      rm -f "${PID_FILE}"
      echo "sidekick stopped"
      return 0
    fi
    sleep 0.1
  done

  kill -9 "${pid}" 2>/dev/null || true
  for _ in {1..20}; do
    if ! kill -0 "${pid}" 2>/dev/null; then
      rm -f "${PID_FILE}"
      echo "sidekick stopped"
      return 0
    fi
    sleep 0.1
  done

  echo "sidekick did not stop in time (pid ${pid})" >&2
  return 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--detach)
        DETACH=1
        ;;
      --no-detach)
        NO_DETACH=1
        ;;
      --log-file)
        if [[ $# -lt 2 ]]; then
          echo "--log-file requires a path" >&2
          exit 1
        fi
        LOG_FILE="$2"
        shift
        ;;
      run|status|stop)
        ACTION="$1"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

# ─── preflight: check required tools ────────────────────────────────────────
preflight() {
  # Core tools every agent needs
  local core_tools=(git gh jq curl)
  local missing=()
  for tool in "${core_tools[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
      missing+=("$tool")
    fi
  done

  # Validate the chosen agent and check its binary
  case "$AGENT" in
    codex|opencode|claude)
      if ! command -v "$AGENT" &>/dev/null; then
        missing+=("$AGENT")
      fi
      ;;
    *)
      log_err "Unknown agent '${AGENT}'. Choose one of: codex, opencode, claude"
      exit 1
      ;;
  esac

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_err "Missing required tools: ${missing[*]}"
    log_err "Install them and try again."
    exit 1
  fi

  log_ok "All required tools found (${core_tools[*]}, agent=${AGENT})"
}

# ─── register sidekick with the control plane ───────────────────────────────
# Calls the control plane to announce this sidekick and get back its identity.
# The response tells us our name, purpose and any config overrides.
register_sidekick() {
  local registration_json

  registration_json=$(curl -sf -X POST "${CONTROL_PLANE_URL}/sidekick/register" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"agent\":\"${AGENT}\",\"hostname\":\"$(hostname)\",\"status\":\"${CURRENT_STATUS}\"}" \
  ) || { log_warn "Could not register with control plane (unreachable or unauthorized) — using defaults"; return; }

  # Parse identity fields
  SIDEKICK_NAME=$(echo "$registration_json" | jq -r '.name // "sidekick"')
  SIDEKICK_PURPOSE=$(echo "$registration_json" | jq -r '.purpose // "unknown"')
  SIDEKICK_PROMPT=$(echo "$registration_json" | jq -r '.prompt // ""')

  log_ok "Registered with control plane"
  log "  id   : ${SIDEKICK_ID}"
  log "  name : ${SIDEKICK_NAME}"
  log "  purpose : ${SIDEKICK_PURPOSE}"
  log "  prompt : ${SIDEKICK_PROMPT}"
}

# ─── heartbeat ──────────────────────────────────────────────────────────────
# Sends a pulse to the control plane before every sleep cycle so it knows
# this sidekick is still alive and what it's up to.
heartbeat() {
  local now uptime_secs uptime_human
  now=$(date +%s)
  uptime_secs=$(( now - STARTED_AT ))

  # Human-friendly uptime
  local h m s
  h=$(( uptime_secs / 3600 ))
  m=$(( (uptime_secs % 3600) / 60 ))
  s=$(( uptime_secs % 60 ))
  uptime_human=$(printf '%02dh%02dm%02ds' "$h" "$m" "$s")

  emit_log "info" "heartbeat" "uptime=${uptime_human} tasks_completed=${TASKS_COMPLETED} tasks_failed=${TASKS_FAILED} agent=${AGENT}"

  curl -sf -X POST "${CONTROL_PLANE_URL}/sidekick/heartbeat" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"status\": \"${CURRENT_STATUS}\"}" > /dev/null || log_warn "Heartbeat failed to send"
}

# ─── reserve next task from the control plane ───────────────────────────────
reserve_task() {
  local response http_code body
  response=$(curl -sf -w "\n%{http_code}" -X POST "${CONTROL_PLANE_URL}/sidekick/task/reserve" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d '{}') || { echo ""; return; }

  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" == "204" || -z "$body" ]]; then
    echo ""
    return
  fi

  echo "$body"
}

validate_task_fields() {
  local task_id="$1" run_id="$2" repo_url="$3" repo_name="$4" base_branch="$5" branch="$6" instructions="$7" pr_title="$8"

  if [[ -z "${task_id}" || -z "${run_id}" || -z "${repo_url}" || -z "${repo_name}" || -z "${base_branch}" || -z "${branch}" || -z "${instructions}" || -z "${pr_title}" ]]; then
    return 1
  fi

  if [[ "${run_id}" == "null" || "${repo_url}" == "null" || "${repo_name}" == "null" || "${base_branch}" == "null" || "${branch}" == "null" || "${instructions}" == "null" || "${pr_title}" == "null" ]]; then
    return 1
  fi

  return 0
}

# ─── ensure repo is cloned & up to date ─────────────────────────────────────
# Prints ONLY the repo path to stdout. All status logging goes to stderr.
ensure_repo() {
  local repo_url="$1" repo_name="$2" base_branch="$3" repo_path="${REPOS_DIR}/${repo_name}"

  if [[ -d "$repo_path/.git" ]]; then
    log "Repo ${repo_name} already cloned, fetching latest…"
    git -C "$repo_path" fetch --all --prune -q || return 1
  else
    log "Cloning ${repo_url} → ${repo_path}"
    git clone -q "$repo_url" "$repo_path" >&2 || return 1
  fi

  # Make sure we're on the requested base branch and clean.
  git -C "$repo_path" checkout "$base_branch" -q 2>/dev/null || return 1
  git -C "$repo_path" reset --hard "origin/${base_branch}" -q || return 1
  git -C "$repo_path" clean -fd -q || return 1

  # This is the ONLY thing that goes to stdout
  echo "$repo_path"
}

# ─── create (or reset) the task branch ──────────────────────────────────────
create_branch() {
  local repo_path="$1" branch="$2"

  # Delete local branch if it already exists (clean slate)
  git -C "$repo_path" branch -D "$branch" 2>/dev/null || true

  git -C "$repo_path" checkout -b "$branch" -q || return 1
  log "Created branch ${branch}"
}

# ─── agent runners ──────────────────────────────────────────────────────────
# Each runner cds into the repo and executes the agent with the given prompt.
# They all swallow exit codes (|| true) — we detect success by whether files
# actually changed later in commit_and_push.

run_agent_codex() {
  local repo_path="$1" instructions="$2"
  local output
  if [[ ${LOG_JSONL} -eq 1 ]]; then
    output=$(cd "$repo_path" && echo "$instructions" | codex exec --yolo 2>&1) || true
  else
    output=$(cd "$repo_path" && echo "$instructions" \
      | codex exec --yolo 2>&1 \
      | tee /dev/stderr) || true
  fi
  echo "$output"
}

run_agent_opencode() {
  local repo_path="$1" instructions="$2"
  local output
  if [[ ${LOG_JSONL} -eq 1 ]]; then
    output=$(cd "$repo_path" && opencode run "$instructions" 2>&1) || true
  else
    output=$(cd "$repo_path" \
      && opencode run "$instructions" 2>&1 \
      | tee /dev/stderr) || true
  fi
  echo "$output"
}

run_agent_claude() {
  local repo_path="$1" instructions="$2"
  # claude --dangerously-skip-permissions -p is the full-auto piped equivalent
  local output
  if [[ ${LOG_JSONL} -eq 1 ]]; then
    output=$(cd "$repo_path" && echo "$instructions" | claude --dangerously-skip-permissions -p 2>&1) || true
  else
    output=$(cd "$repo_path" \
      && echo "$instructions" \
      | claude --dangerously-skip-permissions -p 2>&1 \
      | tee /dev/stderr) || true
  fi
  echo "$output"
}

# ─── dispatch to the active agent ───────────────────────────────────────────
run_agent() {
  local repo_path="$1" instructions="$2"

  if [[ ! -d "${repo_path}/.git" ]]; then
    log_err "Repository path is not a git repository: ${repo_path}"
    return 1
  fi

  log "Running agent=${AGENT}…"
  log "  prompt: \"${instructions}\""

  local output
  output=$(run_agent_"${AGENT}" "$repo_path" "$instructions")

  if [[ ${LOG_JSONL} -eq 1 && -n "$output" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && emit_log "info" "agent_output" "$line"
    done <<< "$output"
  fi

  if [[ -z "$output" ]]; then
    log_warn "Agent produced no output"
  fi

  return 0
}

# ─── commit, push, and open a PR ────────────────────────────────────────────
commit_and_push() {
  local repo_path="$1" branch="$2" pr_title="$3"

  # Check if the agent actually changed anything
  if git -C "$repo_path" diff --quiet && git -C "$repo_path" diff --cached --quiet; then
    if [[ -z "$(git -C "$repo_path" ls-files --others --exclude-standard)" ]]; then
      log_warn "No changes detected – nothing to commit"
      return 1
    fi
  fi

  git -C "$repo_path" add -A || return 1
  git -C "$repo_path" commit -m "${pr_title}" -q || return 1
  log_ok "Committed changes"

  git -C "$repo_path" push -u origin "$branch" -q || return 1
  log_ok "Pushed branch ${branch}"

  # Open a PR via gh
  (cd "$repo_path" && gh pr create \
    --title "$pr_title" \
    --head "$branch" \
    --fill-first 2>/dev/null) && log_ok "Pull request created" \
    || log_warn "Could not create PR (may already exist)"
}

# ─── process a single task ──────────────────────────────────────────────────
process_task() {
  local task_json="$1"

  local task_id run_id task_title repo_url repo_name base_branch branch instructions pr_title
  task_id=$(echo "$task_json"      | jq -r '.taskId // empty')
  run_id=$(echo "$task_json"       | jq -r '.runId // empty')
  task_title=$(echo "$task_json"   | jq -r '.title // empty')
  repo_url=$(echo "$task_json"     | jq -r '.repoUrl // empty')
  repo_name=$(echo "$task_json"    | jq -r '.repoName // empty')
  base_branch=$(echo "$task_json"  | jq -r '.baseBranch // empty')
  branch=$(echo "$task_json"       | jq -r '.executionBranch // empty')
  instructions=$(echo "$task_json" | jq -r '.instructions // empty')
  pr_title=$(echo "$task_json"     | jq -r '.prTitle // empty')

  CURRENT_RUN_ID="${run_id}"
  CURRENT_TASK_ID="${task_id}"

  if ! validate_task_fields "${task_id}" "${run_id}" "${repo_url}" "${repo_name}" "${base_branch}" "${branch}" "${instructions}" "${pr_title}"; then
    log_err "Task payload is missing required execution fields; cannot process"
    log_status "${task_id}" "failed" "invalid task payload"
    TASKS_FAILED=$(( TASKS_FAILED + 1 ))
    CURRENT_STATUS="idle"
    CURRENT_RUN_ID=""
    CURRENT_TASK_ID=""
    return
  fi

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Processing task ${task_id}"
  log "  repo:   ${repo_name} (${repo_url})"
  log "  title:  ${task_title}"
  log "  base:   ${base_branch}"
  log "  branch: ${branch}"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  CURRENT_STATUS="working"
  log_status "$task_id" "running" "started"

  # 1) Clone / update repo
  local repo_path
  repo_path=$(ensure_repo "$repo_url" "$repo_name" "$base_branch") || {
    log_err "Failed to clone/update repo"
    log_status "$task_id" "failed" "could not clone repo"
    TASKS_FAILED=$(( TASKS_FAILED + 1 ))
    CURRENT_STATUS="idle"
    CURRENT_RUN_ID=""
    CURRENT_TASK_ID=""
    return
  }
  log_status "$task_id" "running" "repo ready"

  # 2) Create branch
  create_branch "$repo_path" "$branch" || {
    log_err "Failed to create branch"
    log_status "$task_id" "failed" "could not create branch"
    TASKS_FAILED=$(( TASKS_FAILED + 1 ))
    CURRENT_STATUS="idle"
    CURRENT_RUN_ID=""
    CURRENT_TASK_ID=""
    return
  }

  # 3) Run the coding agent
  if run_agent "$repo_path" "$instructions"; then
    log_ok "Agent (${AGENT}) finished"
    log_status "$task_id" "running" "agent complete"
  else
    log_err "Agent (${AGENT}) exited with an error"
    log_status "$task_id" "failed" "${AGENT} returned non-zero"
    TASKS_FAILED=$(( TASKS_FAILED + 1 ))
    CURRENT_STATUS="idle"
    CURRENT_RUN_ID=""
    CURRENT_TASK_ID=""
    return
  fi

  # 4) Commit + push + PR
  if commit_and_push "$repo_path" "$branch" "$pr_title"; then
    log_ok "Task ${task_id} completed"
    log_status "$task_id" "succeeded" "PR opened"
    TASKS_COMPLETED=$(( TASKS_COMPLETED + 1 ))
  else
    log_warn "Task ${task_id} finished but no changes were made"
    log_status "$task_id" "succeeded" "no changes"
    TASKS_COMPLETED=$(( TASKS_COMPLETED + 1 ))
  fi

  CURRENT_STATUS="idle"
  CURRENT_RUN_ID=""
  CURRENT_TASK_ID=""
}

# ─── main loop ──────────────────────────────────────────────────────────────
main() {
  log "Sidekick control plane worker is online"

  preflight
  register_sidekick
  mkdir -p "$REPOS_DIR"

  log "Repos dir    : ${REPOS_DIR}"
  log "Poll interval: ${POLL_INTERVAL}s"
  log "Agent        : ${AGENT}"
  log "Control plane: ${CONTROL_PLANE_URL}"

  CURRENT_STATUS="idle"

  while true; do
    local task_json
    task_json=$(reserve_task)

    if [[ -z "$task_json" || "$task_json" == "null" ]]; then
      heartbeat
      log "No tasks available – sleeping ${POLL_INTERVAL}s…"
      sleep "$POLL_INTERVAL"
      continue
    fi

    process_task "$task_json"

    # Heartbeat + breather between tasks
    heartbeat
    sleep 2
  done
}

# ─── go ──────────────────────────────────────────────────────────────────────
parse_args "$@"

case "${ACTION}" in
  status)
    status_sidekick
    ;;
  stop)
    stop_sidekick
    ;;
  run)
    if [[ ${DETACH} -eq 1 && ${NO_DETACH} -eq 0 ]]; then
      start_detached
      exit $?
    fi
    if [[ ${NO_DETACH} -eq 1 ]]; then
      LOG_JSONL=1
    fi
    ensure_single_instance
    main
    ;;
esac
