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

# MICRODUCK_USER_ONE_LEG_OSCILLATION_V1
# Penalize persistent oscillation across a short time window rather than only
# looking at one instant.  The signal is the lifted right foot's height relative
# to the left stance foot.  We remove a simple linear trend first, so slow drift
# is mostly left to right_foot_height_error while this term targets repeated
# up/down wobble around that trend.
if "def _right_foot_oscillation_pen(env)" not in s:
    helper = r'''
# MICRODUCK_USER_ONE_LEG_OSCILLATION_V1
def _right_foot_oscillation_pen(env) -> float:
    h = _foot_z(env, "right") - _foot_z(env, "left")

    # While the foot is down / still being lifted, clear the history and do not
    # penalize.  This also makes normal episode resets self-cleaning.
    if env.foot_contact_state["right"] or h < 0.05:
        env._rf_osc_hist = []
        return 0.0

    hist = getattr(env, "_rf_osc_hist", None)
    if hist is None:
        hist = []
        env._rf_osc_hist = hist

    hist.append(float(h))
    window = 25  # ~0.5 s at the 50 Hz policy rate
    if len(hist) > window:
        del hist[:-window]

    # Give the window time to fill before judging it.
    n = len(hist)
    if n < 12:
        return 0.0

    # Remove a linear start->end trend.  Residual RMS then measures repeated
    # wobble rather than a single slow drift over the half-second window.
    start = hist[0]
    end = hist[-1]
    denom = float(n - 1)
    sq = 0.0
    for i, value in enumerate(hist):
        trend = start + (end - start) * (i / denom)
        d = value - trend
        sq += d * d
    rms = (sq / n) ** 0.5

    # ~1.5 mm residual RMS is treated as harmless balance micro-correction.
    # Above that, the penalty grows quadratically and saturates when the
    # detrended oscillation is roughly 7.5 mm RMS or larger.
    excess = max(rms - 0.0015, 0.0)
    if excess <= 0.0:
        return 0.0
    return -min((excess / 0.006) ** 2, 1.0)

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
one_start = s.find('id="one_leg"')
one_end = s.find('default_steps=', one_start)
one = s[one_start:one_end]
if '"right_foot_oscillation"' not in one:
    raise SystemExit("one_leg oscillation source verification failed")

print("✓ one_leg oscillation source patch verified")
print("  penalty: right_foot_oscillation (default 2.0)")
print("  window : 25 steps (~0.5 s), 1.5 mm RMS deadband, detrended")
PY

# Runtime verification in the exact environment used by duck-lab.
(
  cd "$LOCAL"
  uv run python - <<'PY'
from microduck_local.behaviors import BEHAVIORS
keys = [t.key for t in BEHAVIORS["one_leg"].terms]
if "right_foot_oscillation" not in keys:
    raise SystemExit("one_leg oscillation runtime verification failed")
print("✓ one_leg oscillation runtime reward present")
PY
)
