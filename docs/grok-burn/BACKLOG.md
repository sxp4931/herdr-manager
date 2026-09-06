# Shepherd backlog (ordered)

1. **Token meter / usage-log RAM regressions** — Recent work streamed JSONL; hunt remaining whole-file loads, unbounded caches, or menu-bar poll hotspots. Acceptance: code+tests prove bounded reads; document any intentional tradeoffs.
2. **Adapter/protocol robustness** — Unknown protocol / capability disable paths; decode failures; reconnect UX reasons stay accurate. Tests for edge cases.
3. **Attention triage correctness** — worst-state-wins, dwell timers, silent/finished classification edge cases + tests.
4. **Pending actions safety** — approve/deny/interrupt confirmation paths; no accidental writes when capability missing.
5. **CLI herdmgr clarity** — status output useful when socket missing; error messages point to HERDR_SOCKET_PATH.
6. **MCP server guardrails** — confirmation flow / redaction paths; never leak secrets in tool results.
7. **Final verify** — swift test (if available); summarize commits; leave tree clean of build artifacts.
