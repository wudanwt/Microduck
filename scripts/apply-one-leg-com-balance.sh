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

# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V1
# Reward the underlying static-balance solution instead of only punishing the
# visible symptom (the lifted right foot pumping). We compute the full robot's
# mass-weighted horizontal center of mass from MuJoCo body inertial positions,
# then reward it for sitting over the LEFT stance foot.
if "def _com_over_left_stance_foot(env)" not in s:
    helper = r'''
# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V1
def _com_over_left_stance_foot(env) -> float:
    # No meaningful support target when the stance foot itself is airborne.
    if not env.foot_contact_state["left"]:
        return 0.0

    # MuJoCo xipos is the world position of each body's inertial frame (its COM).
    # Ignore body 0 (world, zero mass), then form the whole-robot mass-weighted
    # horizontal COM. Static balance wants this projection inside the support
    # area; the foot centre is a simple, robust target for this first version.
    masses = np.asarray(env.model.body_mass[1:], dtype=float)
    total_mass = float(masses.sum())
    if total_mass <= 1e-12:
        return 0.0

    body_xy = np.asarray(env.data.xipos[1:, :2], dtype=float)
    com_xy = (body_xy * masses[:, None]).sum(axis=0) / total_mass

    left_gid = env.foot_geoms["left"]
    foot_xy = np.asarray(env.data.geom_xpos[left_gid, :2], dtype=float)
    dist = float(np.linalg.norm(com_xy - foot_xy))

    # Two scales: a broad layer gives PPO a gradient even when the COM is still
    # a few cm away; a tight layer rewards actually settling over the stance foot.
    # Rough interpretation: ~0.8 at 1 cm, ~0.47 at 2 cm, ~0.29 at 3 cm.
    broad = float(np.exp(-((dist / 0.04) ** 2)))
    tight = float(np.exp(-((dist / 0.015) ** 2)))
    return 0.5 * broad + 0.5 * tight

'''
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate first behavior registration; upstream changed.")
    s = s[:idx] + helper + s[idx:]

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
        f'{ind}    "Big points for keeping the body center of mass over the left stance foot",\n'
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
    "# MICRODUCK_USER_ONE_LEG_COM_BALANCE_V1",
    "def _com_over_left_stance_foot(env)",
    '"com_over_stance_foot"',
    "body_mass[1:]",
    "xipos[1:, :2]",
]
missing = [x for x in required if x not in s and x != '"com_over_stance_foot"']
if '"com_over_stance_foot"' not in one:
    missing.append('"com_over_stance_foot" in one_leg')
if missing:
    raise SystemExit("one_leg COM-balance source verification failed: " + ", ".join(missing))

print("✓ one_leg COM-balance source patch verified")
print("  reward : com_over_stance_foot (default 2.0)")
print("  target : whole-robot COM projection over the left stance-foot centre")
print("  shape  : broad 4 cm + tight 1.5 cm Gaussian guidance")
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
    raise SystemExit("one_leg COM-balance runtime reward missing")

src = inspect.getsource(poses._com_over_left_stance_foot)
for needle in ("body_mass[1:]", "xipos[1:, :2]", "foot_geoms[\"left\"]"):
    if needle not in src:
        raise SystemExit(f"one_leg COM-balance runtime helper verification failed: {needle}")

print("✓ one_leg COM-balance runtime reward present")
PY
)
