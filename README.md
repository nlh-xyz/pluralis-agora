# pluralis-agora auto-runner

One script to bring up a [Pluralis Agora](https://pluralis.ai/docs/quick-start/run/)
node and keep it running. The network caps the number of active nodes, so
`run-agora.sh` polls the auth gate on a fixed interval (default 10s) until it's
admitted, then supervises the session and restarts it if it dies.

## Usage

```bash
cp .env.example .env
# edit .env — at minimum set HF_TOKEN
./run-agora.sh
```

That's it. The script will:

1. **Pre-flight** — verify `HF_TOKEN`, `git`, and `python3.11` are present
   (fails fast on misconfig instead of hot-looping).
2. **Bootstrap** — `git clone` the agora repo into `$AGORA_DIR` if it's missing
   (existing clones are left as-is), create an isolated **venv** at `$AGORA_VENV`,
   then install the native python packages into it if they're not present. (The
   client only installs deps interactively; with `--skip_input` it just errors,
   so the runner runs its install commands — cu128 torch + editable
   `./agora_server` and `./agora` — once on a fresh box. Using a venv avoids the
   Debian system-pip that can't self-upgrade, `RECORD file not found`.)
3. **Supervise** — run `agora_cli.py start --skip_input ...` in a loop, classifying
   each exit (in priority order):
   - **non-retryable** (closed port, invalid token, ineligible) → **exit** with the
     error (no hot-loop)
   - **already in the auth queue** → wait `AGORA_QUEUE_BACKOFF`s (keeps the identity key)
   - **gate full** (max active nodes) → retry every `AGORA_RETRY_INTERVAL`s
   - **joined then exited** → restart
   - **failed before joining** → retry (last log lines are printed)

`Ctrl+C` (or `SIGTERM`) stops the node and the supervisor cleanly.

## Configuration

All config is via environment variables (a `.env` next to the script is
auto-sourced). See [`.env.example`](.env.example).

| Var | Maps to | Required | Default |
|---|---|---|---|
| `HF_TOKEN` | `--token` | yes | — |
| `AGORA_EMAIL` | `--email` | no | — |
| `AGORA_HOST_PORT` | `--host_port` | no | `49200 + gpu_id` |
| `AGORA_ANNOUNCE_PORT` | `--announce_port` | no | `49200 + gpu_id` |
| `AGORA_GPU_ID` | `--gpu_id` | no | `0` |
| `AGORA_DIR` | clone/target dir | no | `./agora` |
| `AGORA_VENV` | virtualenv location | no | `./.venv` |
| `AGORA_RETRY_INTERVAL` | retry sleep (s) | no | `10` |
| `AGORA_QUEUE_BACKOFF` | wait when already queued (s) | no | `90` |
| `AGORA_REPO_URL` | clone source | no | `PluralisResearch/agora` |

You can also override per-invocation, e.g.:

```bash
AGORA_GPU_ID=1 AGORA_HOST_PORT=49201 AGORA_ANNOUNCE_PORT=51931 ./run-agora.sh
```

## NAT'd hosts (Vast.ai etc.)

On NAT'd providers the internal `host_port` is exposed on a **different** external
port, and peers must be told that external port via `--announce_port` — otherwise
authorization fails with `Port <N> is closed` (which the script treats as fatal).

- If `AGORA_ANNOUNCE_PORT` is unset, the script auto-detects it from
  `VAST_TCP_PORT_<host_port>` when that variable is present.
- On any other NAT provider, set `AGORA_ANNOUNCE_PORT` yourself to the externally
  mapped port. The script warns if it detects a NAT provider but can't resolve one.

## Notes

- **Native execution** in a venv built from `python3.11`. No Docker.
- Requires **Python 3.11** (+ `python3.11-venv` on Debian/Ubuntu) and a CUDA GPU.
  The script checks for these but does **not** install python itself. (`agora_cli.py`
  only offers a conda env *interactively* and can't install 3.11 under `--skip_input`,
  so Python 3.11 is a prerequisite.) Quick installs:
  - conda: `conda create -y -n agora python=3.11 && conda activate agora`
  - Debian 12: `sudo apt-get install -y python3.11 python3.11-venv python3.11-dev`
  - Ubuntu: `sudo add-apt-repository -y ppa:deadsnakes/ppa && sudo apt-get update && sudo apt-get install -y python3.11 python3.11-venv python3.11-dev`
- Multiple GPUs: run one instance per GPU with a distinct `AGORA_GPU_ID` and
  distinct ports.
- The upstream client under `agora/` runs an integrity check — this repo never
  modifies it; it's cloned as-is and left untouched.
