# Pluralis Agora Auto-Runner — Design

**Date:** 2026-07-02
**Status:** Approved

## Goal
A single reusable script that takes a bare GPU box to a persistently-running
Pluralis Agora node: clone → configure via env → run `agora_cli.py start`,
aggressively retrying the auth gate every 10s until admitted, then supervising.

## CLI ground truth (from PluralisResearch/agora `agora_cli.py`)
- Command: `python3 agora_cli.py start`
- Flags: `--token` (HF token), `--email`, `--host_port`, `--announce_port`,
  `--gpu_id`, `--skip_input`, `--use_docker`, `--reconfigure`,
  `--identity_path`, `--log_file`.
- Port defaults: `49200 + gpu_id` for both host/announce.
- Config persists to `~/.agora/user_config.json` and `~/.agora/config_gpu{ID}.json`;
  identity key at `private_gpu{ID}.key`.
- The gate rejection is a runtime event: `Authorization failed: Maximum number
  of active nodes reached, please try again later.. Exiting run.` — the process
  then exits cleanly. Retry logic keys off this string.

## Deliverables
- `run-agora.sh` — the runner (bash)
- `.env.example` — documented config template
- `README.md` — usage

## Config (env vars; `.env` auto-sourced if present)
| Var | Maps to | Required | Default |
|---|---|---|---|
| `HF_TOKEN` | `--token` | yes | — |
| `AGORA_EMAIL` | `--email` | no | — |
| `AGORA_HOST_PORT` | `--host_port` | no | CLI default |
| `AGORA_ANNOUNCE_PORT` | `--announce_port` | no | CLI default |
| `AGORA_GPU_ID` | `--gpu_id` | no | `0` |
| `AGORA_DIR` | clone/target dir | no | `./agora` |
| `AGORA_RETRY_INTERVAL` | retry sleep seconds | no | `10` |
| `AGORA_REPO_URL` | clone source | no | `https://github.com/PluralisResearch/agora` |

## Flow
1. **Load config** — source `.env` if present, then read env.
2. **Pre-flight (fail fast, before the loop)** — assert `HF_TOKEN` set; assert
   `git` and `python3.11` present (error with install hint, do NOT auto-install).
   Bad token / missing tooling are not retryable, so they never enter the loop.
3. **Bootstrap (idempotent)** — if `$AGORA_DIR` missing, `git clone`. Existing
   clones are left untouched (no auto-pull). `agora_cli.py` manages its own
   venv/deps/weights on first run.
4. **Supervise loop** — run the start command with flags derived from env,
   streaming combined stdout+stderr to the terminal and to a per-attempt log.
   On each exit, classify from the log and retry after `AGORA_RETRY_INTERVAL`:
   - matched rejection markers → "gate full — retry #N"
   - saw join/training markers earlier → "session ended — restarting"
   - otherwise → "exited before joining — retry" (log last lines)
   All exits are retryable (per approved choice); the classification only drives
   the log message.

## Error handling
- Combined output `tee`'d to terminal and grepped per-attempt for rejection
  markers (`Maximum number of active nodes reached`, `Authorization failed`) and
  join markers (sync/training phase lines).
- `Ctrl+C` (SIGINT/SIGTERM) → trap kills the child and exits the supervisor cleanly.
- Every log line carries a timestamp and attempt counter.

## Assumptions / non-goals
- Native execution only (no `--use_docker`).
- No auto-install of python3.11 (OS-specific/risky) — checks and instructs.
- No auto-update of an existing clone — remove `$AGORA_DIR` to re-clone.
