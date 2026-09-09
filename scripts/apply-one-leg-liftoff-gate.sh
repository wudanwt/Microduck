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

# ---------------------------------------------------------------------------
# Late-stage liftoff gate.
#
# The previous curriculum successfully taught the duck to unload the right
# foot, but it found a loophole: keep that foot lightly touching the floor and
# continue collecting large COM/hold/unload rewards.  Early curriculum stages
# still need smooth unloading credit, but late stages must make CONTACT itself
# clearly worse than being airborne.
# ---------------------------------------------------------------------------
helper = r'''
# MICRODUCK_USER_ONE_LEG_LIFTOFF_GATE_V1
def _right_foot_ground_contact_penalty(env) -> float:
    """Late-stage penalty for leaving the nominally lifted foot on the floor."""
    stage = _one_leg_stage(env)
    if stage <= 2 or not env.foot_contact_state["right"]:
        return 0.0
    # Ramp the rule in rather than shocking the early learner.
    return -{3: 0.25, 4: 0.50, 5: 1.00, 6: 1.00}.get(stage, 1.00)

'''

if "# MICRODUCK_USER_ONE_LEG_LIFTOFF_GATE_V1" not in s:
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate first behavior registration")
    s = s[:idx] + helper + s[idx:]

# 1) Grounded unloading is useful ONLY as an early bridge.  By stages 5/6 it
# earns almost nothing unless the foot actually leaves the floor.
unload_pat = re.compile(
    r'(?ms)^def _right_foot_unload_score\(env\) -> float:\n.*?(?=^def _one_leg_stage_hold\(env\) -> float:)'
)
unload_new = r'''def _right_foot_unload_score(env) -> float:
    """Airborne=1; grounded unloading credit fades away across the curriculum."""
    stage = _one_leg_stage(env)
    if stage <= 1:
        return 0.0
    if not env.foot_contact_state["right"]:
        return 1.0
    left_n, right_n = _one_leg_foot_normal_forces(env)
    total = left_n + right_n
    if total <= 1e-6:
        return 0.0
    right_share = float(np.clip(right_n / total, 0.0, 1.0))
    raw = float(np.exp(-((right_share / 0.35) ** 2)))
    scale = {2: 1.00, 3: 0.50, 4: 0.20, 5: 0.05, 6: 0.05}.get(stage, 0.05)
    return scale * raw


'''
s, count = unload_pat.subn(unload_new, s, count=1)
if count != 1:
    raise SystemExit("Could not patch _right_foot_unload_score for liftoff gate")

# 2) Do not let one_leg_hold remain a lucrative two-foot reward in late stages.
hold_pat = re.compile(
    r'(?ms)^def _one_leg_stage_hold\(env\) -> float:\n.*?(?=^def _one_leg_stage_lift\(env\) -> float:)'
)
hold_new = r'''def _one_leg_stage_hold(env) -> float:
    contacts = env.foot_contact_state
    if not contacts["left"]:
        return 0.0

    com = _com_over_left_stance_foot(env)
    base = _upright(env) * (0.20 + 0.80 * com)
    stage = _one_leg_stage(env)
    if stage <= 1:
        return base

    _, _, progress, target_score, airborne = _one_leg_clearance(env)
    unload = _right_foot_unload_score(env)
    if airborne:
        support = 0.70 + 0.30 * target_score
    elif stage == 2:
        support = 0.08 + 0.52 * unload + 0.20 * progress
    elif stage == 3:
        support = 0.05 + 0.30 * unload + 0.15 * progress
    elif stage == 4:
        support = 0.03 + 0.15 * unload + 0.10 * progress
    else:
        # In the polishing stages a grounded right foot is no longer a valid
        # one-leg hold.  Keep only a tiny slope so PPO can still move toward
        # clearance instead of seeing a perfectly flat objective.
        support = 0.01 + 0.03 * progress
    return base * support


'''
s, count = hold_pat.subn(hold_new, s, count=1)
if count != 1:
    raise SystemExit("Could not patch _one_leg_stage_hold for liftoff gate")

# 3) Likewise, 'foot in air' must stop paying significant grounded-unload
# credit once the learner reaches the final stages.
lift_pat = re.compile(
    r'(?ms)^def _one_leg_stage_lift\(env\) -> float:\n.*?(?=^def _one_leg_stage_stable_hover\(env\) -> float:)'
)
lift_new = r'''def _one_leg_stage_lift(env) -> float:
    stage = _one_leg_stage(env)
    if stage <= 1:
        return 0.0

    _, _, progress, target_score, airborne = _one_leg_clearance(env)
    if airborne:
        return 0.25 + 0.75 * target_score

    unload = _right_foot_unload_score(env)
    bridge = unload * (0.15 + 0.85 * progress)
    if stage == 2:
        return bridge
    if stage == 3:
        return 0.50 * bridge
    if stage == 4:
        return 0.20 * bridge
    return 0.0


'''
s, count = lift_pat.subn(lift_new, s, count=1)
if count != 1:
    raise SystemExit("Could not patch _one_leg_stage_lift for liftoff gate")

