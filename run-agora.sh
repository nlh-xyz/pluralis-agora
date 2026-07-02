#!/usr/bin/env bash
#
# run-agora.sh — reusable auto-runner for a Pluralis Agora node.
#
# Bootstraps the agora repo, then runs `agora_cli.py start` in a supervise loop:
# the network gates max participants, so on rejection we retry every
# AGORA_RETRY_INTERVAL seconds until we're admitted; once training, any later
# exit is restarted the same way.
#
# Config comes from environment variables (a local .env is auto-sourced).
# See .env.example for the full list.

set -uo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-source .env (next to this script) if present.
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

HF_TOKEN="${HF_TOKEN:-}"
AGORA_EMAIL="${AGORA_EMAIL:-}"
AGORA_HOST_PORT="${AGORA_HOST_PORT:-}"
AGORA_ANNOUNCE_PORT="${AGORA_ANNOUNCE_PORT:-}"
AGORA_GPU_ID="${AGORA_GPU_ID:-0}"
AGORA_DIR="${AGORA_DIR:-${SCRIPT_DIR}/agora}"
AGORA_RETRY_INTERVAL="${AGORA_RETRY_INTERVAL:-10}"
AGORA_QUEUE_BACKOFF="${AGORA_QUEUE_BACKOFF:-90}"
AGORA_REPO_URL="${AGORA_REPO_URL:-https://github.com/PluralisResearch/agora}"

