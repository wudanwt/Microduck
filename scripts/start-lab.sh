#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_NAME="${1:-first-gait}"
LOCAL="$ROOT/microduck-lab/microduck_local"
VIEWER="$ROOT/microduck-lab/duck-viewer"
REFERENCE="$ROOT/microduck-lab/microduck/policies/alpha_walking.onnx"
RUN_DIR="$LOCAL/runs/$RUN_NAME"

if [ ! -f "$REFERENCE" ]; then
  echo "Reference policy not found. Run: bash scripts/setup-mac.sh"
  exit 1
fi

args=("$REFERENCE")
if [ -d "$RUN_DIR" ]; then
  args=("$RUN_DIR" "$REFERENCE")
fi

echo "🦆 Starting duck-lab backend"
(cd "$LOCAL" && uv run duck-lab "${args[@]}") &
LAB_PID=$!

cleanup() {
  kill "$LAB_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

sleep 2

echo "🦆 Starting browser viewer"
echo "Open the URL printed by Next.js. Ctrl+C stops both processes."
cd "$VIEWER"
npm run dev
