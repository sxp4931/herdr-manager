#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node scripts/preflight.mjs --require-core
export CI=1 TZ=UTC HERDR_FIXTURE=1 HERDR_ALLOW_NETWORK=0
export HERDR_FIXTURE_NOW=2026-09-29T16:00:00.000Z
export HERDR_STATE_DIR
HERDR_STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/herdr-verify.XXXXXXXX")
verify_pid=''
cleanup() {
  if [ -n "$verify_pid" ]; then
    kill "$verify_pid" 2>/dev/null || true
    wait "$verify_pid" 2>/dev/null || true
  fi
  rm -rf -- "$HERDR_STATE_DIR"
}
trap cleanup EXIT INT TERM
mkdir -p .artifacts/verify
npm ci --no-audit --no-fund
.venv/bin/python -m pip check
npm run check:policy
npm run check
npm run test:e2e
if node --input-type=module - <<'JS'
import net from "node:net";
const socket = net.connect({ host: "127.0.0.1", port: 14317 });
const timer = setTimeout(() => {
  socket.destroy();
  process.exit(0);
}, 400);
socket.on("connect", () => {
  clearTimeout(timer);
  socket.end();
  process.exit(2);
});
socket.on("error", () => {
  clearTimeout(timer);
  process.exit(0);
});
JS
then
  :
else
  printf '%s\n' 'port 14317 is already in use; leaving the existing listener alone' >&2
  exit 1
fi
node apps/server/dist/main.js --fixture --host 127.0.0.1 --port 14317 \
  > "$HERDR_STATE_DIR/server.log" 2>&1 &
verify_pid=$!
export HERDR_SMOKE_PID="$verify_pid"
node scripts/smoke.mjs --base-url http://127.0.0.1:14317 \
  --wait-ms 15000 --evidence .artifacts/verify/smoke.json
curl --fail --silent --show-error http://127.0.0.1:14317/api/health \
  > "$HERDR_STATE_DIR/health.json"
node --input-type=module - "$HERDR_STATE_DIR/health.json" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const h=JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
assert.equal(h.status,'ok'); assert.equal(h.readOnly,true);
assert.equal(h.mode,'fixture'); assert.equal(h.schemaVersion,1);
JS
node scripts/check-policy.mjs --artifacts .artifacts/verify
printf '%s\n' 'VERIFY herdr-dashboard PASS'
