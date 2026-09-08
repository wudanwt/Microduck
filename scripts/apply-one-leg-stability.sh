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

# Keep the friendly label aligned with the actual current target in core.py.
s = s.replace(
    'Points for holding the right foot ~5 cm off the ground',
    'Points for holding the right foot ~8 cm off the ground',
)

# ---------------------------------------------------------------------------
# Helper 1: positive reward for a genuinely quiet hover near 8 cm.
# ---------------------------------------------------------------------------
if "def _right_foot_stable_hover(env)" not in s:
    helper = r'''
# MICRODUCK_USER_ONE_LEG_STABILITY_V4
# Positive reward: right foot near 8 cm AND moving slowly vertically.
def _right_foot_stable_hover(env) -> float:
    if env.foot_contact_state["right"]:
        return 0.0

    h = _foot_z(env, "right") - _foot_z(env, "left")
    height_score = float(np.exp(-((h - 0.08) ** 2) / 0.03 ** 2))

    v6 = _v6_buf(env)
    mujoco.mj_objectVelocity(
        env.model, env.data, mujoco.mjtObj.mjOBJ_GEOM,
        env.foot_geoms["right"], v6, 0,
    )
    vz = float(v6[5])
    still_score = float(np.exp(-(vz * vz) / 0.08 ** 2))
    return height_score * still_score

'''
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate first behavior registration; upstream changed.")
    s = s[:idx] + helper + s[idx:]

# ---------------------------------------------------------------------------
# Helper 2: direct penalty for lifted-foot vertical pumping.
# It uses right-vs-left relative vertical speed so whole-body vertical motion
# is not mistaken for the lifted leg pumping by itself.
# ---------------------------------------------------------------------------
if "def _right_foot_vertical_motion_pen(env)" not in s:
    helper = r'''
def _right_foot_vertical_motion_pen(env) -> float:
    if env.foot_contact_state["right"]:
        return 0.0

    h = _foot_z(env, "right") - _foot_z(env, "left")
    if h < 0.05:
        return 0.0

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
    return -min((rel_vz / 0.04) ** 2, 1.0)

'''
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate behavior registration; upstream changed.")
    s = s[:idx] + helper + s[idx:]

# ---------------------------------------------------------------------------
# Helper 3: penalize repeated UP<->DOWN reversals after the foot is lifted.
#
# Why this exists: a low-frequency sinusoidal leg pump can have modest speed,
# so the speed penalty alone may plateau.  This term detects direction changes
# outside a deadband and briefly latches a penalty.  At 50 Hz a 6-step latch is
# ~0.12 s: periodic pumping is expensive, while an occasional balance correction
# is still allowed.
# ---------------------------------------------------------------------------
if "def _right_foot_direction_reversal_pen(env)" not in s:
    helper = r'''
def _right_foot_direction_reversal_pen(env) -> float:
    h = _foot_z(env, "right") - _foot_z(env, "left")

    # Reset state while the foot is down / still being lifted. This also makes
    # episode resets safe without requiring a hook into the environment reset.
    if env.foot_contact_state["right"] or h < 0.05:
        env._rf_rev_last_sign = 0
        env._rf_rev_latch = 0
        return 0.0

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

    # Tiny corrections below 1.2 cm/s are treated as stationary.  Keep the
    # previous non-zero direction across the deadband so a true reversal that
    # passes through zero is still detected.
    deadband = 0.012
    sign = 1 if rel_vz > deadband else (-1 if rel_vz < -deadband else 0)
    last = int(getattr(env, "_rf_rev_last_sign", 0))
    latch = int(getattr(env, "_rf_rev_latch", 0))

    if sign != 0:
        if last != 0 and sign != last:
            latch = 6
        env._rf_rev_last_sign = sign

    if latch > 0:
        env._rf_rev_latch = latch - 1
        return -1.0

    env._rf_rev_latch = 0
    return 0.0

'''
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate behavior registration; upstream changed.")
    s = s[:idx] + helper + s[idx:]

