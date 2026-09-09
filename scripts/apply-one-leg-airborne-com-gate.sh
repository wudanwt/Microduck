#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL="$ROOT/microduck-lab/microduck_local"
TARGET="$LOCAL/src/microduck_local/behaviors/poses.py"

if [ ! -f "$TARGET" ]; then
  echo "Microduck Lab behavior file not found: $TARGET" >&2
  exit 1
fi

python3 - "$TARGET" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
s = path.read_text()

MARKER = "# MICRODUCK_USER_ONE_LEG_AIRBORNE_COM_GATE_V1"
HELPER = r'''
# MICRODUCK_USER_ONE_LEG_AIRBORNE_COM_GATE_V1
def _one_leg_airborne_com_score(env) -> float:
    """COM balance reward whose late-stage value requires REAL foot clearance.

    Early stages may use the grounded COM gradient to learn transferring weight
    onto the left stance foot. In late stages, however, a lightly touching
    right foot is not success: the COM reward is strongly gated by contact and
    then smoothly restored as the right foot actually rises toward the target.
    """
    raw = _com_over_left_stance_foot(env)
    stage = _one_leg_stage(env)
    if stage <= 2:
        return raw

    h, target, progress, _, airborne = _one_leg_clearance(env)

    if stage == 3:
        if not airborne:
            return raw * (0.15 + 0.25 * progress)
        gate = 0.45 + 0.55 * float(np.clip(h / max(target, 1e-4), 0.0, 1.0))
        return raw * gate

    if stage == 4:
        if not airborne:
            return raw * (0.08 + 0.12 * progress)
        gate = 0.30 + 0.70 * float(np.clip(h / max(target, 1e-4), 0.0, 1.0))
        return raw * gate

    # Final 8 cm stages: grounded toe-touch gets only 5% of COM credit.
    if not airborne:
        return 0.05 * raw

    # Also block the numerical "0.2 mm gap" loophole. A just-airborne foot
    # starts near 10% COM credit and smoothly earns the rest with clearance.
    # Full credit arrives by ~6 cm; the separate height reward still polishes
    # the final 8 cm target.
    lo = 0.003
    hi = 0.060
    x = float(np.clip((h - lo) / (hi - lo), 0.0, 1.0))
    smooth = x * x * (3.0 - 2.0 * x)
    gate = 0.10 + 0.90 * smooth
    return raw * gate

'''

if MARKER not in s:
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate first behavior registration")
    s = s[:idx] + HELPER + s[idx:]

# Redirect ONLY the visible COM reward term. _one_leg_stage_hold may continue
# to use the raw COM signal internally because its own support factor is already
# aggressively gated by the liftoff gate in stages 5/6.
one_id = s.find('id="one_leg"')
if one_id < 0:
    raise SystemExit("Could not locate one_leg behavior")
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id)
if reg_start < 0 or reg_end < 0:
    raise SystemExit("Could not locate complete one_leg registration")
reg_end += len("\n))")
block = s[reg_start:reg_end]

pat = re.compile(
    r'(RewardTerm\(\s*"com_over_stance_foot"\s*,\s*"[^"]*"\s*,\s*[-+0-9.eE]+\s*,\s*)'
    r'[A-Za-z_][A-Za-z0-9_]*(?:\s*\([^()\n]*\))?',
    re.S,
)
block, count = pat.subn(lambda m: m.group(1) + "_one_leg_airborne_com_score", block, count=1)
if count != 1:
    raise SystemExit("Could not redirect com_over_stance_foot to airborne gate")

s = s[:reg_start] + block + s[reg_end:]
path.write_text(s)

# Text verification.
s = path.read_text()
one_id = s.find('id="one_leg"')
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id) + len("\n))")
one = s[reg_start:reg_end]
for needle in (
    MARKER,
    "def _one_leg_airborne_com_score(env)",
    "return 0.05 * raw",
    "lo = 0.003",
    "hi = 0.060",
    "_one_leg_airborne_com_score",
):
    if needle not in s and needle not in one:
        raise SystemExit(f"airborne COM gate source verification failed: {needle}")

