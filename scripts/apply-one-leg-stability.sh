#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/microduck-lab/microduck_local/src/microduck_local/behaviors/poses.py"

if [ ! -f "$TARGET" ]; then
  echo "Microduck Lab behavior file not found: $TARGET" >&2
  echo "Run: git submodule update --init --recursive" >&2
  exit 1
fi

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
s = path.read_text()

# Keep the upstream-friendly text aligned with the real target in core.py.
s = s.replace(
    'Points for holding the right foot ~5 cm off the ground',
    'Points for holding the right foot ~8 cm off the ground',
    1,
)

# ---------------------------------------------------------------------------
# 1) Positive reward: height near 8 cm AND low absolute vertical velocity.
#    This helped reduce the original large pumping motion, but a slow periodic
#    oscillation can still score reasonably well, so V2 adds a direct penalty
#    below as well.
# ---------------------------------------------------------------------------
if "def _right_foot_stable_hover(env)" not in s:
    helper = r'''
# MICRODUCK_USER_ONE_LEG_STABILITY_V2
# User overlay: reward a TRUE static hover of the lifted right foot instead of
# merely rewarding that it passes through a broad height band.
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
# 2) Direct penalty for periodic pumping AFTER the right foot is already up.
#    Use right-vs-left RELATIVE vertical speed so a whole-body vertical balance
#    correction is not mistaken for the lifted leg pumping by itself.
#
#    Below 5 cm: no penalty, so the policy is still free to lift the foot.
#    Above 5 cm: |relative vz| ~= 0.04 m/s reaches the full -1 penalty.
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
# Inject the two terms into one_leg.  Idempotent on already-patched checkouts.
# ---------------------------------------------------------------------------
foot_line = 'RewardTerm("foot_in_air", "Points for holding the right foot ~8 cm off the ground", 1.5, _lift_up_L),'
if foot_line not in s:
    raise SystemExit("Could not locate one_leg foot_in_air reward; upstream changed.")

stable_block = '''RewardTerm(
            "right_foot_stable_hover",
            "Big points for holding the right foot steady near 8 cm",
            2.0,
            _right_foot_stable_hover,
        ),'''

if '"right_foot_stable_hover",' not in s:
    s = s.replace(foot_line, foot_line + "\n        " + stable_block, 1)

motion_block = '''RewardTerm(
            "right_foot_vertical_motion",
            "Penalty for moving the lifted right foot up and down after it is raised",
            2.0,
            _right_foot_vertical_motion_pen,
            is_penalty=True,
        ),'''

if '"right_foot_vertical_motion",' not in s:
    # Put the direct penalty immediately after the stable-hover reward so the
    # two user-added controls stay next to each other in the recipe source.
    if stable_block not in s:
        raise SystemExit("Could not locate stable-hover reward block for V2 migration.")
    s = s.replace(stable_block, stable_block + "\n        " + motion_block, 1)

path.write_text(s)
print("✓ one_leg stability V2 rewards applied")
print("  reward : right_foot_stable_hover (default weight 2.0)")
print("  penalty: right_foot_vertical_motion (default weight 2.0)")
print("  motion penalty activates after ~5 cm lift; full around 0.04 m/s relative vertical speed")
PY
