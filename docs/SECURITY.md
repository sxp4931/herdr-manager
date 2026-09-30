# Security

The dashboard is read-only. It binds to loopback, stores only normalized records, and does not keep terminal screens, environment blocks, or credential files.

## What is stored

SQLite lives under a private directory (`0700`) at a file mode of `0600`, including the WAL and shared-memory files when they exist. Tables hold quota samples, source health, the latest session row, git metadata, and alert rows. Quota samples older than seven days are deleted using the injected clock. A session or git row older than an already stored observation is ignored. Session dwell stays with the same session identity and process id; a new identity starts a new dwell.

## Redaction

Before a value is written or returned as JSON, string fields are rewritten:

- credential-like prefixes (`sk-`, `sk-ant-`, `ghp_`, `github_pat_`, `xai-`, `AKIA`)
- bearer tokens
- URL usernames, passwords, and token query parameters
- email addresses
- newlines and other control characters, which are collapsed to a single line
- the fixture sentinel `SYNTHETIC_SECRET_SENTINEL`

Objects that still carry raw capture fields (`screen`, `stdout`, `stderr`, `argv`, `env`) are rejected instead of stored.

## Corruption and locks

A file that is not a SQLite database, or that fails `PRAGMA integrity_check`, raises `StorageCorruptionError`. The file is left in place for the operator. Writes use a bounded busy timeout and do not delete the database when the lock is held.

## HTTP

JSON responses are `no-store`, unknown `/api` paths are 404, and mutating methods are 405. Request targets are not copied into response bodies.
