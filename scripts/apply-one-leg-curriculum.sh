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
# MICRODUCK_USER_ONE_LEG_CURRICULUM_V1
#
# A single end-state recipe kept converging to the same local optimum:
# body COM near the two-foot centre + the lifted right leg pumping to rescue
# balance.  Teach the causal skill in order instead:
#   1) move COM over the LEFT foot while both feet may still touch,
#   2) lift the right foot only 2.5 cm,
#   3) raise it to 5 cm,
#   4) reach the final 8 cm target with light damping,
#   5) keep 8 cm while full anti-oscillation penalties polish the hold.
#
# The lab's native CurriculumStage chain fine-tunes stage N from stage N-1.
# Per-stage env knobs are read with _spawn_knob(), so the same recipe also
# previews the correct stage inside the long-running browser lab.
# ---------------------------------------------------------------------------
helper = r'''
# MICRODUCK_USER_ONE_LEG_CURRICULUM_V1
def _one_leg_stage(env) -> int:
    try:
        return max(1, min(5, int(float(_spawn_knob(
            env, "MICRODUCK_ONELEG_STAGE", "5") or "5"))))
    except (TypeError, ValueError):
        return 5


def _one_leg_target_h(env) -> float:
    try:
        return float(_spawn_knob(
            env, "MICRODUCK_ONELEG_TARGET_H", "0.080") or "0.080")
    except (TypeError, ValueError):
        return 0.080


def _one_leg_stage_hold(env) -> float:
    """Stage 1 allows both feet down; later stages require right foot airborne.

    In every stage the payout is explicitly coupled to the lateral COM score,
    so a leg-pumping solution cannot collect the full main hold reward while
    the body stays between the feet.
    """
    contacts = env.foot_contact_state
    if not contacts["left"]:
        return 0.0
    stage = _one_leg_stage(env)
    if stage >= 2 and contacts["right"]:
        return 0.0
    com = _com_over_left_stance_foot(env)
    # Keep some upright credit alive while COM is still moving, but make the
    # correct support solution much more valuable than the old centred pose.
    return _upright(env) * (0.20 + 0.80 * com)


def _one_leg_stage_lift(env) -> float:
    stage = _one_leg_stage(env)
    if stage <= 1 or env.foot_contact_state["right"]:
        return 0.0
    h = _foot_z(env, "right") - _foot_z(env, "left")
    target = _one_leg_target_h(env)
    # Wide enough that the next curriculum step is reachable from the previous
    # one, while still making each stage's intended height the clear maximum.
    std = 0.025 if stage <= 3 else 0.030
    return float(np.exp(-((h - target) ** 2) / std ** 2))


def _one_leg_stage_stable_hover(env) -> float:
    stage = _one_leg_stage(env)
    if stage <= 1 or env.foot_contact_state["right"]:
        return 0.0

    h = _foot_z(env, "right") - _foot_z(env, "left")
    target = _one_leg_target_h(env)
    height_std = 0.025 if stage <= 3 else 0.030
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

    # Early stages allow active exploration.  The tolerance tightens only as
    # the target height approaches the finished skill.
    still_std = {2: 0.12, 3: 0.10, 4: 0.08, 5: 0.06}.get(stage, 0.06)
    still_score = float(np.exp(-(rel_vz * rel_vz) / still_std ** 2))
    return height_score * still_score


def _one_leg_stage_vertical_motion_pen(env) -> float:
    stage = _one_leg_stage(env)
    if stage < 4:
        return 0.0
    base = _right_foot_vertical_motion_pen(env)
    return 0.5 * base if stage == 4 else base


def _one_leg_stage_direction_reversal_pen(env) -> float:
    if _one_leg_stage(env) < 5:
        return 0.0
    return _right_foot_direction_reversal_pen(env)


def _one_leg_stage_height_error_pen(env) -> float:
    if _one_leg_stage(env) < 4:
        return 0.0
    return _right_foot_height_error_pen(env)


def _one_leg_stage_oscillation_pen(env) -> float:
    if _one_leg_stage(env) < 5:
        # Clear the old window while the term is disabled so stage 5 does not
        # inherit stale samples from a previous preview/reset.
        env._rf_osc_hist = []
        return 0.0
    return _right_foot_oscillation_pen(env)

'''

if "# MICRODUCK_USER_ONE_LEG_CURRICULUM_V1" not in s:
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate first behavior registration; upstream changed.")
    s = s[:idx] + helper + s[idx:]

# Locate the complete one_leg Behavior registration.
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

# Redirect the existing sliders to curriculum-aware implementations.  Keys and
# weights stay unchanged, so the user's existing UI / saved recipes remain
# readable; only the underlying goal changes by stage.
redirects = {
    "one_leg_hold": "_one_leg_stage_hold",
    "foot_in_air": "_one_leg_stage_lift",
    "right_foot_stable_hover": "_one_leg_stage_stable_hover",
    "right_foot_vertical_motion": "_one_leg_stage_vertical_motion_pen",
    "right_foot_direction_reversal": "_one_leg_stage_direction_reversal_pen",
    "right_foot_height_error": "_one_leg_stage_height_error_pen",
    "right_foot_oscillation": "_one_leg_stage_oscillation_pen",
}
for key, fn in redirects.items():
    block = replace_term_fn(block, key, fn)

