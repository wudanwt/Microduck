#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POSES="$ROOT/microduck-lab/microduck_local/src/microduck_local/behaviors/poses.py"

if [ ! -f "$POSES" ]; then
  echo "Microduck Lab behavior file not found: $POSES" >&2
  exit 1
fi

python3 - "$POSES" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
s = path.read_text()
original = s
repairs: list[str] = []

# Repair the exact corruption produced by curriculum V2 when it replaced only
# the identifier of the original factory callable _stance_flat("left"), leaving
# the argument list behind.
s2 = re.sub(
    r'_one_leg_stage_flat_support\s*\(\s*["\']left["\']\s*\)',
    '_one_leg_stage_flat_support',
    s,
)
if s2 != s:
    repairs.append("removed stale flat-support factory argument")
    s = s2

# Older reverse-assist installers replaced their whole helper region up to the
# first Behavior registration. Any helpers installed later in that same region
# could therefore disappear while their RewardTerm callables remained behind.
# Add tiny import-safe stubs ONLY when a callable is referenced but its function
# definition is missing. The proper installers later in start-lab overwrite or
# replace these stubs with the real implementations.
stubs: list[str] = []
if "_right_foot_ground_contact_penalty" in s and "def _right_foot_ground_contact_penalty(" not in s:
    stubs.append(
        'def _right_foot_ground_contact_penalty(env) -> float:\n'
        '    """Preflight stub; replaced by the liftoff-gate installer."""\n'
        '    return 0.0\n\n'
    )
    repairs.append("restored missing ground-contact helper stub")

if "_one_leg_airborne_com_score" in s and "def _one_leg_airborne_com_score(" not in s:
    stubs.append(
        'def _one_leg_airborne_com_score(env) -> float:\n'
        '    """Preflight stub; replaced by the airborne-COM installer."""\n'
        '    return _com_over_left_stance_foot(env)\n\n'
    )
    repairs.append("restored missing airborne-COM helper stub")

if stubs:
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate first behavior registration for preflight repair")
    s = s[:idx] + "# MICRODUCK_USER_ONE_LEG_PREFLIGHT_STUBS\n" + "".join(stubs) + s[idx:]

if s != original:
    path.write_text(s)
    print("✓ repaired stale one_leg source before imports")
    for item in repairs:
        print(f"  - {item}")
else:
    print("✓ one_leg source preflight: no stale callable corruption found")
PY
