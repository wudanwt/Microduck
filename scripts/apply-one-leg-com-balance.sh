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
# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V3
#
# V2 fixed the axis: it scores only the LATERAL COM offset from the left stance
# foot.  The latest run showed the duck still ~4 cm off-target, where V2's two
# relatively narrow Gaussians paid only ~0.06 raw.  That is too little shaping
# signal for PPO to discover a structural body shift from an already-trained
# policy.
#
# V3 keeps the same physically meaningful lateral target and +/-5 mm free band,
# but adds a deliberately broad 6 cm pull plus medium/tight polish layers:
#   - broad  6.0 cm : keeps a useful gradient alive 4-8 cm away
#   - medium 2.5 cm : pulls decisively once the body enters the right region
#   - tight  1.0 cm : rewards the final static alignment
# This is the same wide-pull -> tight-polish principle used elsewhere in the
# lab's mature reward recipes.
# ---------------------------------------------------------------------------
helper_v3 = r'''
# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V3
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

    # Only sideways COM offset matters here; fore/aft displacement is handled
    # by the existing stance/body terms.
    lateral_error = abs(float(np.dot(com_xy - foot_xy, lateral_xy)))

    # +/-5 mm is effectively centered over the stance foot.
    excess = max(lateral_error - 0.005, 0.0)
    if excess <= 0.0:
        return 1.0

    # Wide pull -> medium capture -> tight polish.
    # Approximate scores vs TOTAL lateral error (including the 5 mm free band):
    #   1.0 cm -> ~0.94
    #   2.0 cm -> ~0.70
    #   3.0 cm -> ~0.52
    #   4.0 cm -> ~0.40
    #   5.0 cm -> ~0.30
    # so an already-trained policy several cm away still gets a strong gradient.
    broad = float(np.exp(-((excess / 0.060) ** 2)))
    medium = float(np.exp(-((excess / 0.025) ** 2)))
    tight = float(np.exp(-((excess / 0.010) ** 2)))
    return 0.50 * broad + 0.30 * medium + 0.20 * tight

'''

# Migrate an already-patched V1/V2 checkout in place. Preserve all other user
# overlays and keep the public reward key stable so existing runs can continue
# fine-tuning without schema churn.
if "# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V2" in s:
    pat = re.compile(
        r'(?ms)^# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V2\n'
        r'def _com_over_left_stance_foot\(env\) -> float:\n.*?'
        r'(?=^_register\(Behavior\()'
    )
    s, count = pat.subn(helper_v3, s, count=1)
    if count != 1:
        raise SystemExit("Could not migrate one-leg COM-balance V2 helper; local source changed.")
elif "# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V1" in s:
    pat = re.compile(
        r'(?ms)^# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V1\n'
        r'def _com_over_left_stance_foot\(env\) -> float:\n.*?'
        r'(?=^_register\(Behavior\()'
    )
    s, count = pat.subn(helper_v3, s, count=1)
    if count != 1:
        raise SystemExit("Could not migrate one-leg COM-balance V1 helper; local source changed.")
elif "# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V3" not in s:
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate first behavior registration; upstream changed.")
    s = s[:idx] + helper_v3 + s[idx:]

# Keep the existing reward key and friendly sentence.
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
    "# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V3",
    "def _com_over_left_stance_foot(env)",
    '"com_over_stance_foot"',
    "body_mass[1:]",
    "xipos[1:, :2]",
    "xmat[env.trunk_body_id]",
    "lateral_error",
    "excess / 0.060",
    "excess / 0.025",
    "excess / 0.010",
]
missing = [x for x in required if x not in s and x != '"com_over_stance_foot"']
if '"com_over_stance_foot"' not in one:
    missing.append('"com_over_stance_foot" in one_leg')
if missing:
    raise SystemExit("one_leg COM-balance V3 source verification failed: " + ", ".join(missing))

print("✓ one_leg COM-balance V3 source patch verified")
print("  reward : com_over_stance_foot (same key; existing runs stay compatible)")
print("  target : lateral whole-robot COM aligned over the left stance foot")
print("  frame  : trunk local +Y projected to ground (yaw-invariant)")
print("  shape  : ±5 mm target + 6.0 cm broad / 2.5 cm medium / 1.0 cm tight")
print("  intent : keep useful learning gradient alive even 4-8 cm off target")
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
    raise SystemExit("one_leg COM-balance V3 runtime reward missing")

src = inspect.getsource(poses._com_over_left_stance_foot)
for needle in (
    "body_mass[1:]",
    "xipos[1:, :2]",
    "xmat[env.trunk_body_id]",
    "lateral_error",
    "0.060",
    "0.025",
    "0.010",
):
    if needle not in src:
        raise SystemExit(f"one_leg COM-balance V3 runtime helper verification failed: {needle}")

print("✓ one_leg COM-balance V3 runtime reward present")
PY
)
