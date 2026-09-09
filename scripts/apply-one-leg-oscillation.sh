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
# MICRODUCK_USER_ONE_LEG_OSCILLATION_V2
#
# V1 proved that the windowed detector worked, but the observed one-leg jitter
# scored only ~0.035 raw: for this ~25 cm robot, a few millimetres of persistent
# foot wobble is visually obvious even though V1 treated it as harmless.
#
# V2 therefore keeps the same detrended-window idea but makes it intentionally
# more sensitive:
#   - 20 samples ~= 0.4 s at the 50 Hz policy rate
#   - only 0.6 mm residual RMS is free
#   - ~3.6 mm residual RMS reaches full penalty
#
# The linear trend is still removed first, so slow drift is mostly left to
# right_foot_height_error; this term is about repeated wobble around the trend.
# ---------------------------------------------------------------------------
helper_v2 = r'''
# MICRODUCK_USER_ONE_LEG_OSCILLATION_V2
def _right_foot_oscillation_pen(env) -> float:
    h = _foot_z(env, "right") - _foot_z(env, "left")

    # While the foot is down / still being lifted, clear history and do not
    # penalize. This also makes normal episode resets self-cleaning.
    if env.foot_contact_state["right"] or h < 0.05:
        env._rf_osc_hist = []
        return 0.0

    hist = getattr(env, "_rf_osc_hist", None)
    if hist is None:
        hist = []
        env._rf_osc_hist = hist

    hist.append(float(h))
    window = 20  # ~0.4 s at 50 Hz
    if len(hist) > window:
        del hist[:-window]

    # Let enough history accumulate before judging the signal.
    n = len(hist)
    if n < 10:
        return 0.0

    # Remove a simple linear start->end trend. Residual RMS measures repeated
    # wobble instead of punishing one slow monotonic correction.
    start = hist[0]
    end = hist[-1]
    denom = float(n - 1)
    sq = 0.0
    for i, value in enumerate(hist):
        trend = start + (end - start) * (i / denom)
        d = value - trend
        sq += d * d
    rms = (sq / n) ** 0.5

    # 0.6 mm RMS is treated as harmless micro-correction. Above that the
    # penalty grows quadratically; ~3.6 mm total residual RMS reaches -1.
    excess = max(rms - 0.0006, 0.0)
    if excess <= 0.0:
        return 0.0
    return -min((excess / 0.003) ** 2, 1.0)

'''

# Upgrade an already-patched local checkout in place. Older V1 installations
# have this helper immediately before the first behavior registration. Replace
# only that marked helper block; do not touch the rest of the user's overlays.
if "# MICRODUCK_USER_ONE_LEG_OSCILLATION_V1" in s:
    pat = re.compile(
        r'(?ms)^# MICRODUCK_USER_ONE_LEG_OSCILLATION_V1\n'
        r'def _right_foot_oscillation_pen\(env\) -> float:\n.*?'
        r'(?=^_register\(Behavior\()'
    )
    s, count = pat.subn(helper_v2, s, count=1)
    if count != 1:
        raise SystemExit("Could not migrate one-leg oscillation V1 helper; local source changed.")
elif "# MICRODUCK_USER_ONE_LEG_OSCILLATION_V2" not in s:
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate first behavior registration; upstream changed.")
    s = s[:idx] + helper_v2 + s[idx:]

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

if '"right_foot_oscillation"' not in block:
    flat_match = re.search(
        r'(?m)^(?P<indent>[ \t]*)RewardTerm\("flat_stance_foot",',
        block,
    )
    if not flat_match:
        raise SystemExit("Could not locate one_leg flat_stance_foot reward; upstream changed.")
    ind = flat_match.group("indent")
    term = (
        f'{ind}RewardTerm(\n'
        f'{ind}    "right_foot_oscillation",\n'
        f'{ind}    "Penalty for sustained oscillation of the lifted right foot over a short time window",\n'
        f'{ind}    2.0,\n'
        f'{ind}    _right_foot_oscillation_pen,\n'
        f'{ind}    is_penalty=True,\n'
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
    '# MICRODUCK_USER_ONE_LEG_OSCILLATION_V2',
    '"right_foot_oscillation"',
    'window = 20',
    'rms - 0.0006',
    'excess / 0.003',
]
missing = [x for x in required if x not in s and x != '"right_foot_oscillation"']
if '"right_foot_oscillation"' not in one:
    missing.append('"right_foot_oscillation" in one_leg')
if missing:
    raise SystemExit("one_leg oscillation V2 source verification failed: " + ", ".join(missing))

print("✓ one_leg oscillation V2 source patch verified")
print("  penalty: right_foot_oscillation (default 2.0)")
print("  window : 20 steps (~0.4 s), 0.6 mm RMS deadband, detrended")
print("  scale  : ~3.6 mm residual RMS reaches full penalty")
PY

# Runtime verification in the exact environment used by duck-lab.
(
  cd "$LOCAL"
  uv run python - <<'PY'
import inspect
from microduck_local.behaviors import BEHAVIORS
from microduck_local.behaviors import poses

keys = [t.key for t in BEHAVIORS["one_leg"].terms]
if "right_foot_oscillation" not in keys:
    raise SystemExit("one_leg oscillation V2 runtime reward missing")

src = inspect.getsource(poses._right_foot_oscillation_pen)
for needle in ("window = 20", "0.0006", "0.003"):
    if needle not in src:
        raise SystemExit(f"one_leg oscillation V2 runtime helper verification failed: {needle}")

print("✓ one_leg oscillation V2 runtime reward present")
PY
)
