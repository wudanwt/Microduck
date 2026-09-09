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

# Repair the exact corruption produced by curriculum V2 when it replaced only
# the identifier of the original factory callable _stance_flat("left"), leaving
# the argument list behind:
#   _one_leg_stage_flat_support("left")
# must be a plain RewardTerm callable:
#   _one_leg_stage_flat_support
s = re.sub(
    r'_one_leg_stage_flat_support\s*\(\s*["\']left["\']\s*\)',
    '_one_leg_stage_flat_support',
    s,
)

if s != original:
    path.write_text(s)
    print("✓ repaired stale one_leg callable corruption before imports")
else:
    print("✓ one_leg source preflight: no stale callable corruption found")
PY