# The curriculum's declared steps sum to 6M.  If the Teach panel chooses a
# different TOTAL budget, viz_server proportionally scales these ratios rather
# than multiplying the user's number by five.
block = re.sub(
    r'default_steps\s*=\s*[0-9_]+',
    'default_steps=6_000_000',
    block,
    count=1,
)

if "curriculum=(" not in block:
    needle = "    symmetric=False,"
    if needle not in block:
        raise SystemExit("Could not locate one_leg symmetric=False anchor.")
    curriculum = r'''
    curriculum=(
        CurriculumStage(
            "阶段 1：把重心压到左脚",
            1_000_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "1",
                "MICRODUCK_ONELEG_TARGET_H": "0.000",
                "MICRODUCK_EPISODE_S": "12",
            },
            detail="右脚暂时允许着地；先保持身体直立，并把横向重心真正搬到左支撑脚上。",
        ),
        CurriculumStage(
            "阶段 2：右脚轻轻离地 2.5 cm",
            1_000_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "2",
                "MICRODUCK_ONELEG_TARGET_H": "0.025",
                "MICRODUCK_EPISODE_S": "12",
            },
            detail="在左脚已经承重的基础上，只要求右脚小幅离地；暂时不处罚周期抖动。",
        ),
        CurriculumStage(
            "阶段 3：把右脚抬到 5 cm",
            1_200_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "3",
                "MICRODUCK_ONELEG_TARGET_H": "0.050",
                "MICRODUCK_EPISODE_S": "14",
            },
            detail="保持重心在左脚附近，再逐步增加抬脚高度，让单脚静态姿态先成形。",
        ),
        CurriculumStage(
            "阶段 4：达到 8 cm 并稳住",
            1_200_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "4",
                "MICRODUCK_ONELEG_TARGET_H": "0.080",
                "MICRODUCK_EPISODE_S": "16",
            },
            detail="达到最终 8 cm 高度，并开始轻度处罚右脚上下运动与高度漂移。",
        ),
        CurriculumStage(
            "阶段 5：消除最后的周期抖动",
            1_600_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "5",
                "MICRODUCK_ONELEG_TARGET_H": "0.080",
                "MICRODUCK_EPISODE_S": "20",
            },
            detail="保持最终姿态，启用完整的垂直速度、换向和时间窗口振荡惩罚，做静态平衡精修。",
        ),
    ),'''
    block = block.replace(needle, needle + curriculum, 1)

s = s[:reg_start] + block + s[reg_end:]
path.write_text(s)

# Source verification.
s = path.read_text()
one_id = s.find('id="one_leg"')
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id) + len("\n))")
one = s[reg_start:reg_end]
required = [
    "# MICRODUCK_USER_ONE_LEG_CURRICULUM_V1",
    "_one_leg_stage_hold",
    "_one_leg_stage_lift",
    "_one_leg_stage_stable_hover",
    "_one_leg_stage_vertical_motion_pen",
    "_one_leg_stage_direction_reversal_pen",
    "_one_leg_stage_height_error_pen",
    "_one_leg_stage_oscillation_pen",
    "阶段 1：把重心压到左脚",
    "阶段 5：消除最后的周期抖动",
    "default_steps=6_000_000",
]
missing = [x for x in required if x not in s and x not in one]
if "curriculum=(" not in one:
    missing.append("curriculum=( in one_leg")
if missing:
    raise SystemExit("one_leg curriculum source verification failed: " + ", ".join(missing))

print("✓ one_leg staged curriculum source patch verified")
print("  stage 1: lateral COM over left foot; right foot may stay down")
print("  stage 2: right foot target 2.5 cm")
print("  stage 3: right foot target 5 cm")
print("  stage 4: right foot target 8 cm + light vertical damping")
print("  stage 5: 8 cm static hold + full anti-oscillation polish")
print("  default total budget: 6.0M steps")
PY

# Runtime verification in the exact environment used by duck-lab.
(
  cd "$LOCAL"
  uv run python - <<'PY'
from microduck_local.behaviors import BEHAVIORS

b = BEHAVIORS["one_leg"]
if len(b.curriculum) != 5:
    raise SystemExit(f"one_leg curriculum runtime verification failed: {len(b.curriculum)} stages")
expected = ["1", "2", "3", "4", "5"]
actual = [st.env.get("MICRODUCK_ONELEG_STAGE") for st in b.curriculum]
if actual != expected:
    raise SystemExit(f"one_leg curriculum stage knobs wrong: {actual}")
keys = {t.key: t.fn.__name__ for t in b.terms}
required = {
    "one_leg_hold": "_one_leg_stage_hold",
    "foot_in_air": "_one_leg_stage_lift",
    "right_foot_stable_hover": "_one_leg_stage_stable_hover",
    "right_foot_vertical_motion": "_one_leg_stage_vertical_motion_pen",
    "right_foot_direction_reversal": "_one_leg_stage_direction_reversal_pen",
    "right_foot_height_error": "_one_leg_stage_height_error_pen",
    "right_foot_oscillation": "_one_leg_stage_oscillation_pen",
}
wrong = {k: (keys.get(k), v) for k, v in required.items() if keys.get(k) != v}
if wrong:
    raise SystemExit(f"one_leg curriculum runtime reward redirects wrong: {wrong}")
print("✓ one_leg staged curriculum runtime verified")
for i, st in enumerate(b.curriculum, 1):
    print(f"  {i}. {st.label} · {st.steps:,} declared steps")
PY
)
