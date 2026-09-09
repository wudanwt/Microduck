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
# Late-stage liftoff gate V2.
#
# Earlier installers intentionally patch the same one_leg helper cluster.  V1
# assumed a particular adjacency between helper functions and therefore broke
# once reverse-curriculum / unloading helpers had been layered in.  V2 replaces
# top-level functions by NAME and stops at the next top-level def/_register,
# making the patch independent of installer order.
# ---------------------------------------------------------------------------

def replace_top_level_function(src: str, name: str, replacement: str) -> str:
    """Replace one top-level `def name(...)` regardless of neighboring helpers."""
    start_re = re.compile(rf'(?m)^def {re.escape(name)}\([^\n]*\)(?:\s*->\s*[^:]+)?:\s*\n')
    m = start_re.search(src)
    if not m:
        raise SystemExit(f"Could not locate top-level function {name}")
    # Top-level helpers in this module are separated by another `def`, a class/
    # decorator (future-proofing), or the first behavior registration.
    boundary = re.compile(r'(?m)^(?=def |class |@|_register\(Behavior\()')
    n = boundary.search(src, m.end())
    end = n.start() if n else len(src)
    return src[:m.start()] + replacement.rstrip() + "\n\n" + src[end:]

contact_fn = r'''def _right_foot_ground_contact_penalty(env) -> float:
    """Late-stage penalty for leaving the nominally lifted foot on the floor."""
    stage = _one_leg_stage(env)
    if stage <= 2 or not env.foot_contact_state["right"]:
        return 0.0
    # Ramp the rule in rather than shocking the early learner.
    return -{3: 0.25, 4: 0.50, 5: 1.00, 6: 1.00}.get(stage, 1.00)
'''

marker = "# MICRODUCK_USER_ONE_LEG_LIFTOFF_GATE_V2"
if marker not in s:
    # Keep the marker next to the helper so repeated starts are easy to audit.
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate first behavior registration")
    s = s[:idx] + marker + "\n" + contact_fn + "\n" + s[idx:]
else:
    s = replace_top_level_function(s, "_right_foot_ground_contact_penalty", contact_fn)

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
    # Early stage 2 still learns unloading continuously. By stages 5/6 a
    # grounded right foot gets almost none of this reward, so "toe touching"
    # can no longer masquerade as successful one-leg balance.
    scale = {2: 1.00, 3: 0.50, 4: 0.20, 5: 0.05, 6: 0.05}.get(stage, 0.05)
    return scale * raw
'''
s = replace_top_level_function(s, "_right_foot_unload_score", unload_new)

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
        # Polishing stages: grounded right foot is not a valid one-leg hold.
        # Preserve only a tiny gradient toward clearance.
        support = 0.01 + 0.03 * progress
    return base * support
'''
s = replace_top_level_function(s, "_one_leg_stage_hold", hold_new)

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
    # Final stages: touching the floor is not "foot in air" at all.
    return 0.0
'''
s = replace_top_level_function(s, "_one_leg_stage_lift", lift_new)

# Add/update the visible contact penalty term in the one_leg recipe.
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
else:
    # Keep the intended weight/function even if a previous partial version
    # already inserted the term.
    block = re.sub(
        r'(?ms)RewardTerm\(\s*"right_foot_ground_contact".*?\),',
        'RewardTerm(\n            "right_foot_ground_contact",\n'
        '            "惩罚：进入抬腿阶段后右脚仍然接触地面",\n'
        '            4.0,\n'
        '            _right_foot_ground_contact_penalty,\n'
        '            is_penalty=True,\n'
        '        ),',
        block,
        count=1,
    )

s = s[:reg_start] + block + s[reg_end:]
path.write_text(s)

# Text verification.
s = path.read_text()
one_id = s.find('id="one_leg"')
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id) + len("\n))")
one = s[reg_start:reg_end]
for needle in (
    "# MICRODUCK_USER_ONE_LEG_LIFTOFF_GATE_V2",
    "def _right_foot_ground_contact_penalty(env)",
    '"right_foot_ground_contact"',
    "scale = {2: 1.00, 3: 0.50, 4: 0.20, 5: 0.05, 6: 0.05}",
    "support = 0.01 + 0.03 * progress",
    "Final stages: touching the floor is not",
):
    if needle not in s and needle not in one:
        raise SystemExit(f"liftoff-gate V2 source verification failed: {needle}")

print("✓ one_leg liftoff-gate V2 source patch verified")
print("  patching: function-name based, independent of helper ordering")
print("  stage2: grounded unloading still receives full shaping")
print("  stage3/4: grounded loophole progressively reduced")
print("  stage5/6: grounded right foot = -4.0 weighted contact penalty")
print("  stage5/6: grounded unload credit = 5%; grounded hold nearly zero")
PY

# Runtime + physical ordering check.
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

# Final-stage training never uses this spawn (probability 0); invoking it here
# only proves the reward ordering for a physically airborne pose.
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

print("✓ one_leg liftoff-gate V2 physical reward ordering passed")
print(f"  grounded: contact_pen={ground_pen:.2f}, unload={ground_unload:.3f}, hold={ground_hold:.3f}")
print(f"  airborne: contact_pen={air_pen:.2f}, unload={air_unload:.3f}, lift={air_lift:.3f}")
env.close()
PY
)
