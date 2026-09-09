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

echo "🦩 Applying one-leg stability rewards"
bash "$ROOT/scripts/apply-one-leg-stability.sh"

echo "📏 Applying one-leg hover-height penalty"
bash "$ROOT/scripts/apply-one-leg-height-error.sh"

echo "〰️ Applying one-leg windowed oscillation penalty"
bash "$ROOT/scripts/apply-one-leg-oscillation.sh"

echo "⚖️ Applying one-leg center-of-mass balance reward"
bash "$ROOT/scripts/apply-one-leg-com-balance.sh"

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
