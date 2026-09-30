# herdr dashboard agent rules

This repository is a read-only Linux localhost dashboard. It is a sibling client of the herdr socket, not a wrapper around the Shepherd Swift app.

## Hard rules

1. Work only on `feat/herdr-dashboard-v1` in this repository. Reference checkouts are read-only. Do not push, open a PR, merge, deploy, spend money, or use a real API key.
2. Do not read credential files, copy tokens, scrape account sites, or print secrets. Strip vendor API-key environment variables from collector children. Do not log in, log out, or change account settings.
3. Spawn children with argument arrays and `shell: false`. Never interpolate a path, branch, provider, or pane id into a shell string. Git observations set `GIT_OPTIONAL_LOCKS=0` and `GIT_TERMINAL_PROMPT=0`.
4. Never send input to an existing user, herdr, or tmux pane. A usage probe, when explicitly enabled, gets a new process group in an empty private directory. It must not resume a chat, accept workspace trust, redeem a reset, or start a model turn.
5. Record milestone evidence in `PROGRESS.md` and external capability gaps in `BLOCKERS.md`. Label fixtures as fixtures.
6. Unknown quota data is null or `unknown`, never zero. `mode=fixture` is available only when `HERDR_FIXTURE=1`.
7. V1 has no action buttons and no write endpoints. Do not add a feature flag that later enables them.

## Local checks

`npm run check` runs lint, typecheck, unit tests, Python tests, the production build, and integration tests. `bash scripts/verify.sh` is the fresh-machine proof, once that script exists.
