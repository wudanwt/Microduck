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
# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V2
#
# V1 used the full XY distance between whole-robot COM and the left-foot
# centre. That made harmless fore/aft offset compete with the thing a one-leg
# balance actually needs most: shifting the body LATERALLY over the stance leg.
# V2 keeps the same mass-weighted whole-robot COM, but scores only the lateral
# component in the trunk heading frame. This is yaw-invariant and gives PPO a
# direct gradient for "move the body over the left support leg".
# ---------------------------------------------------------------------------
helper_v2 = r'''
# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V2
def _com_over_left_stance_foot(env) -> float:
    # No meaningful support target when the stance foot itself is airborne.
    if not env.foot_contact_state["left"]:
        return 0.0

    # Whole-robot mass-weighted COM from MuJoCo inertial-frame positions.
    # body 0 is the world body (zero mass), so skip it.
    masses = np.asarray(env.model.body_mass[1:], dtype=float)
    total_mass = float(masses.sum())
    if total_mass <= 1e-12:
        return 0.0

    body_xy = np.asarray(env.data.xipos[1:, :2], dtype=float)
    com_xy = (body_xy * masses[:, None]).sum(axis=0) / total_mass

    left_gid = env.foot_geoms["left"]
    foot_xy = np.asarray(env.data.geom_xpos[left_gid, :2], dtype=float)

    # Use the trunk's local +Y axis projected onto the ground as the robot's
    # lateral axis. Unlike raw world-Y, this remains correct if the duck yaws.
    trunk_R = np.asarray(env.data.xmat[env.trunk_body_id], dtype=float).reshape(3, 3)
    lateral_xy = trunk_R[:2, 1].copy()
    norm = float(np.linalg.norm(lateral_xy))
    if norm <= 1e-9:
        return 0.0
    lateral_xy /= norm

    # Only the sideways COM offset matters here; fore/aft displacement is left
    # to the existing stance/body terms instead of being falsely taxed.
    lateral_error = abs(float(np.dot(com_xy - foot_xy, lateral_xy)))

    # Treat the central +/-5 mm as effectively "inside the support target".
    # Outside it, blend a broad and a tight Gaussian so PPO still has useful
    # gradient when the COM is 1-3 cm away, while strongly preferring a true
    # settled stance. Approximate score after the free band:
    #   10 mm total error -> ~0.87, 15 mm -> ~0.61,
    #   20 mm -> ~0.40, 30 mm -> ~0.18.
    excess = max(lateral_error - 0.005, 0.0)
    if excess <= 0.0:
        return 1.0
    broad = float(np.exp(-((excess / 0.025) ** 2)))
    tight = float(np.exp(-((excess / 0.010) ** 2)))
    return 0.5 * broad + 0.5 * tight

'''

# Migrate an already-patched V1 checkout in place. V1's helper was inserted
# immediately before the first behavior registration. Preserve all other user
# reward overlays and keep the public reward key stable so existing runs can
# continue fine-tuning without schema churn.
if "# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V1" in s:
    pat = re.compile(
        r'(?ms)^# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V1\n'
        r'def _com_over_left_stance_foot\(env\) -> float:\n.*?'
        r'(?=^_register\(Behavior\()'
    )
    s, count = pat.subn(helper_v2, s, count=1)
    if count != 1:
        raise SystemExit("Could not migrate one-leg COM-balance V1 helper; local source changed.")
elif "# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V2" not in s:
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate first behavior registration; upstream changed.")
    s = s[:idx] + helper_v2 + s[idx:]

# Keep the existing reward key so old run recipes can load, but update the
# friendly sentence to describe what V2 actually optimizes.
s = s.replace(
    "Big points for keeping the body center of mass over the left stance foot",
    "Big points for shifting the body center of mass sideways over the left stance foot",
)

# Locate only the one_leg reward block.
one_start = s.find('id="one_leg"')
if one_start < 0:
    raise SystemExit("Could not locate one_leg behavior; upstream changed.")
one_end = s.find('default_steps=', one_start)
if one_end < 0:
    raise SystemExit("Could not locate end of one_leg reward recipe; upstream changed.")

prefix = s[:one_start]
block = s[one_start:one_end]
suffix = s[one_end:]

if '"com_over_stance_foot"' not in block:
    flat_match = re.search(
        r'(?m)^(?P<indent>[ \t]*)RewardTerm\("flat_stance_foot",',
        block,
    )
    if not flat_match:
        raise SystemExit("Could not locate one_leg flat_stance_foot reward; upstream changed.")
    ind = flat_match.group("indent")
    term = (
        f'{ind}RewardTerm(\n'
        f'{ind}    "com_over_stance_foot",\n'
        f'{ind}    "Big points for shifting the body center of mass sideways over the left stance foot",\n'
        f'{ind}    2.0,\n'
        f'{ind}    _com_over_left_stance_foot,\n'
        f'{ind}),\n'
    )
    block = block[:flat_match.start()] + term + block[flat_match.start():]

s = prefix + block + suffix
path.write_text(s)

# Text-level verification.
s = path.read_text()
one_start = s.find('id="one_leg"')
one_end = s.find('default_steps=', one_start)
one = s[one_start:one_end]
required = [
    "# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V2",
    "def _com_over_left_stance_foot(env)",
    '"com_over_stance_foot"',
    "body_mass[1:]",
    "xipos[1:, :2]",
    "xmat[env.trunk_body_id]",
    "lateral_error",
    "0.005",
]
missing = [x for x in required if x not in s and x != '"com_over_stance_foot"']
if '"com_over_stance_foot"' not in one:
    missing.append('"com_over_stance_foot" in one_leg')
if missing:
    raise SystemExit("one_leg COM-balance V2 source verification failed: " + ", ".join(missing))

print("✓ one_leg COM-balance V2 source patch verified")
print("  reward : com_over_stance_foot (same key; existing runs stay compatible)")
print("  target : lateral whole-robot COM aligned over the left stance foot")
print("  frame  : trunk local +Y projected to ground (yaw-invariant)")
print("  shape  : ±5 mm free target, then broad 2.5 cm + tight 1.0 cm guidance")
PY

# Runtime verification in the exact environment used by duck-lab.
(
  cd "$LOCAL"
  uv run python - <<'PY'
import inspect
from microduck_local.behaviors import BEHAVIORS
from microduck_local.behaviors import poses

keys = [t.key for t in BEHAVIORS["one_leg"].terms]
if "com_over_stance_foot" not in keys:
    raise SystemExit("one_leg COM-balance V2 runtime reward missing")

src = inspect.getsource(poses._com_over_left_stance_foot)
for needle in (
    "body_mass[1:]",
    "xipos[1:, :2]",
    "xmat[env.trunk_body_id]",
    "lateral_error",
    "0.005",
):
    if needle not in src:
        raise SystemExit(f"one_leg COM-balance V2 runtime helper verification failed: {needle}")

print("✓ one_leg COM-balance V2 runtime reward present")
PY
)
