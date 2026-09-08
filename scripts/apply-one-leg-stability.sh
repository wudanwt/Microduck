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

# Keep the human-facing label aligned with the actual target in core.py.
s = s.replace(
    'Points for holding the right foot ~5 cm off the ground',
    'Points for holding the right foot ~8 cm off the ground',
)

# ---------------------------------------------------------------------------
# Helper 1: positive reward for a genuinely quiet hover near 8 cm.
# ---------------------------------------------------------------------------
if "def _right_foot_stable_hover(env)" not in s:
    helper = r'''
# MICRODUCK_USER_ONE_LEG_STABILITY_V3
# Positive reward: right foot near 8 cm AND moving slowly vertically.
def _right_foot_stable_hover(env) -> float:
    if env.foot_contact_state["right"]:
        return 0.0

    h = _foot_z(env, "right") - _foot_z(env, "left")
    height_score = float(np.exp(-((h - 0.08) ** 2) / 0.03 ** 2))

    v6 = _v6_buf(env)
    mujoco.mj_objectVelocity(
        env.model,
        env.data,
        mujoco.mjtObj.mjOBJ_GEOM,
        env.foot_geoms["right"],
        v6,
        0,
    )
    vz = float(v6[5])
    still_score = float(np.exp(-(vz * vz) / 0.08 ** 2))
    return height_score * still_score

'''
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate the first behavior registration in poses.py; upstream changed.")
    s = s[:idx] + helper + s[idx:]

# ---------------------------------------------------------------------------
# Helper 2: direct penalty for lifted-foot vertical pumping.
# Use right-vs-left relative vertical speed so whole-body vertical correction
# is not mistaken for the right leg pumping by itself.
# Below 5 cm there is no penalty, so the policy is free to perform the lift.
# ---------------------------------------------------------------------------
if "def _right_foot_vertical_motion_pen(env)" not in s:
    helper2 = r'''
def _right_foot_vertical_motion_pen(env) -> float:
    if env.foot_contact_state["right"]:
        return 0.0

    h = _foot_z(env, "right") - _foot_z(env, "left")
    if h < 0.05:
        return 0.0

    v6 = _v6_buf(env)
    mujoco.mj_objectVelocity(
        env.model,
        env.data,
        mujoco.mjtObj.mjOBJ_GEOM,
        env.foot_geoms["right"],
        v6,
        0,
    )
    right_vz = float(v6[5])

    # The scratch buffer is overwritten by each call, but right_vz is already
    # copied to a Python float before the second query.
    mujoco.mj_objectVelocity(
        env.model,
        env.data,
        mujoco.mjtObj.mjOBJ_GEOM,
        env.foot_geoms["left"],
        v6,
        0,
    )
    left_vz = float(v6[5])

    rel_vz = right_vz - left_vz
    return -min((rel_vz / 0.04) ** 2, 1.0)

'''
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate behavior registration in poses.py; upstream changed.")
    s = s[:idx] + helper2 + s[idx:]

# ---------------------------------------------------------------------------
# Structurally locate the one_leg Behavior block. Do not depend on an older
# overlay's formatting or insertion order.
# ---------------------------------------------------------------------------
one_start = s.find('id="one_leg"')
if one_start < 0:
    raise SystemExit("Could not locate one_leg behavior; upstream changed.")
one_end = s.find('default_steps=', one_start)
if one_end < 0:
    raise SystemExit("Could not locate end of one_leg reward recipe; upstream changed.")

prefix = s[:one_start]
block = s[one_start:one_end]
suffix = s[one_end:]

foot_pat = re.compile(
    r'(?m)^(?P<indent>[ \t]*)RewardTerm\("foot_in_air",\s*'
    r'"Points for holding the right foot ~8 cm off the ground",\s*'
    r'1\.5,\s*_lift_up_L\),'
)
m = foot_pat.search(block)
if not m:
    raise SystemExit("Could not locate one_leg foot_in_air reward; upstream changed.")
indent = m.group("indent")

stable_block = (
    f'{indent}RewardTerm(\n'
    f'{indent}    "right_foot_stable_hover",\n'
    f'{indent}    "Big points for holding the right foot steady near 8 cm",\n'
    f'{indent}    2.0,\n'
    f'{indent}    _right_foot_stable_hover,\n'
    f'{indent}),'
)

if '"right_foot_stable_hover"' not in block:
    insert_at = m.end()
    block = block[:insert_at] + "\n" + stable_block + block[insert_at:]

# Insert the penalty before flat_stance_foot. That anchor exists in every
# supported one_leg recipe and does not depend on how V1 formatted the custom
# stable-hover block.
if '"right_foot_vertical_motion"' not in block:
    flat_match = re.search(
        r'(?m)^(?P<indent>[ \t]*)RewardTerm\("flat_stance_foot",',
        block,
    )
    if not flat_match:
        raise SystemExit("Could not locate one_leg flat_stance_foot reward; upstream changed.")
    ind = flat_match.group("indent")
    motion_block = (
        f'{ind}RewardTerm(\n'
        f'{ind}    "right_foot_vertical_motion",\n'
        f'{ind}    "Penalty for moving the lifted right foot up and down after it is raised",\n'
        f'{ind}    2.0,\n'
        f'{ind}    _right_foot_vertical_motion_pen,\n'
        f'{ind}    is_penalty=True,\n'
        f'{ind}),\n'
    )
    insert_at = flat_match.start()
    block = block[:insert_at] + motion_block + block[insert_at:]

s = prefix + block + suffix
path.write_text(s)

# Text-level verification before Python imports anything heavy.
one_start = s.find('id="one_leg"')
one_end = s.find('default_steps=', one_start)
one = s[one_start:one_end]
missing = [
    key for key in ("right_foot_stable_hover", "right_foot_vertical_motion")
    if f'"{key}"' not in one
]
if missing:
    raise SystemExit("one_leg overlay verification failed; missing: " + ", ".join(missing))

print("✓ one_leg stability V3 source patch verified")
print("  reward : right_foot_stable_hover (default 2.0)")
print("  penalty: right_foot_vertical_motion (default 2.0)")
PY

# Runtime verification using the same uv environment the lab will launch with.
(
  cd "$LOCAL"
  uv run python - <<'PY'
from microduck_local.behaviors import BEHAVIORS
keys = [t.key for t in BEHAVIORS["one_leg"].terms]
required = ["right_foot_stable_hover", "right_foot_vertical_motion"]
missing = [k for k in required if k not in keys]
if missing:
    raise SystemExit("one_leg runtime verification failed; missing: " + ", ".join(missing))
print("✓ one_leg runtime rewards:", ", ".join(k for k in keys if k.startswith("right_foot_")))
PY
)
