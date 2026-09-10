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

# Rebuild the entire one-leg source stack from the pinned microduck-lab
# baseline on EVERY launch. We intentionally do not layer patch scripts over an
# already-patched poses.py anymore; that approach caused restart-order bugs.
# Only poses.py is reset. Training runs, exported policies and lab-state.json
# are preserved.
bash "$ROOT/scripts/rebuild-one-leg-stack.sh"

echo "🎯 Applying Teach fine-tune learning-rate control"
bash "$ROOT/scripts/apply-finetune-lr.sh"

echo "🇨🇳 Applying Chinese viewer UI"
bash "$ROOT/scripts/apply-zh-cn.sh"

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
echo "Viewer defaults to Chinese; use the top-right EN / 中文 button to switch."
cd "$VIEWER"
npm run dev
