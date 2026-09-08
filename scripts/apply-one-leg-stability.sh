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
marker = "# MICRODUCK_USER_ONE_LEG_STABILITY_V1"

helper = r'''
# MICRODUCK_USER_ONE_LEG_STABILITY_V1
# User overlay: reward a TRUE static hover of the lifted right foot instead of
# merely rewarding that it passes through a broad height band.  The stock
# foot_in_air term only scores height; a policy can therefore oscillate up and
# down and still collect good reward.  This term multiplies height accuracy by
# a zero-vertical-speed score, so the best solution is: lift to ~8 cm, then
# settle there.
def _right_foot_stable_hover(env) -> float:
    if env.foot_contact_state["right"]:
        return 0.0

    # Same physical target as the current one-leg height reward: ~8 cm above
    # the stance foot.  A 3 cm Gaussian keeps a useful gradient around the
    # already-learned pose while making the optimum more precise.
    h = _foot_z(env, "right") - _foot_z(env, "left")
    height_score = float(np.exp(-((h - 0.08) ** 2) / 0.03 ** 2))

    # mj_objectVelocity returns [angular xyz, linear xyz].  World-frame linear
    # z is index 5.  At |vz| ~= 0.08 m/s the stillness score is e^-1; faster
    # vertical pumping rapidly loses the bonus, while small balance corrections
    # remain possible.
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

if marker not in s:
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate the first behavior registration in poses.py; upstream changed.")
    s = s[:idx] + helper + s[idx:]

old = 'RewardTerm("foot_in_air", "Points for holding the right foot ~5 cm off the ground", 1.5, _lift_up_L),'
new = '''RewardTerm("foot_in_air", "Points for holding the right foot ~8 cm off the ground", 1.5, _lift_up_L),
        RewardTerm(
            "right_foot_stable_hover",
            "Big points for holding the right foot steady near 8 cm",
            2.0,
            _right_foot_stable_hover,
        ),'''

if "right_foot_stable_hover" not in s[s.find("terms=("):]:
    if old not in s:
        # Be tolerant of a future upstream text-only fix from 5 cm -> 8 cm.
        old8 = 'RewardTerm("foot_in_air", "Points for holding the right foot ~8 cm off the ground", 1.5, _lift_up_L),'
        if old8 not in s:
            raise SystemExit("Could not locate one_leg foot_in_air reward; upstream changed.")
        s = s.replace(old8, new, 1)
    else:
        s = s.replace(old, new, 1)
else:
    # Even when the custom term is already present, correct the stale upstream
    # friendly text if this checkout still says 5 cm.
    s = s.replace(
        'Points for holding the right foot ~5 cm off the ground',
        'Points for holding the right foot ~8 cm off the ground',
        1,
    )

path.write_text(s)
print("✓ one_leg stable-hover reward applied")
print("  new term: right_foot_stable_hover (default weight 2.0)")
print("  target: ~8 cm height, vertical speed -> 0")
PY
