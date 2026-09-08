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

# MICRODUCK_USER_ONE_LEG_HEIGHT_ERROR_V1
# Penalize amplitude: once the lifted foot is up, keep its height close to 8 cm.
# A ±1 cm deadband is free. Outside that band the penalty rises quadratically
# and saturates when the foot is about 4 cm away from the target. A smooth gate
# from 3->5 cm lets the policy perform the initial lift without immediately
# paying the full hold-position penalty.
if "def _right_foot_height_error_pen(env)" not in s:
    helper = r'''
# MICRODUCK_USER_ONE_LEG_HEIGHT_ERROR_V1
def _right_foot_height_error_pen(env) -> float:
    if env.foot_contact_state["right"]:
        return 0.0

    h = _foot_z(env, "right") - _foot_z(env, "left")

    # Smoothly activate while the right foot is being lifted:
    # <=3 cm: off; >=5 cm: fully active.
    gate = float(np.clip((h - 0.03) / 0.02, 0.0, 1.0))
    if gate <= 0.0:
        return 0.0

    # Free band: 7..9 cm. Then penalize amplitude around the 8 cm target.
    err = max(abs(h - 0.08) - 0.01, 0.0)
    if err <= 0.0:
        return 0.0

    # 1 cm outside the free band -> ~0.11 penalty;
    # 2 cm -> ~0.44; 3 cm or more -> full penalty.
    return -gate * min((err / 0.03) ** 2, 1.0)

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

if '"right_foot_height_error"' not in block:
    flat_match = re.search(
        r'(?m)^(?P<indent>[ \t]*)RewardTerm\("flat_stance_foot",',
        block,
    )
    if not flat_match:
        raise SystemExit("Could not locate one_leg flat_stance_foot reward; upstream changed.")
    ind = flat_match.group("indent")
    term = (
        f'{ind}RewardTerm(\n'
        f'{ind}    "right_foot_height_error",\n'
        f'{ind}    "Penalty for drifting away from the 8 cm right-foot hover height",\n'
        f'{ind}    2.0,\n'
        f'{ind}    _right_foot_height_error_pen,\n'
        f'{ind}    is_penalty=True,\n'
        f'{ind}),\n'
    )
    block = block[:flat_match.start()] + term + block[flat_match.start():]

s = prefix + block + suffix
path.write_text(s)

# Text-level verification.
one_start = s.find('id="one_leg"')
one_end = s.find('default_steps=', one_start)
one = s[one_start:one_end]
if '"right_foot_height_error"' not in one:
    raise SystemExit("one_leg height-error source verification failed")

print("✓ one_leg height-error source patch verified")
print("  penalty: right_foot_height_error (default 2.0)")
print("  target : 8 cm, ±1 cm free band, quadratic outside, smooth lift gate")
PY

# Runtime verification in the exact environment used by duck-lab.
(
  cd "$LOCAL"
  uv run python - <<'PY'
from microduck_local.behaviors import BEHAVIORS
keys = [t.key for t in BEHAVIORS["one_leg"].terms]
if "right_foot_height_error" not in keys:
    raise SystemExit("one_leg height-error runtime verification failed")
print("✓ one_leg height-error runtime reward present")
PY
)
