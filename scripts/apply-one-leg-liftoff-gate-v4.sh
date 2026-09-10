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


def replace_top_level_function(src: str, name: str, replacement: str) -> str:
    start_re = re.compile(rf'(?m)^def {re.escape(name)}\([^\n]*\)(?:\s*->\s*[^:]+)?:\s*\n')
    m = start_re.search(src)
    if not m:
        raise SystemExit(f"Could not locate top-level function {name}")
    boundary = re.compile(r'(?m)^(?=def |class |@|_register\(Behavior\()')
    n = boundary.search(src, m.end())
    end = n.start() if n else len(src)
    return src[:m.start()] + replacement.rstrip() + "\n\n" + src[end:]


def upsert_top_level_function(src: str, name: str, replacement: str) -> str:
    if re.search(rf'(?m)^def {re.escape(name)}\(', src):
        return replace_top_level_function(src, name, replacement)
    idx = src.find("_register(Behavior(")
    if idx < 0:
        raise SystemExit("Could not locate first behavior registration")
    return src[:idx] + replacement.rstrip() + "\n\n" + src[idx:]


contact_fn = r'''def _right_foot_ground_contact_penalty(env) -> float:
    """Penalty for keeping the nominally lifted right foot on the floor."""
    stage = _one_leg_stage(env)
    if stage <= 2 or not env.foot_contact_state["right"]:
        return 0.0
    return -{3: 0.25, 4: 0.50, 5: 1.00, 6: 1.00}.get(stage, 1.00)
'''
s = upsert_top_level_function(s, "_right_foot_ground_contact_penalty", contact_fn)

unload_fn = r'''def _right_foot_unload_score(env) -> float:
    """Airborne=1; grounded unloading credit fades across later stages."""
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
s = replace_top_level_function(s, "_right_foot_unload_score", unload_fn)

hold_fn = r'''def _one_leg_stage_hold(env) -> float:
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
        support = 0.01 + 0.03 * progress
    return base * support
'''
s = replace_top_level_function(s, "_one_leg_stage_hold", hold_fn)

lift_fn = r'''def _one_leg_stage_lift(env) -> float:
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
s = replace_top_level_function(s, "_one_leg_stage_lift", lift_fn)

# Normalize the visible contact penalty RewardTerm in the one_leg registration.
one_id = s.find('id="one_leg"')
if one_id < 0:
    raise SystemExit("Could not locate one_leg behavior")
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id)
if reg_start < 0 or reg_end < 0:
    raise SystemExit("Could not locate complete one_leg registration")
reg_end += len("\n))")
block = s[reg_start:reg_end]

term = '''RewardTerm(
            "right_foot_ground_contact",
            "惩罚：进入抬腿阶段后右脚仍然接触地面",
            4.0,
            _right_foot_ground_contact_penalty,
            is_penalty=True,
        ),'''

if '"right_foot_ground_contact"' in block:
    block, count = re.subn(
        r'(?ms)RewardTerm\(\s*"right_foot_ground_contact".*?\),',
        term,
        block,
        count=1,
    )
    if count != 1:
        raise SystemExit("Could not normalize right_foot_ground_contact RewardTerm")
else:
    m = re.search(r'(?ms)RewardTerm\(\s*"right_foot_unloaded".*?\),', block)
    if not m:
        raise SystemExit("Could not locate right_foot_unloaded RewardTerm")
    block = block[:m.end()] + "\n        " + term + block[m.end():]

s = s[:reg_start] + block + s[reg_end:]
path.write_text(s)

