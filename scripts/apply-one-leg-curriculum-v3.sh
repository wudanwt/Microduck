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

# V3 keeps the V2 curriculum semantics, but fixes the installer itself:
# RewardTerm callables may be factories such as _stance_flat("left").
# Replacing only the identifier left a dangling ("left"), producing
# _one_leg_stage_flat_support("left") and crashing module import.  V3 replaces
# the whole callable expression and repairs already-corrupted local sources.
helper_v3 = r'''
# MICRODUCK_USER_ONE_LEG_CURRICULUM_V3
def _one_leg_stage(env) -> int:
    try:
        return max(1, min(6, int(float(_spawn_knob(
            env, "MICRODUCK_ONELEG_STAGE", "6") or "6"))))
    except (TypeError, ValueError):
        return 6


def _one_leg_target_h(env) -> float:
    try:
        return float(_spawn_knob(
            env, "MICRODUCK_ONELEG_TARGET_H", "0.080") or "0.080")
    except (TypeError, ValueError):
        return 0.080


_ONE_LEG_LEFT_FLAT = _stance_flat("left")


def _one_leg_stage_flat_support(env) -> float:
    """Stage 1 blocks the splayed-feet shortcut; later only left foot matters."""
    if _one_leg_stage(env) <= 1:
        return _flat_feet(env)
    return _ONE_LEG_LEFT_FLAT(env)


def _one_leg_clearance(env) -> tuple[float, float, float, float, bool]:
    h = max(_foot_z(env, "right") - _foot_z(env, "left"), 0.0)
    target = max(_one_leg_target_h(env), 1e-4)
    progress = float(np.clip(h / target, 0.0, 1.0))
    stage = _one_leg_stage(env)
    std = 0.020 if stage <= 2 else (0.025 if stage <= 4 else 0.030)
    target_score = float(np.exp(-((h - target) ** 2) / std ** 2))
    airborne = not env.foot_contact_state["right"]
    return h, target, progress, target_score, airborne


def _one_leg_stage_hold(env) -> float:
    contacts = env.foot_contact_state
    if not contacts["left"]:
        return 0.0

    com = _com_over_left_stance_foot(env)
    base = _upright(env) * (0.20 + 0.80 * com)
    stage = _one_leg_stage(env)
    if stage <= 1:
        return base

    _, _, progress, target_score, airborne = _one_leg_clearance(env)
    if airborne:
        support = 0.70 + 0.30 * target_score
    else:
        support = 0.12 + 0.58 * progress
    return base * support


def _one_leg_stage_lift(env) -> float:
    stage = _one_leg_stage(env)
    if stage <= 1:
        return 0.0

    _, _, progress, target_score, airborne = _one_leg_clearance(env)
    if not airborne:
        # Dense pre-liftoff shaping: even while touching the floor, every mm of
        # upward clearance improves the score.
        return 0.08 * target_score + 0.92 * progress
    return 0.25 + 0.75 * target_score


def _one_leg_stage_stable_hover(env) -> float:
    stage = _one_leg_stage(env)
    if stage <= 1 or env.foot_contact_state["right"]:
        return 0.0

    h, target, _, _, _ = _one_leg_clearance(env)
    height_std = 0.020 if stage <= 2 else (0.025 if stage <= 4 else 0.030)
    height_score = float(np.exp(-((h - target) ** 2) / height_std ** 2))

    v6 = _v6_buf(env)
    mujoco.mj_objectVelocity(
        env.model, env.data, mujoco.mjtObj.mjOBJ_GEOM,
        env.foot_geoms["right"], v6, 0,
    )
    right_vz = float(v6[5])
    mujoco.mj_objectVelocity(
        env.model, env.data, mujoco.mjtObj.mjOBJ_GEOM,
        env.foot_geoms["left"], v6, 0,
    )
    left_vz = float(v6[5])
    rel_vz = right_vz - left_vz

    still_std = {2: 0.14, 3: 0.12, 4: 0.10, 5: 0.08, 6: 0.06}.get(stage, 0.06)
    still_score = float(np.exp(-(rel_vz * rel_vz) / still_std ** 2))
    return height_score * still_score


def _one_leg_stage_vertical_motion_pen(env) -> float:
    stage = _one_leg_stage(env)
    if stage < 5:
        return 0.0
    base = _right_foot_vertical_motion_pen(env)
    return 0.45 * base if stage == 5 else base


def _one_leg_stage_direction_reversal_pen(env) -> float:
    if _one_leg_stage(env) < 6:
        return 0.0
    return _right_foot_direction_reversal_pen(env)


def _one_leg_stage_height_error_pen(env) -> float:
    if _one_leg_stage(env) < 5:
        return 0.0
    return _right_foot_height_error_pen(env)


def _one_leg_stage_oscillation_pen(env) -> float:
    if _one_leg_stage(env) < 6:
        env._rf_osc_hist = []
        return 0.0
    return _right_foot_oscillation_pen(env)

'''