# 4) Add an explicit visible penalty term to the one_leg recipe.
one_id = s.find('id="one_leg"')
if one_id < 0:
    raise SystemExit("Could not locate one_leg behavior")
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id)
if reg_start < 0 or reg_end < 0:
    raise SystemExit("Could not locate complete one_leg registration")
reg_end += len("\n))")
block = s[reg_start:reg_end]

if '"right_foot_ground_contact"' not in block:
    m = re.search(
        r'(?ms)(?P<indent>^[ \t]*)RewardTerm\(\s*"right_foot_unloaded".*?\),',
        block,
    )
    if not m:
        raise SystemExit("Could not locate right_foot_unloaded term")
    ind = m.group("indent")
    term = (
        f'\n{ind}RewardTerm(\n'
        f'{ind}    "right_foot_ground_contact",\n'
        f'{ind}    "惩罚：进入抬腿阶段后右脚仍然接触地面",\n'
        f'{ind}    4.0,\n'
        f'{ind}    _right_foot_ground_contact_penalty,\n'
        f'{ind}    is_penalty=True,\n'
        f'{ind}),' 
    )
    block = block[:m.end()] + term + block[m.end():]

s = s[:reg_start] + block + s[reg_end:]
path.write_text(s)

# Text verification.
s = path.read_text()
one_id = s.find('id="one_leg"')
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id) + len("\n))")
one = s[reg_start:reg_end]
for needle in (
    "# MICRODUCK_USER_ONE_LEG_LIFTOFF_GATE_V1",
    "def _right_foot_ground_contact_penalty(env)",
    '"right_foot_ground_contact"',
    "scale = {2: 1.00, 3: 0.50, 4: 0.20, 5: 0.05, 6: 0.05}",
    "support = 0.01 + 0.03 * progress",
    "return 0.0",
):
    if needle not in s and needle not in one:
        raise SystemExit(f"liftoff-gate source verification failed: {needle}")

print("✓ one_leg liftoff-gate source patch verified")
print("  stage2: grounded unloading still receives full shaping")
print("  stage3: grounded contact penalty ramps in")
print("  stage4: grounded loophole strongly reduced")
print("  stage5/6: grounded right foot = -4.0 weighted contact penalty")
print("  stage5/6: grounded unload credit reduced to 5%; grounded hold nearly zero")
PY

# Runtime + physical ordering check.  We intentionally compare the same stage-6
# environment before and after a manual pre-lift spawn.  If grounded contact is
# still rewarded comparably, this script refuses to start the lab.
(
  cd "$LOCAL"
  uv run python - <<'PY'
from microduck_local.behaviors import BEHAVIORS
from microduck_local.behaviors.env import BehaviorEnv

b = BEHAVIORS["one_leg"]
terms = {t.key: t for t in b.terms}
required = {"right_foot_unloaded", "right_foot_ground_contact", "one_leg_hold", "foot_in_air"}
missing = required - set(terms)
if missing:
    raise SystemExit(f"liftoff-gate runtime terms missing: {sorted(missing)}")

stage6 = b.curriculum[-1]
env = BehaviorEnv("one_leg", spawn_overrides=stage6.env)
env.reset()
env.foot_contact_state = env._foot_contacts()
if not env.foot_contact_state["right"]:
    raise SystemExit("liftoff-gate check expected normal stage6 reset with right foot grounded")

ground_pen = terms["right_foot_ground_contact"].fn(env)
ground_unload = terms["right_foot_unloaded"].fn(env)
ground_hold = terms["one_leg_hold"].fn(env)
if ground_pen > -0.99:
    raise SystemExit(f"liftoff-gate grounded penalty too weak: {ground_pen}")
if ground_unload > 0.08:
    raise SystemExit(f"liftoff-gate grounded unload credit too high: {ground_unload}")

# Manually invoke the reverse spawn even though final-stage spawn probability is
# zero. This is only a test pose; the final trained policy still receives no
# training-wheel spawn in stage 6.
_, spawn_fn = b.spawn_families[0]
spawn_fn(env)
env.foot_contact_state = env._foot_contacts()
if env.foot_contact_state["right"]:
    raise SystemExit("liftoff-gate physical check failed: pre-lift pose still touches floor")

air_pen = terms["right_foot_ground_contact"].fn(env)
air_unload = terms["right_foot_unloaded"].fn(env)
air_lift = terms["foot_in_air"].fn(env)
if abs(air_pen) > 1e-9:
    raise SystemExit(f"liftoff-gate airborne penalty should be zero: {air_pen}")
if air_unload < 0.99:
    raise SystemExit(f"liftoff-gate airborne unload reward too low: {air_unload}")
if air_lift <= 0.0:
    raise SystemExit(f"liftoff-gate airborne lift reward should be positive: {air_lift}")

print("✓ one_leg liftoff-gate physical reward ordering passed")
print(f"  grounded: contact_pen={ground_pen:.2f}, unload={ground_unload:.3f}, hold={ground_hold:.3f}")
print(f"  airborne: contact_pen={air_pen:.2f}, unload={air_unload:.3f}, lift={air_lift:.3f}")
env.close()
PY
)
