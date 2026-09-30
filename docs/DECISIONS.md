# Decisions

## 2026-09-29 — Runtime patches on this machine

- Node is exactly `22.23.2`, matching the plan pin.
- The npm CLI used to create the lockfile is `10.9.3`, invoked from the Corepack cache because `/usr/bin/npm` on this host is 9.2.0 and the Node 22.23.2 distribution itself ships npm 10.9.8.
- Python is `3.13.5`. The plan prefers `3.13.7` and explicitly allows recording the installed 3.10–3.13 patch instead of replacing the interpreter. Standard-library probe APIs (`pty`, `os`, `select`, `signal`, `termios`, `fcntl`) are present. No OS package was installed.

## 2026-09-29 — One Node process

The server is a Node HTTP process using `node:sqlite` and the same TypeScript contracts as the Vite UI. A second Python web framework is not introduced. Python is limited to the PTY helper.

## 2026-09-29 — Exact vitest override

`npm install` with npm 10.9.3, npm 10.9.8, and npm 9.2.0 aborted inside Arborist (`Cannot read properties of null (reading 'edgesOut')`) while resolving Vite 8.3.0's optional `@vitejs/devtools` peer. That tree depends on `vitest@*`, and the `latest` dist-tag is vitest 5.0.2, which collides with the direct pin vitest 4.1.11. Root `overrides.vitest` is the exact string `4.1.11`. No direct dependency version changed, and `npm ci` then reproduces the lockfile on both npm 10.9.3 and the host npm 9.2.0.

## 2026-09-29 — Fixture mode gate

`mode=fixture` is selected only by `HERDR_FIXTURE=1`. The `--fixture` CLI flag refuses to start unless that variable is set, so a production start command cannot silently enter the demo catalog.
