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
AGORA_REPO_URL="${AGORA_REPO_URL:-https://github.com/PluralisResearch/agora}"

# Output patterns used to classify why a run ended.
REJECT_MARKERS='Maximum number of active nodes reached|Authorization failed'
JOIN_MARKERS='Sync phase|\[TRAINING\]|Training|batch'

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
  ARGS=(start --skip_input --gpu_id "${AGORA_GPU_ID}" --token "${HF_TOKEN}")
  [[ -n "${AGORA_EMAIL}" ]]          && ARGS+=(--email "${AGORA_EMAIL}")
  [[ -n "${AGORA_HOST_PORT}" ]]      && ARGS+=(--host_port "${AGORA_HOST_PORT}")
  [[ -n "${AGORA_ANNOUNCE_PORT}" ]]  && ARGS+=(--announce_port "${AGORA_ANNOUNCE_PORT}")
}

# ---------------------------------------------------------------------------
# Supervise loop
# ---------------------------------------------------------------------------
supervise() {
  local run_log attempt=0 rc joined
  run_log="$(mktemp -t agora-run.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '${run_log}'; cleanup" INT TERM

  log "starting supervisor: gpu=${AGORA_GPU_ID} host_port=${AGORA_HOST_PORT:-default} announce_port=${AGORA_ANNOUNCE_PORT:-default} retry=${AGORA_RETRY_INTERVAL}s"

  while [[ "${STOP}" -eq 0 ]]; do
    attempt=$((attempt + 1))
    : > "${run_log}"
    log "=== attempt #${attempt}: ${PYTHON_BIN} agora_cli.py ${ARGS[*]//${HF_TOKEN}/<HF_TOKEN>} ==="

    # Stream to terminal AND capture to run_log for post-mortem classification.
    ( cd "${AGORA_DIR}" && exec "${PYTHON_BIN}" agora_cli.py "${ARGS[@]}" ) 2>&1 | tee "${run_log}" &
    CHILD_PID=$!
    wait "${CHILD_PID}"
    rc="${PIPESTATUS[0]}"
    CHILD_PID=""

    [[ "${STOP}" -eq 1 ]] && break

    if grep -Eq "${REJECT_MARKERS}" "${run_log}"; then
      log "gate full (rejected, rc=${rc}) — retry #$((attempt + 1)) in ${AGORA_RETRY_INTERVAL}s ..."
    elif grep -Eq "${JOIN_MARKERS}" "${run_log}"; then
      log "session ended after joining (rc=${rc}) — restarting in ${AGORA_RETRY_INTERVAL}s ..."
    else
      log "exited before joining (rc=${rc}) — retry in ${AGORA_RETRY_INTERVAL}s. Last lines:"
      tail -n 5 "${run_log}" | sed 's/^/    | /' >&2
    fi

    sleep "${AGORA_RETRY_INTERVAL}" || break
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