print("✓ one_leg airborne-COM gate source patch verified")
print("  stage1/2: full grounded COM shaping remains available")
print("  stage3/4: grounded COM progressively discounted")
print("  stage5/6: grounded COM capped at 5%")
print("  stage5/6: airborne COM credit ramps with true 3-60 mm clearance")
PY

(
  cd "$LOCAL"
  uv run python - <<'PY'
from microduck_local.behaviors import BEHAVIORS
from microduck_local.behaviors.env import BehaviorEnv
from microduck_local.behaviors import poses

b = BEHAVIORS["one_leg"]
terms = {t.key: t for t in b.terms}
term = terms.get("com_over_stance_foot")
if term is None or term.fn.__name__ != "_one_leg_airborne_com_score":
    raise SystemExit(f"airborne COM runtime binding wrong: {getattr(term.fn, '__name__', None) if term else None}")

stage6 = b.curriculum[-1]
env = BehaviorEnv("one_leg", spawn_overrides=stage6.env)
env.reset()

# Grounded logical probe. We explicitly make the left foot the valid stance
# support and the right foot grounded, then verify the FINAL-STAGE gate ratio
# rather than comparing absolute scores across two different poses.
env.foot_contact_state = {"left": True, "right": True}
raw_ground = poses._com_over_left_stance_foot(env)
gated_ground = term.fn(env)
if raw_ground > 1e-9:
    grounded_ratio = gated_ground / raw_ground
    if not (0.0 <= grounded_ratio <= 0.051):
        raise SystemExit(
            f"airborne COM grounded gate ratio wrong: raw={raw_ground:.3f}, "
            f"gated={gated_ground:.3f}, ratio={grounded_ratio:.3f}"
        )
else:
    grounded_ratio = 0.0

# Real physical pre-lift probe. Final-stage training has spawn probability zero;
# this manual call is only a validation pose. First verify the RIGHT foot truly
# clears the floor in MuJoCo. Then mark the LEFT foot as the valid stance
# support for reward evaluation: an instantaneous mj_forward after IK may not
# yet register a floor contact even though the pose is the intended stance.
_, spawn_fn = b.spawn_families[0]
spawn_fn(env)
physical_contacts = env._foot_contacts()
if physical_contacts["right"]:
    raise SystemExit("airborne COM physical check failed: pre-lift still touches floor")

left = env.foot_geoms["left"]
right = env.foot_geoms["right"]
h = float(env.data.geom_xpos[right][2] - env.data.geom_xpos[left][2])

# Reward-logic probe: right foot remains physically verified airborne; left is
# the intended stance support. This avoids the COM helper returning zero solely
# because contact generation has not settled on this synthetic one-frame pose.
env.foot_contact_state = {"left": True, "right": False}
raw_air = poses._com_over_left_stance_foot(env)
gated_air = term.fn(env)
if raw_air <= 1e-9:
    raise SystemExit(
        f"airborne COM raw score unexpectedly zero after valid-stance probe; h={h*1000:.1f}mm"
    )
airborne_ratio = gated_air / raw_air

# At the stage-6 validation spawn (~55 mm), the smooth 3-60 mm clearance gate
# should have restored most of the raw COM reward. Keep the threshold broad so
# the check tests semantics, not one exact floating-point pose.
if airborne_ratio < 0.50:
    raise SystemExit(
        f"airborne COM clearance gate too weak: raw={raw_air:.3f}, gated={gated_air:.3f}, "
        f"ratio={airborne_ratio:.3f}, h={h*1000:.1f}mm"
    )

print("✓ one_leg airborne-COM gate ratio validation passed")
print(f"  grounded: raw={raw_ground:.3f}, gated={gated_ground:.3f}, ratio={grounded_ratio:.3f}")
print(
    f"  airborne : h={h*1000:.1f} mm, raw={raw_air:.3f}, gated={gated_air:.3f}, "
    f"ratio={airborne_ratio:.3f}, physical_left_contact={physical_contacts['left']}"
)
env.close()
PY
)
