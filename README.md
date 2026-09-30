# herdr dashboard

Read-only localhost dashboard for subscription windows, banked Codex resets, herdr and tmux session triage, and git worktree counts.

Milestone 01 boots the toolchain, the loopback health API, and the test runners. Operations for passive, live, and fixture modes are completed in a later milestone. Do not point this process at a public interface.

```bash
npm ci
python3 -m venv .venv
.venv/bin/python -m pip install -r probes/requirements.txt
npm exec playwright install chromium
npm run build
npm start
```

The server binds `127.0.0.1:4317`. Stop it with SIGINT or SIGTERM.
