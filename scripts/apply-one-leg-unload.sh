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

helper = r'''
# MICRODUCK_USER_ONE_LEG_UNLOAD_V1
def _one_leg_foot_normal_forces(env) -> tuple[float, float]:
    """Return summed floor-normal contact force on (left, right) feet."""
    floor = env.floor_geom
    left_gid = env.foot_geoms["left"]
    right_gid = env.foot_geoms["right"]
    left_n = 0.0
    right_n = 0.0
    f6 = getattr(env, "_one_leg_contact_force_scratch", None)
    if f6 is None:
        f6 = env._one_leg_contact_force_scratch = np.zeros(6)
    for i in range(env.data.ncon):
        con = env.data.contact[i]
        a = int(con.geom1)
        b = int(con.geom2)
        if a == floor:
            other = b
        elif b == floor:
            other = a
        else:
            continue
        if other != left_gid and other != right_gid:
            continue
        mujoco.mj_contactForce(env.model, env.data, i, f6)
        normal = abs(float(f6[0]))
        if other == left_gid:
            left_n += normal
        else:
            right_n += normal
    return left_n, right_n


def _right_foot_unload_score(env) -> float:
    """1 when the right foot is unloaded/airborne; smooth credit while unloading."""
    if _one_leg_stage(env) <= 1:
        return 0.0
    if not env.foot_contact_state["right"]:
        return 1.0
    left_n, right_n = _one_leg_foot_normal_forces(env)
    total = left_n + right_n
    if total <= 1e-6:
        return 0.0
    right_share = float(np.clip(right_n / total, 0.0, 1.0))
    # Broad Gaussian: ~0.13 at 50% load, ~0.48 at 30%, ~0.72 at 20%,
    # ~0.92 at 10%, and 1.0 at zero load. This gives PPO a physical slope
    # toward unloading before it ever has to cross the binary contact boundary.
    return float(np.exp(-((right_share / 0.35) ** 2)))

'''

if "# MICRODUCK_USER_ONE_LEG_UNLOAD_V1" not in s:
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate first behavior registration")
    s = s[:idx] + helper + s[idx:]

# Re-shape the curriculum-aware hold/lift helpers so grounded reward depends on
# unloading force, not only on geometric foot height.
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
    else:
        # While still grounded, moving load OFF the right foot matters much
        # more than merely tilting the foot upward.
        support = 0.08 + 0.52 * unload + 0.20 * progress
    return base * support


'''
s, count = hold_pat.subn(hold_new, s, count=1)
if count != 1:
    raise SystemExit("Could not patch _one_leg_stage_hold")

lift_pat = re.compile(
    r'(?ms)^def _one_leg_stage_lift\(env\) -> float:\n.*?(?=^def _one_leg_stage_stable_hover\(env\) -> float:)'
)
lift_new = r'''def _one_leg_stage_lift(env) -> float:
    stage = _one_leg_stage(env)
    if stage <= 1:
        return 0.0

    _, _, progress, target_score, airborne = _one_leg_clearance(env)
    if not airborne:
        unload = _right_foot_unload_score(env)
        # First unload, then lift. Height progress is deliberately gated by
        # unloading so a loaded foot cannot game the reward by rolling/tilting.
        return unload * (0.15 + 0.85 * progress)
    return 0.25 + 0.75 * target_score


'''
s, count = lift_pat.subn(lift_new, s, count=1)
if count != 1:
    raise SystemExit("Could not patch _one_leg_stage_lift")

# Add a visible reward term so the Teach scorecard shows whether unloading is
# actually improving before liftoff.
one_id = s.find('id="one_leg"')
if one_id < 0:
    raise SystemExit("Could not locate one_leg behavior")
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id)
if reg_start < 0 or reg_end < 0:
    raise SystemExit("Could not locate one_leg registration")
reg_end += len("\n))")
block = s[reg_start:reg_end]

if '"right_foot_unloaded"' not in block:
    foot = re.search(
        r'(?ms)(?P<indent>^[ \t]*)RewardTerm\(\s*"foot_in_air".*?\),',
        block,
    )
    if not foot:
        raise SystemExit("Could not locate foot_in_air term")
    ind = foot.group("indent")
    term = (
        f'\n{ind}RewardTerm(\n'
        f'{ind}    "right_foot_unloaded",\n'
        f'{ind}    "Points for shifting load off the right foot before lifting",\n'
        f'{ind}    3.0,\n'
        f'{ind}    _right_foot_unload_score,\n'
        f'{ind}),' 
    )
    block = block[:foot.end()] + term + block[foot.end():]

# Rebalance curriculum time: do not over-train the two-foot stage.
repls = {
    '"阶段 1：重心左移 + 双脚保持平整",\n            900_000,': '"阶段 1：重心左移 + 双脚保持平整",\n            300_000,',
    '"阶段 2：卸载右脚并抬到 1.5 cm",\n            700_000,': '"阶段 2：卸载右脚并抬到 1.5 cm",\n            1_300_000,',
    '"阶段 3：右脚抬到 3 cm",\n            800_000,': '"阶段 3：右脚抬到 3 cm",\n            900_000,',
    '"阶段 5：达到最终 8 cm",\n            1_100_000,': '"阶段 5：达到最终 8 cm",\n            1_000_000,',
}
for old, new in repls.items():
    block = block.replace(old, new)

s = s[:reg_start] + block + s[reg_end:]
path.write_text(s)

# Source verification.
s = path.read_text()
one_id = s.find('id="one_leg"')
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id) + len("\n))")
one = s[reg_start:reg_end]
for needle in (
    "# MICRODUCK_USER_ONE_LEG_UNLOAD_V1",
    "def _one_leg_foot_normal_forces(env)",
    "def _right_foot_unload_score(env)",
    '"right_foot_unloaded"',
    "mj_contactForce",
    "unload * (0.15 + 0.85 * progress)",
):
    if needle not in s and needle not in one:
        raise SystemExit(f"one_leg unload source verification failed: {needle}")

print("✓ one_leg unload/contact-force shaping source patch verified")
print("  reward : right_foot_unloaded (default 3.0)")
print("  signal : MuJoCo floor-normal contact force share")
print("  stage 1: 0.3M (short COM-transfer warmup)")
print("  stage 2: 1.3M (unload right foot -> 1.5 cm lift)")
PY

(
  cd "$LOCAL"
  uv run python - <<'PY'
from microduck_local.behaviors import BEHAVIORS
b = BEHAVIORS["one_leg"]
keys = {t.key: t.fn.__name__ for t in b.terms}
if keys.get("right_foot_unloaded") != "_right_foot_unload_score":
    raise SystemExit(f"right_foot_unloaded runtime binding wrong: {keys.get('right_foot_unloaded')}")
steps = [st.steps for st in b.curriculum]
expected = [300_000, 1_300_000, 900_000, 1_000_000, 1_000_000, 1_500_000]
if steps != expected:
    raise SystemExit(f"one_leg unload curriculum step split wrong: {steps}")
print("✓ one_leg unload/contact-force shaping runtime verified")
print("  curriculum steps:", steps)
PY
)