# Upgrade any older curriculum helper in place. The curriculum helper is the
# final helper before the first behavior registration.
if "# MICRODUCK_USER_ONE_LEG_CURRICULUM_V3" not in s:
    migrated = False
    for old in ("V2", "V1"):
        marker = f"# MICRODUCK_USER_ONE_LEG_CURRICULUM_{old}"
        if marker in s:
            pat = re.compile(
                rf'(?ms)^{re.escape(marker)}\n'
                r'def _one_leg_stage\(env\) -> int:\n.*?'
                r'(?=^_register\(Behavior\()'
            )
            s, count = pat.subn(helper_v3, s, count=1)
            if count != 1:
                raise SystemExit(f"Could not migrate curriculum {old} helper")
            migrated = True
            break
    if not migrated:
        anchor = "_register(Behavior("
        idx = s.find(anchor)
        if idx < 0:
            raise SystemExit("Could not locate first behavior registration")
        s = s[:idx] + helper_v3 + s[idx:]

# Locate the complete one_leg Behavior registration.
one_id = s.find('id="one_leg"')
if one_id < 0:
    raise SystemExit("Could not locate one_leg behavior")
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id)
if reg_start < 0 or reg_end < 0:
    raise SystemExit("Could not locate complete one_leg registration")
reg_end += len("\n))")
block = s[reg_start:reg_end]


def redirect_term(text: str, key: str, new_fn: str) -> str:
    # Match the ENTIRE callable expression, including a simple factory call.
    # Handles all of these safely:
    #   _lift_up_L
    #   _one_leg_stage_lift
    #   _stance_flat("left")
    #   _one_leg_stage_flat_support("left")   <- repairs V2 corruption
    pat = re.compile(
        r'(RewardTerm\(\s*"' + re.escape(key) +
        r'"\s*,\s*"[^"]*"\s*,\s*[-+0-9.eE]+\s*,\s*)'
        r'[A-Za-z_][A-Za-z0-9_]*(?:\s*\([^()\n]*\))?',
        re.S,
    )
    out, count = pat.subn(lambda m: m.group(1) + new_fn, text, count=1)
    if count != 1:
        raise SystemExit(f"Could not redirect one_leg reward function for {key}")
    return out

redirects = {
    "one_leg_hold": "_one_leg_stage_hold",
    "foot_in_air": "_one_leg_stage_lift",
    "right_foot_stable_hover": "_one_leg_stage_stable_hover",
    "right_foot_vertical_motion": "_one_leg_stage_vertical_motion_pen",
    "right_foot_direction_reversal": "_one_leg_stage_direction_reversal_pen",
    "right_foot_height_error": "_one_leg_stage_height_error_pen",
    "right_foot_oscillation": "_one_leg_stage_oscillation_pen",
    "flat_stance_foot": "_one_leg_stage_flat_support",
}
for key, fn in redirects.items():
    block = redirect_term(block, key, fn)

block = re.sub(r'default_steps\s*=\s*[0-9_]+', 'default_steps=6_000_000', block, count=1)

# Remove any previously inserted curriculum. We always insert curriculum as the
# final Behavior field, so deleting from its field start to the outer close is
# deterministic and avoids fragile nested-parenthesis regexes.
cur_idx = block.find("\n    curriculum=(")
if cur_idx >= 0:
    block = block[:cur_idx] + "\n))"

