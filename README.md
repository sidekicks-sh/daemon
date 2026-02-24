# Sidekicks Daemon

`sidekick.sh` is a lightweight autonomous worker that polls the Sidekicks control plane, runs coding tasks in git repos, then commits, pushes, and opens PRs.

## Requirements
- `bash`, `git`, `curl`, `jq`, `gh`
- One agent CLI: `codex` (default), `opencode`, or `claude`

## Run
```bash
./sidekick.sh run
./sidekick.sh --detach run
./sidekick.sh status
./sidekick.sh stop
```

## Key env vars
- `SIDEKICK_CONTROL_PLANE_URL` (default: `http://localhost:3000/api`)
- `SIDEKICK_API_TOKEN` (default: `mock-token`)
- `SIDEKICK_AGENT` (`codex|opencode|claude`, default: `codex`)
- `SIDEKICK_REPOS_DIR` (default: `./repos`)
- `SIDEKICK_POLL_INTERVAL` (default: `10`)
- `SIDEKICK_PID_FILE`, `SIDEKICK_LOG_FILE`