# ---------------------------------------------------------------------------
# Structurally locate the one_leg recipe. This supports original/V1/V2/V3 local
# checkouts and only inserts terms that are missing.
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

if '"right_foot_stable_hover"' not in block:
    stable = (
        f'{indent}RewardTerm(\n'
        f'{indent}    "right_foot_stable_hover",\n'
        f'{indent}    "Big points for holding the right foot steady near 8 cm",\n'
        f'{indent}    2.0,\n'
        f'{indent}    _right_foot_stable_hover,\n'
        f'{indent}),'
    )
    block = block[:m.end()] + "\n" + stable + block[m.end():]

# All custom penalties go immediately before flat_stance_foot so migration from
# older overlays does not depend on the formatting of previously inserted terms.
flat_match = re.search(
    r'(?m)^(?P<indent>[ \t]*)RewardTerm\("flat_stance_foot",',
    block,
)
if not flat_match:
    raise SystemExit("Could not locate one_leg flat_stance_foot reward; upstream changed.")
ind = flat_match.group("indent")

insertions = []
if '"right_foot_vertical_motion"' not in block:
    insertions.append(
        f'{ind}RewardTerm(\n'
        f'{ind}    "right_foot_vertical_motion",\n'
        f'{ind}    "Penalty for moving the lifted right foot up and down after it is raised",\n'
        f'{ind}    2.0,\n'
        f'{ind}    _right_foot_vertical_motion_pen,\n'
        f'{ind}    is_penalty=True,\n'
        f'{ind}),\n'
    )
if '"right_foot_direction_reversal"' not in block:
    insertions.append(
        f'{ind}RewardTerm(\n'
        f'{ind}    "right_foot_direction_reversal",\n'
        f'{ind}    "Penalty for repeatedly reversing the lifted right foot up and down",\n'
        f'{ind}    2.0,\n'
        f'{ind}    _right_foot_direction_reversal_pen,\n'
        f'{ind}    is_penalty=True,\n'
        f'{ind}),\n'
    )

if insertions:
    # Re-find because block may have changed when stable_hover was inserted.
    flat_match = re.search(
        r'(?m)^(?P<indent>[ \t]*)RewardTerm\("flat_stance_foot",',
        block,
    )
    block = block[:flat_match.start()] + "".join(insertions) + block[flat_match.start():]

s = prefix + block + suffix
path.write_text(s)

# Text-level verification.
one_start = s.find('id="one_leg"')
one_end = s.find('default_steps=', one_start)
one = s[one_start:one_end]
required = (
    "right_foot_stable_hover",
    "right_foot_vertical_motion",
    "right_foot_direction_reversal",
)
missing = [key for key in required if f'"{key}"' not in one]
if missing:
    raise SystemExit("one_leg V4 source verification failed; missing: " + ", ".join(missing))

print("✓ one_leg stability V4 source patch verified")
print("  reward : right_foot_stable_hover (default 2.0)")
print("  penalty: right_foot_vertical_motion (default 2.0)")
print("  penalty: right_foot_direction_reversal (default 2.0)")
print("  reversal detector: >5 cm lift, 0.012 m/s deadband, 6-step (~0.12 s) latch")
PY

# Runtime verification using the same uv environment the lab launches with.
(
  cd "$LOCAL"
  uv run python - <<'PY'
from microduck_local.behaviors import BEHAVIORS
keys = [t.key for t in BEHAVIORS["one_leg"].terms]
required = [
    "right_foot_stable_hover",
    "right_foot_vertical_motion",
    "right_foot_direction_reversal",
]
missing = [k for k in required if k not in keys]
if missing:
    raise SystemExit("one_leg V4 runtime verification failed; missing: " + ", ".join(missing))
print("✓ one_leg runtime rewards:", ", ".join(k for k in keys if k.startswith("right_foot_")))
PY
)
