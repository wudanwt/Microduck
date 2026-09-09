#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL="$ROOT/microduck-lab/microduck_local"
TARGET="$LOCAL/src/microduck_local/behaviors/poses.py"

if [ ! -f "$TARGET" ]; then
  echo "Microduck Lab behavior file not found: $TARGET" >&2
  echo "Run: git submodule update --init --recursive" >&2
  exit 1
fi

python3 - "$TARGET" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
s = path.read_text()

# ---------------------------------------------------------------------------
# MICRODUCK_USER_ONE_LEG_CURRICULUM_V2
#
# V1 correctly separated "shift weight" from "lift the foot", but two loopholes
# showed up in live training:
#   1) stage 1 could satisfy the COM term by splaying/tilting both feet instead
#      of learning a clean body-over-left-leg support posture;
#   2) stage 2 paid ZERO lift reward while the right foot still touched the
#      floor, making the very first unload/lift a sparse event.
#
# V2 closes both gaps:
#   - stage 1 scores BOTH feet flat while learning lateral COM transfer;
#   - stages 2+ use DENSE clearance progress even before contact breaks;
#   - the main hold reward also rises smoothly with right-foot clearance rather
#     than jumping from almost nothing to full credit at contact loss;
#   - height targets advance 1.5 -> 3 -> 5 -> 8 cm, then a final polish stage
#     turns on the full anti-oscillation penalties.
# ---------------------------------------------------------------------------
helper_v2 = r'''
# MICRODUCK_USER_ONE_LEG_CURRICULUM_V2
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
    """Stage 1 forbids the splayed-feet shortcut; later only stance foot matters."""
    if _one_leg_stage(env) <= 1:
        return _flat_feet(env)
    return _ONE_LEG_LEFT_FLAT(env)


def _one_leg_clearance(env) -> tuple[float, float, float, float, bool]:
    """(height, target, progress 0..1, target score, airborne).

    Crucially, `progress` exists while the right foot is STILL touching.  That
    gives PPO a slope for unloading/peeling the foot off the floor instead of
    waiting for a random action to cross a binary contact boundary first.
    """
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
        # Once clear of the floor, reward settling near the stage target.
        support = 0.70 + 0.30 * target_score
    else:
        # No binary cliff: a grounded foot starts at small credit and earns
        # progressively more only by actually lifting/unloading upward.
        support = 0.12 + 0.58 * progress
    return base * support


def _one_leg_stage_lift(env) -> float:
    stage = _one_leg_stage(env)
    if stage <= 1:
        return 0.0

    _, _, progress, target_score, airborne = _one_leg_clearance(env)
    if not airborne:
        # Dense pre-liftoff shaping. At h=0 this is intentionally small but
        # non-zero; every millimetre upward produces an immediate advantage.
        return 0.08 * target_score + 0.92 * progress

    # Crossing the contact boundary gets a modest bonus, but the maximum still
    # lives at the requested target height rather than "barely off the floor".
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

    # Early lift stages are permissive; only the finished skill is very quiet.
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
    # The underlying term targets 8 cm, so do not turn it on during the 1.5/3/5
    # cm teaching stages or it would fight the curriculum target.
    if _one_leg_stage(env) < 5:
        return 0.0
    return _right_foot_height_error_pen(env)


def _one_leg_stage_oscillation_pen(env) -> float:
    if _one_leg_stage(env) < 6:
        env._rf_osc_hist = []
        return 0.0
    return _right_foot_oscillation_pen(env)

'''

# Migrate a local checkout already patched by V1. The curriculum helper is the
# last helper inserted before the first behavior registration, so replace only
# its marked block and preserve the other one-leg reward overlays above it.
if "# MICRODUCK_USER_ONE_LEG_CURRICULUM_V1" in s:
    pat = re.compile(
        r'(?ms)^# MICRODUCK_USER_ONE_LEG_CURRICULUM_V1\n'
        r'def _one_leg_stage\(env\) -> int:\n.*?'
        r'(?=^_register\(Behavior\()'
    )
    s, count = pat.subn(helper_v2, s, count=1)
    if count != 1:
        raise SystemExit("Could not migrate one-leg curriculum V1 helper; local source changed.")
elif "# MICRODUCK_USER_ONE_LEG_CURRICULUM_V2" not in s:
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate first behavior registration; upstream changed.")
    s = s[:idx] + helper_v2 + s[idx:]

# Locate complete one_leg registration.
one_id = s.find('id="one_leg"')
if one_id < 0:
    raise SystemExit("Could not locate one_leg behavior; upstream changed.")
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id)
if reg_start < 0 or reg_end < 0:
    raise SystemExit("Could not locate complete one_leg registration; upstream changed.")
reg_end += len("\n))")
block = s[reg_start:reg_end]


def replace_term_fn(text: str, key: str, new_fn: str) -> str:
    pat = re.compile(
        r'(RewardTerm\(\s*"' + re.escape(key) +
        r'"\s*,\s*"[^"]*"\s*,\s*[-+0-9.eE]+\s*,\s*)'
        r'([A-Za-z_][A-Za-z0-9_]*)',
        re.S,
    )
    out, count = pat.subn(lambda m: m.group(1) + new_fn, text, count=1)
    if count != 1:
        raise SystemExit(f"Could not redirect one_leg reward function for {key}")
    return out

# Keep public reward keys/sliders stable; redirect their implementation by stage.
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
    block = replace_term_fn(block, key, fn)

block = re.sub(
    r'default_steps\s*=\s*[0-9_]+',
    'default_steps=6_000_000',
    block,
    count=1,
)

