#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "🦆 Microduck Mac setup"
echo "Workspace: $ROOT"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Warning: this setup script is tuned for macOS."
fi

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing dependency: $1"
    return 1
  fi
}

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required. Install it from https://brew.sh and rerun this script."
  exit 1
fi

for pkg in git uv node; do
  if ! command -v "$pkg" >/dev/null 2>&1; then
    echo "→ installing $pkg with Homebrew"
    brew install "$pkg"
  fi
done

echo "→ initializing pinned submodules"
git submodule update --init --recursive

# microduck-lab expects these two upstream repos beside its own projects.
# Keep the canonical copies as top-level submodules and expose them via symlink.
ln -sfn ../microduck "$ROOT/microduck-lab/microduck"
ln -sfn ../microduck_rl "$ROOT/microduck-lab/microduck_rl"

echo "→ syncing Python environment"
(cd "$ROOT/microduck-lab/microduck_local" && uv sync)

POLICY_REPO="pollen-robotics/microduck-policies"
POLICY_REV="088524a64e2557dc453256b6071dbb9d23888802"
POLICIES=(
  alpha_walking.onnx
  alpha_stand.onnx
  alpha_sitstand.onnx
  alpha_ground_pick.onnx
  ball_kick_left.onnx
  ball_kick_right.onnx
  roller.onnx
  roller_crouch.onnx
  roulade.onnx
)

mkdir -p "$ROOT/microduck/policies"
missing=()
for p in "${POLICIES[@]}"; do
  [ -s "$ROOT/microduck/policies/$p" ] || missing+=("$p")
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "→ downloading ${#missing[@]} official shipped policies"
  (cd "$ROOT/microduck-lab/microduck_local" && \
    uv run hf download "$POLICY_REPO" "${missing[@]}" \
      --revision "$POLICY_REV" \
      --local-dir "$ROOT/microduck/policies" \
      --quiet >/dev/null)
else
  echo "✓ official shipped policies already present"
fi

echo "→ installing browser viewer dependencies"
(cd "$ROOT/microduck-lab/duck-viewer" && npm install --no-audit --no-fund)

echo "→ applying Chinese viewer UI"
bash "$ROOT/scripts/apply-zh-cn.sh"

echo "→ running contract smoke tests"
(cd "$ROOT/microduck-lab/microduck_local" && \
  uv run --with pytest pytest \
    tests/test_env_contract.py \
    tests/test_world.py \
    tests/test_brain.py \
    -q -p no:cacheprovider)

cat <<'MSG'

✅ Microduck Mac workspace is ready.
✅ Viewer defaults to Chinese; use the top-right EN / 中文 button to switch.

Next:
  ./scripts/train-first.sh

To inspect this Mac before training:
  cd microduck-lab/microduck_local
  uv run machine-facts
  uv run bench-envs

MSG
