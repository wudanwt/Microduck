#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/microduck-lab/microduck_local"

ENVS="${ENVS:-32}"
STEPS="${STEPS:-3000000}"
RUN_NAME="${RUN_NAME:-first-gait}"

echo "🦆 Training $RUN_NAME on this Mac"
echo "envs=$ENVS steps=$STEPS"

uv run train-walk --envs "$ENVS" --steps "$STEPS" --run-name "$RUN_NAME"
uv run export-walk "runs/$RUN_NAME"
uv run eval-walk "runs/$RUN_NAME/policy.onnx"

echo
echo "✅ Policy exported: microduck-lab/microduck_local/runs/$RUN_NAME/policy.onnx"
echo "Start the viewer with: bash ../../scripts/start-lab.sh $RUN_NAME"
