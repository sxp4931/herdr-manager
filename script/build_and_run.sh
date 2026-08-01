#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Shepherd"
BUNDLE_ID="com.shepherd.app"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/Shepherd.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

workspace_pids() {
    ps -axo pid=,command= | awk -v target="$APP_EXECUTABLE" 'index($0, target) {print $1}'
}

stop_workspace_app() {
    while read -r pid; do
        [ -n "$pid" ] || continue
        kill "$pid" >/dev/null 2>&1 || true
    done < <(workspace_pids)
}

launch_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

verify_app() {
    sleep 1
    workspace_pids | grep -q .
}

cd "$ROOT_DIR"
stop_workspace_app
./build-app.sh

case "$MODE" in
    run)
        launch_app
        ;;
    --debug|debug)
        lldb -- "$APP_EXECUTABLE"
        ;;
    --logs|logs)
        launch_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        launch_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --verify|verify)
        launch_app
        verify_app
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