# Output patterns used to classify why a run ended, checked in order per attempt.
# FATAL: non-retryable — a wrong port / bad token / ineligibility never recovers,
# so we fail fast instead of looping forever.
FATAL_MARKERS='Port [0-9]+ is closed|Invalid HuggingFace token|Verification failed|not eligible'
# QUEUE: we already hold a slot in the auth queue — back off longer, keep the key.
QUEUE_MARKERS='already in the authorization queue'
# RETRY: the network is at capacity — poll again after the normal interval.
RETRY_MARKERS='Maximum number of active nodes reached'
# JOIN: admitted to the run. Anything after this is a live session that died.
JOIN_MARKERS='Access granted'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { printf '%s [run-agora] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Signal handling — stop the child cleanly on Ctrl+C / TERM
# ---------------------------------------------------------------------------
CHILD_PID=""
STOP=0
cleanup() {
  STOP=1
  if [[ -n "${CHILD_PID}" ]] && kill -0 "${CHILD_PID}" 2>/dev/null; then
    log "signal received — stopping agora (pid ${CHILD_PID})..."
    kill "${CHILD_PID}" 2>/dev/null
    wait "${CHILD_PID}" 2>/dev/null
  fi
  log "supervisor stopped."
  exit 0
}
trap cleanup INT TERM

# Sleep that a trapped signal can interrupt immediately. A foreground `sleep`
# defers traps until it returns (a plain `kill` would then hang up to the full
# backoff); backgrounding it and `wait`-ing lets INT/TERM fire at once.
interruptible_sleep() {
  sleep "$1" &
  CHILD_PID=$!
  wait "${CHILD_PID}" 2>/dev/null
  CHILD_PID=""
}

# ---------------------------------------------------------------------------
# Pre-flight — fail fast on non-retryable problems (before the loop)
# ---------------------------------------------------------------------------
preflight() {
  [[ -n "${HF_TOKEN}" ]] || die "HF_TOKEN is not set. Export it or add it to .env (see .env.example)."

  command -v git >/dev/null 2>&1 || die "git not found. Install git and re-run."

  if command -v python3.11 >/dev/null 2>&1; then
    PYTHON_BIN="python3.11"
  else
    die "python3.11 not found. Pluralis Agora requires Python 3.11.
     Install it (e.g. 'sudo apt install python3.11' on Debian/Ubuntu, or via pyenv) and re-run."
  fi

  [[ "${AGORA_GPU_ID}" =~ ^[0-9]+$ ]] || die "AGORA_GPU_ID must be an integer (got '${AGORA_GPU_ID}')."
  [[ "${AGORA_RETRY_INTERVAL}" =~ ^[0-9]+$ ]] || die "AGORA_RETRY_INTERVAL must be an integer seconds value."
  [[ "${AGORA_QUEUE_BACKOFF}" =~ ^[0-9]+$ ]] || die "AGORA_QUEUE_BACKOFF must be an integer seconds value."
}

# ---------------------------------------------------------------------------
# Bootstrap — clone repo if missing (idempotent, no auto-update)
# ---------------------------------------------------------------------------
bootstrap() {
  if [[ -d "${AGORA_DIR}/.git" ]]; then
    log "using existing agora clone at ${AGORA_DIR} (not auto-updating)."
  elif [[ -e "${AGORA_DIR}" ]]; then
    die "${AGORA_DIR} exists but is not a git clone. Remove it or set AGORA_DIR elsewhere."
  else
    log "cloning ${AGORA_REPO_URL} -> ${AGORA_DIR} ..."
    git clone "${AGORA_REPO_URL}" "${AGORA_DIR}" || die "git clone failed."
  fi

  [[ -f "${AGORA_DIR}/agora_cli.py" ]] || die "agora_cli.py not found in ${AGORA_DIR}."
}

# ---------------------------------------------------------------------------
# Build the argv for `agora_cli.py start`
# ---------------------------------------------------------------------------
build_args() {
  # NAT'd hosts (e.g. Vast.ai) map the internal host_port to a different external
  # port. If the announce port wasn't set explicitly, auto-detect it from the
  # provider's VAST_TCP_PORT_<host_port> env var so peers can reach us.
  if [[ -z "${AGORA_ANNOUNCE_PORT}" && -n "${AGORA_HOST_PORT}" ]]; then
    local vast_var="VAST_TCP_PORT_${AGORA_HOST_PORT}"
    if [[ -n "${!vast_var:-}" ]]; then
      AGORA_ANNOUNCE_PORT="${!vast_var}"
      log "auto-detected announce port ${AGORA_ANNOUNCE_PORT} from ${vast_var}."
    fi
  fi
  # On a NAT provider with no resolvable announce port, warn — the default
  # (host_port) will not be reachable from outside and auth will fail.
  if [[ -z "${AGORA_ANNOUNCE_PORT}" ]] && compgen -v | grep -q '^VAST_'; then
    log "WARNING: NAT provider detected but no announce port resolved. Set AGORA_ANNOUNCE_PORT to the externally-mapped port or the node may be unreachable."
  fi

  ARGS=(start --skip_input --gpu_id "${AGORA_GPU_ID}" --token "${HF_TOKEN}")
  [[ -n "${AGORA_EMAIL}" ]]          && ARGS+=(--email "${AGORA_EMAIL}")
  [[ -n "${AGORA_HOST_PORT}" ]]      && ARGS+=(--host_port "${AGORA_HOST_PORT}")
  [[ -n "${AGORA_ANNOUNCE_PORT}" ]]  && ARGS+=(--announce_port "${AGORA_ANNOUNCE_PORT}")
}

# ---------------------------------------------------------------------------
# Supervise loop
# ---------------------------------------------------------------------------
supervise() {
  local run_log attempt=0 rc delay
  run_log="$(mktemp -t agora-run.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '${run_log}'; cleanup" INT TERM

  log "starting supervisor: gpu=${AGORA_GPU_ID} host_port=${AGORA_HOST_PORT:-default} announce_port=${AGORA_ANNOUNCE_PORT:-default} retry=${AGORA_RETRY_INTERVAL}s queue_backoff=${AGORA_QUEUE_BACKOFF}s"

  # Run from the client dir (read-only for us; the client's integrity check must
  # see an unmodified tree). Nothing after this depends on the original cwd.
  cd "${AGORA_DIR}" || die "cannot cd into ${AGORA_DIR}."

  while [[ "${STOP}" -eq 0 ]]; do
    attempt=$((attempt + 1))
    : > "${run_log}"
    log "=== attempt #${attempt}: ${PYTHON_BIN} agora_cli.py ${ARGS[*]//${HF_TOKEN}/<HF_TOKEN>} ==="

    # CHILD_PID is the client itself (not tee), so the trap kills the real
    # process on Ctrl+C and rc below is the client's own exit code. Output is
    # mirrored to the terminal and captured for post-mortem classification.
    "${PYTHON_BIN}" agora_cli.py "${ARGS[@]}" > >(tee "${run_log}") 2>&1 &
    CHILD_PID=$!
    wait "${CHILD_PID}"
    rc=$?
    CHILD_PID=""

    [[ "${STOP}" -eq 1 ]] && break

    # Classify the exit, checked in priority order. FATAL never recovers.
    if grep -Eq "${FATAL_MARKERS}" "${run_log}"; then
      local last; last="$(tail -n 5 "${run_log}" 2>/dev/null)"
      rm -f "${run_log}"
      die "non-retryable error (rc=${rc}). Fix config and re-run. Last lines:
${last}"
    elif grep -Eq "${QUEUE_MARKERS}" "${run_log}"; then
      # Already holding a queue slot — back off longer and keep our identity key.
      delay="${AGORA_QUEUE_BACKOFF}"
      log "already in the authorization queue (rc=${rc}) — waiting ${delay}s (keeping identity key) ..."
    elif grep -Eq "${RETRY_MARKERS}" "${run_log}"; then
      delay="${AGORA_RETRY_INTERVAL}"
      log "gate full (rejected, rc=${rc}) — retry #$((attempt + 1)) in ${delay}s ..."
    elif grep -Eq "${JOIN_MARKERS}" "${run_log}"; then
      delay="${AGORA_RETRY_INTERVAL}"
      log "session ended after joining (rc=${rc}) — restarting in ${delay}s ..."
    else
      delay="${AGORA_RETRY_INTERVAL}"
      log "exited before joining (rc=${rc}) — retry in ${delay}s. Last lines:"
      tail -n 5 "${run_log}" | sed 's/^/    | /' >&2
    fi

    interruptible_sleep "${delay}"
  done

  rm -f "${run_log}"
}

# ---------------------------------------------------------------------------
main() {
  preflight
  bootstrap
  build_args
  supervise
}

main "$@"