curriculum = r'''    curriculum=(
        CurriculumStage(
            "阶段 1：重心左移 + 双脚保持平整",
            900_000,
            env={"MICRODUCK_ONELEG_STAGE": "1", "MICRODUCK_ONELEG_TARGET_H": "0.000", "MICRODUCK_EPISODE_S": "12"},
            detail="右脚暂时允许着地，但两只脚都要尽量平放；用身体与关节把横向重心搬到左脚。",
        ),
        CurriculumStage(
            "阶段 2：卸载右脚并抬到 1.5 cm",
            700_000,
            env={"MICRODUCK_ONELEG_STAGE": "2", "MICRODUCK_ONELEG_TARGET_H": "0.015", "MICRODUCK_EPISODE_S": "12"},
            detail="右脚还接触地面时也按抬高进度连续给分，先学会卸载、翘起，再真正离地。",
        ),
        CurriculumStage(
            "阶段 3：右脚抬到 3 cm",
            800_000,
            env={"MICRODUCK_ONELEG_STAGE": "3", "MICRODUCK_ONELEG_TARGET_H": "0.030", "MICRODUCK_EPISODE_S": "13"},
            detail="从已经会离地的策略继续提高右脚，同时保持左脚承重。",
        ),
        CurriculumStage(
            "阶段 4：右脚抬到 5 cm",
            1_000_000,
            env={"MICRODUCK_ONELEG_STAGE": "4", "MICRODUCK_ONELEG_TARGET_H": "0.050", "MICRODUCK_EPISODE_S": "14"},
            detail="把单脚姿态稳定成形，此阶段仍不启用针对 8 cm 的高度误差处罚。",
        ),
        CurriculumStage(
            "阶段 5：达到最终 8 cm",
            1_100_000,
            env={"MICRODUCK_ONELEG_STAGE": "5", "MICRODUCK_ONELEG_TARGET_H": "0.080", "MICRODUCK_EPISODE_S": "16"},
            detail="达到最终高度，并使用较轻的上下运动处罚与 8 cm 高度约束。",
        ),
        CurriculumStage(
            "阶段 6：静态平衡精修与消抖",
            1_500_000,
            env={"MICRODUCK_ONELEG_STAGE": "6", "MICRODUCK_ONELEG_TARGET_H": "0.080", "MICRODUCK_EPISODE_S": "20"},
            detail="保持 8 cm 单脚姿态，启用完整的垂直速度、换向与时间窗口振荡惩罚。",
        ),
    ),'''

if not block.endswith("\n))"):
    raise SystemExit("one_leg registration close changed unexpectedly")
block = block[:-len("\n))")] + "\n" + curriculum + "\n))"

s = s[:reg_start] + block + s[reg_end:]
path.write_text(s)

# Source verification catches the exact regression that broke the user's run.
s = path.read_text()
one_id = s.find('id="one_leg"')
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id) + len("\n))")
one = s[reg_start:reg_end]
if '_one_leg_stage_flat_support("left")' in one or "_one_leg_stage_flat_support('left')" in one:
    raise SystemExit("V3 repair failed: dangling flat-support factory argument remains")
for key, fn in redirects.items():
    if f'"{key}"' not in one or fn not in one:
        raise SystemExit(f"V3 source verification failed for {key} -> {fn}")
if "# MICRODUCK_USER_ONE_LEG_CURRICULUM_V3" not in s:
    raise SystemExit("V3 helper marker missing")
if one.count("CurriculumStage(") != 6:
    raise SystemExit(f"Expected 6 curriculum stages, found {one.count('CurriculumStage(')}")

print("✓ one_leg staged curriculum V3 source patch verified")
print("  repaired callable replacement: factory calls are replaced as a whole")
print("  stage 1: COM left + BOTH feet flat")
print("  stage 2: dense unload/lift shaping -> 1.5 cm")
print("  stage 3: 3 cm")
print("  stage 4: 5 cm")
print("  stage 5: 8 cm + light damping")
print("  stage 6: 8 cm + full anti-oscillation polish")
print("  default total budget: 6.0M steps")
PY

(
  cd "$LOCAL"
  uv run python - <<'PY'
from microduck_local.behaviors import BEHAVIORS

b = BEHAVIORS["one_leg"]
if len(b.curriculum) != 6:
    raise SystemExit(f"one_leg curriculum V3 runtime verification failed: {len(b.curriculum)} stages")
expected = ["1", "2", "3", "4", "5", "6"]
actual = [st.env.get("MICRODUCK_ONELEG_STAGE") for st in b.curriculum]
if actual != expected:
    raise SystemExit(f"one_leg curriculum V3 stage knobs wrong: {actual}")
keys = {t.key: t.fn.__name__ for t in b.terms}
required = {
    "one_leg_hold": "_one_leg_stage_hold",
    "foot_in_air": "_one_leg_stage_lift",
    "right_foot_stable_hover": "_one_leg_stage_stable_hover",
    "right_foot_vertical_motion": "_one_leg_stage_vertical_motion_pen",
    "right_foot_direction_reversal": "_one_leg_stage_direction_reversal_pen",
    "right_foot_height_error": "_one_leg_stage_height_error_pen",
    "right_foot_oscillation": "_one_leg_stage_oscillation_pen",
    "flat_stance_foot": "_one_leg_stage_flat_support",
}
wrong = {k: (keys.get(k), v) for k, v in required.items() if keys.get(k) != v}
if wrong:
    raise SystemExit(f"one_leg curriculum V3 runtime reward redirects wrong: {wrong}")
print("✓ one_leg staged curriculum V3 runtime verified")
for i, st in enumerate(b.curriculum, 1):
    print(f"  {i}. {st.label} · {st.steps:,} declared steps")
PY
)