# Semantic source verification: no comment markers or patch-history sentinels.
s = path.read_text()
one_id = s.find('id="one_leg"')
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id) + len("\n))")
one = s[reg_start:reg_end]
checks = (
    "def _right_foot_ground_contact_penalty(env)",
    "def _right_foot_unload_score(env)",
    "def _one_leg_stage_hold(env)",
    "def _one_leg_stage_lift(env)",
    '"right_foot_ground_contact"',
    "_right_foot_ground_contact_penalty",
    "scale = {2: 1.00, 3: 0.50, 4: 0.20, 5: 0.05, 6: 0.05}",
    "support = 0.01 + 0.03 * progress",
)
for needle in checks:
    if needle not in s and needle not in one:
        raise SystemExit(f"liftoff-gate V4 semantic source verification failed: {needle}")

print("✓ one_leg liftoff-gate V4 semantic source verification passed")
print("  no marker/sentinel dependency")
print("  stage2: grounded unloading bridge remains available")
print("  stage3/4: grounded loophole progressively reduced")
print("  stage5/6: grounded right foot = -4.0 weighted contact penalty")
print("  stage5/6: grounded unload credit = 5%; grounded hold nearly zero")
PY

(
  cd "$LOCAL"
  uv run python - <<'PY'
from microduck_local.behaviors import BEHAVIORS
from microduck_local.behaviors.env import BehaviorEnv

b = BEHAVIORS["one_leg"]
terms = {t.key: t for t in b.terms}
required = {"right_foot_unloaded", "right_foot_ground_contact", "one_leg_hold", "foot_in_air"}
missing = sorted(required - set(terms))
if missing:
    raise SystemExit(f"liftoff-gate V4 runtime terms missing: {missing}")
if terms["right_foot_ground_contact"].fn.__name__ != "_right_foot_ground_contact_penalty":
    raise SystemExit("liftoff-gate V4 contact RewardTerm binding wrong")

stage6 = b.curriculum[-1]
env = BehaviorEnv("one_leg", spawn_overrides=stage6.env)
env.reset()

# Logical grounded probe of the loophole itself.
env.foot_contact_state = {"left": True, "right": True}
ground_pen = terms["right_foot_ground_contact"].fn(env)
ground_unload = terms["right_foot_unloaded"].fn(env)
ground_hold = terms["one_leg_hold"].fn(env)
ground_lift = terms["foot_in_air"].fn(env)
if ground_pen > -0.99:
    raise SystemExit(f"liftoff-gate V4 grounded penalty too weak: {ground_pen}")
if ground_unload > 0.08:
    raise SystemExit(f"liftoff-gate V4 grounded unload credit too high: {ground_unload}")
if ground_lift > 1e-9:
    raise SystemExit(f"liftoff-gate V4 grounded lift credit should be zero: {ground_lift}")

# Physical airborne probe using the reverse spawn. Stage-6 training still uses
# zero assisted-spawn probability; this call exists only for verification.
_, spawn_fn = b.spawn_families[0]
spawn_fn(env)
physical = env._foot_contacts()
if physical["right"]:
    raise SystemExit("liftoff-gate V4 physical check failed: pre-lift right foot still touches floor")
env.foot_contact_state = {"left": True, "right": False}
air_pen = terms["right_foot_ground_contact"].fn(env)
air_unload = terms["right_foot_unloaded"].fn(env)
air_lift = terms["foot_in_air"].fn(env)
if abs(air_pen) > 1e-9:
    raise SystemExit(f"liftoff-gate V4 airborne penalty should be zero: {air_pen}")
if air_unload < 0.99:
    raise SystemExit(f"liftoff-gate V4 airborne unload reward too low: {air_unload}")
if air_lift <= 0.0:
    raise SystemExit(f"liftoff-gate V4 airborne lift reward should be positive: {air_lift}")

print("✓ one_leg liftoff-gate V4 physical reward ordering passed")
print(f"  grounded: contact_pen={ground_pen:.2f}, unload={ground_unload:.3f}, hold={ground_hold:.3f}, lift={ground_lift:.3f}")
print(f"  airborne: contact_pen={air_pen:.2f}, unload={air_unload:.3f}, lift={air_lift:.3f}")
env.close()
PY
)
