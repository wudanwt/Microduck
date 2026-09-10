#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$ROOT/microduck-lab"
LOCAL="$LAB/microduck_local"
POSES_REL="microduck_local/src/microduck_local/behaviors/poses.py"
POSES="$LAB/$POSES_REL"

if [ ! -d "$LAB/.git" ] && [ ! -f "$LAB/.git" ]; then
  echo "microduck-lab submodule is not initialized: $LAB" >&2
  exit 1
fi

if ! git -C "$LAB" ls-files --error-unmatch "$POSES_REL" >/dev/null 2>&1; then
  echo "Tracked upstream poses.py not found in microduck-lab: $POSES_REL" >&2
  exit 1
fi

echo "🧱 Rebuilding one-leg stack from the pinned microduck-lab baseline"
# Reset ONLY the one source file owned by our one-leg patch stack. Training
# runs, lab-state.json and exported policies are untouched.
git -C "$LAB" checkout -- "$POSES_REL"

if [ ! -f "$POSES" ]; then
  echo "Failed to restore baseline poses.py: $POSES" >&2
  exit 1
fi

echo "  1/9 stability rewards"
bash "$ROOT/scripts/apply-one-leg-stability.sh"

echo "  2/9 hover-height penalty"
bash "$ROOT/scripts/apply-one-leg-height-error.sh"

echo "  3/9 oscillation detector"
bash "$ROOT/scripts/apply-one-leg-oscillation.sh"

echo "  4/9 COM balance"
bash "$ROOT/scripts/apply-one-leg-com-balance.sh"

echo "  5/9 staged curriculum"
bash "$ROOT/scripts/apply-one-leg-curriculum-v3.sh"

echo "  6/9 contact-force unloading"
bash "$ROOT/scripts/apply-one-leg-unload.sh"

echo "  7/9 reverse curriculum spawn"
bash "$ROOT/scripts/apply-one-leg-reverse-spawn.sh"

echo "  8/9 reverse-assist V3"
bash "$ROOT/scripts/apply-one-leg-reverse-assist-v3.sh"

echo "  9/9 late-stage liftoff + airborne COM gates"
bash "$ROOT/scripts/apply-one-leg-liftoff-gate-v4.sh"
bash "$ROOT/scripts/apply-one-leg-airborne-com-gate.sh"

# Final canonical verification after ALL writers have finished.
(
  cd "$LOCAL"
  uv run python - <<'PY'
from pathlib import Path
from microduck_local.behaviors import BEHAVIORS
from microduck_local.behaviors import poses

b = BEHAVIORS["one_leg"]
terms = {t.key: t for t in b.terms}
required = {
    "one_leg_hold",
    "foot_in_air",
    "right_foot_unloaded",
    "right_foot_ground_contact",
    "right_foot_stable_hover",
    "right_foot_vertical_motion",
    "right_foot_direction_reversal",
    "right_foot_height_error",
    "right_foot_oscillation",
    "com_over_stance_foot",
}
missing = sorted(required - set(terms))
if missing:
    raise SystemExit(f"final one-leg stack missing RewardTerms: {missing}")

expected_fns = {
    "right_foot_ground_contact": "_right_foot_ground_contact_penalty",
    "com_over_stance_foot": "_one_leg_airborne_com_score",
}
for key, expected in expected_fns.items():
    actual = terms[key].fn.__name__
    if actual != expected:
        raise SystemExit(f"final binding wrong for {key}: {actual} != {expected}")
    if not hasattr(poses, expected):
        raise SystemExit(f"final helper missing from poses module: {expected}")

if b.state_fn is None or b.state_fn.__name__ != "_one_leg_reverse_assist_state":
    raise SystemExit(f"final one-leg state_fn wrong: {b.state_fn}")
if len(b.spawn_families) != 1 or b.spawn_families[0][1].__name__ != "_one_leg_spawn_pre_lift":
    raise SystemExit(f"final one-leg spawn family wrong: {b.spawn_families}")
if len(b.curriculum) != 6:
    raise SystemExit(f"final one-leg curriculum stage count wrong: {len(b.curriculum)}")

src = Path("src/microduck_local/behaviors/poses.py").read_text()
for fn in (
    "_one_leg_spawn_pre_lift",
    "_one_leg_reverse_assist_state",
    "_right_foot_ground_contact_penalty",
    "_one_leg_airborne_com_score",
):
    count = src.count(f"def {fn}(")
    if count != 1:
        raise SystemExit(f"final source has {count} definitions of {fn}; expected exactly 1")

print("✓ final one-leg stack import/binding verification passed")
print("  one canonical poses.py rebuilt from pinned baseline")
print("  6 curriculum stages; reverse-assist V3; liftoff V4; airborne COM gate")
PY
)

# Reproducibility fingerprint: the same pinned code should produce the same hash
# on every launch.
if command -v shasum >/dev/null 2>&1; then
  HASH="$(shasum -a 256 "$POSES" | awk '{print $1}')"
else
  HASH="$(python3 - "$POSES" <<'PY'
from pathlib import Path
import hashlib, sys
print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
fi

echo "✓ one-leg stack rebuilt deterministically"
echo "  poses.py sha256: $HASH"