curriculum_v2 = r'''    curriculum=(
        CurriculumStage(
            "阶段 1：重心左移 + 双脚保持平整",
            900_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "1",
                "MICRODUCK_ONELEG_TARGET_H": "0.000",
                "MICRODUCK_EPISODE_S": "12",
            },
            detail="右脚暂时允许着地，但两只脚都要尽量平放；目标是用身体与关节把横向重心搬到左脚，而不是把脚掌向两侧撇开。",
        ),
        CurriculumStage(
            "阶段 2：卸载右脚并抬到 1.5 cm",
            700_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "2",
                "MICRODUCK_ONELEG_TARGET_H": "0.015",
                "MICRODUCK_EPISODE_S": "12",
            },
            detail="右脚还接触地面时也按抬高进度连续给分，让策略先学会卸载、翘起，再跨过真正离地的接触边界。",
        ),
        CurriculumStage(
            "阶段 3：右脚抬到 3 cm",
            800_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "3",
                "MICRODUCK_ONELEG_TARGET_H": "0.030",
                "MICRODUCK_EPISODE_S": "13",
            },
            detail="从已经会离地的策略继续提高右脚，同时保持左脚承重与身体直立。",
        ),
        CurriculumStage(
            "阶段 4：右脚抬到 5 cm",
            1_000_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "4",
                "MICRODUCK_ONELEG_TARGET_H": "0.050",
                "MICRODUCK_EPISODE_S": "14",
            },
            detail="把单脚姿态稳定成形；此阶段仍不启用针对 8 cm 的高度误差处罚。",
        ),
        CurriculumStage(
            "阶段 5：达到最终 8 cm",
            1_100_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "5",
                "MICRODUCK_ONELEG_TARGET_H": "0.080",
                "MICRODUCK_EPISODE_S": "16",
            },
            detail="达到最终高度，并只使用较轻的上下运动处罚和 8 cm 高度约束，避免过早压死探索。",
        ),
        CurriculumStage(
            "阶段 6：静态平衡精修与消抖",
            1_500_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "6",
                "MICRODUCK_ONELEG_TARGET_H": "0.080",
                "MICRODUCK_EPISODE_S": "20",
            },
            detail="保持 8 cm 单脚姿态，启用完整的垂直速度、换向与时间窗口振荡惩罚，专门消除周期性抖腿。",
        ),
    ),'''

# Replace V1/V2 curriculum wholesale when present; otherwise insert it after
# symmetric=False. It sits at the end of the Behavior registration by design.
cur_pat = re.compile(r'(?ms)^    curriculum=\(\n.*?^    \),(?=\n\)\))')
if cur_pat.search(block):
    block = cur_pat.sub(curriculum_v2, block, count=1)
else:
    needle = "    symmetric=False,"
    if needle not in block:
        raise SystemExit("Could not locate one_leg symmetric=False anchor.")
    block = block.replace(needle, needle + "\n" + curriculum_v2, 1)

s = s[:reg_start] + block + s[reg_end:]
path.write_text(s)

# Source verification.
s = path.read_text()
one_id = s.find('id="one_leg"')
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id) + len("\n))")
one = s[reg_start:reg_end]
required = [
    "# MICRODUCK_USER_ONE_LEG_CURRICULUM_V2",
    "_one_leg_stage_flat_support",
    "_one_leg_clearance",
    "_one_leg_stage_hold",
    "_one_leg_stage_lift",
    "_one_leg_stage_stable_hover",
    "_one_leg_stage_vertical_motion_pen",
    "_one_leg_stage_direction_reversal_pen",
    "_one_leg_stage_height_error_pen",
    "_one_leg_stage_oscillation_pen",
    "阶段 1：重心左移 + 双脚保持平整",
    "阶段 2：卸载右脚并抬到 1.5 cm",
    "阶段 6：静态平衡精修与消抖",
    "default_steps=6_000_000",
]
missing = [x for x in required if x not in s and x not in one]
if "curriculum=(" not in one:
    missing.append("curriculum=( in one_leg")
if missing:
    raise SystemExit("one_leg curriculum V2 source verification failed: " + ", ".join(missing))

print("✓ one_leg staged curriculum V2 source patch verified")
print("  stage 1: COM left + BOTH feet flat (blocks splayed-foot shortcut)")
print("  stage 2: dense unload/lift shaping -> 1.5 cm")
print("  stage 3: 3 cm")
print("  stage 4: 5 cm")
print("  stage 5: 8 cm + light damping")
print("  stage 6: 8 cm + full anti-oscillation polish")
print("  default total budget: 6.0M steps")
PY

# Runtime verification in the exact environment used by duck-lab.
(
  cd "$LOCAL"
  uv run python - <<'PY'
from microduck_local.behaviors import BEHAVIORS

b = BEHAVIORS["one_leg"]
if len(b.curriculum) != 6:
    raise SystemExit(f"one_leg curriculum V2 runtime verification failed: {len(b.curriculum)} stages")
expected = ["1", "2", "3", "4", "5", "6"]
actual = [st.env.get("MICRODUCK_ONELEG_STAGE") for st in b.curriculum]
if actual != expected:
    raise SystemExit(f"one_leg curriculum V2 stage knobs wrong: {actual}")
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
    raise SystemExit(f"one_leg curriculum V2 runtime reward redirects wrong: {wrong}")
print("✓ one_leg staged curriculum V2 runtime verified")
for i, st in enumerate(b.curriculum, 1):
    print(f"  {i}. {st.label} · {st.steps:,} declared steps")
PY
)
