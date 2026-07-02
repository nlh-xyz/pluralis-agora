# pluralis-agora auto-runner

One script to bring up a [Pluralis Agora](https://pluralis.ai/docs/quick-start/run/)
node and keep it running. The network gates the max number of active nodes, so
`run-agora.sh` spams the auth gate on a fixed interval (default 10s) until it's
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
   (existing clones are left as-is). `agora_cli.py` sets up its own deps/weights
   on first run.
3. **Supervise** — run `agora_cli.py start --skip_input ...` in a loop:
   - gate full → retry every `AGORA_RETRY_INTERVAL`s
   - joined then exited → restart
   - failed before joining → retry (last log lines are printed)

`Ctrl+C` stops the node and the supervisor cleanly.

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
| `AGORA_RETRY_INTERVAL` | retry sleep (s) | no | `10` |
| `AGORA_REPO_URL` | clone source | no | `PluralisResearch/agora` |

You can also override per-invocation, e.g.:

```bash
AGORA_GPU_ID=1 AGORA_HOST_PORT=49201 AGORA_ANNOUNCE_PORT=51931 ./run-agora.sh
```

## Notes

- **Native execution** (python3.11), matching the standard workspace setup. No Docker.
- Requires **Python 3.11** and a CUDA GPU (per Pluralis requirements). The script
  checks for python3.11 but does **not** install it for you.
- Multiple GPUs: run one instance per GPU with a distinct `AGORA_GPU_ID` and
  distinct ports.
