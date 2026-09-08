#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/microduck-lab/microduck_local/src/microduck_local/train_behavior.py"

if [ ! -f "$TARGET" ]; then
  echo "Microduck Lab trainer not found: $TARGET" >&2
  echo "Run: git submodule update --init --recursive" >&2
  exit 1
fi

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
s = path.read_text()
marker = "MICRODUCK_USER_FINETUNE_LR_V1"

old = '''        lr0 = args.lr_start if args.lr_start is not None else (\n            LR_START if resume else 2e-4)\n        lr1 = args.lr_end if args.lr_end is not None else (\n            LR_END if resume else 3e-5)\n        model.lr_schedule = linear_decay(lr0, lr1)\n'''

new = '''        # MICRODUCK_USER_FINETUNE_LR_V1\n        # Cross-run fine-tunes used to hard-code 2e-4 -> 3e-5, which meant\n        # MICRODUCK_LR_START/END on the lab process did not actually control\n        # Teach fine-tuning.  Honor dedicated FINETUNE vars first, then the\n        # generic LR vars for backwards compatibility, while preserving the\n        # upstream 2e-4 -> 3e-5 defaults when nothing is set.\n        fine_lr0 = _env_lr(\"MICRODUCK_FINETUNE_LR_START\",\n                            _env_lr(\"MICRODUCK_LR_START\", 2e-4))\n        fine_lr1 = _env_lr(\"MICRODUCK_FINETUNE_LR_END\",\n                            _env_lr(\"MICRODUCK_LR_END\", 3e-5))\n        lr0 = args.lr_start if args.lr_start is not None else (\n            LR_START if resume else fine_lr0)\n        lr1 = args.lr_end if args.lr_end is not None else (\n            LR_END if resume else fine_lr1)\n        model.lr_schedule = linear_decay(lr0, lr1)\n        print(f\"learning-rate schedule: {lr0:g} -> {lr1:g} \"\n              f\"({'resume' if resume else 'fine-tune'})\")\n'''

if marker not in s:
    if old not in s:
        raise SystemExit("Could not locate the fine-tune learning-rate block; upstream changed.")
    s = s.replace(old, new, 1)
    path.write_text(s)

s = path.read_text()
required = [
    marker,
    'MICRODUCK_FINETUNE_LR_START',
    'MICRODUCK_FINETUNE_LR_END',
    'learning-rate schedule:',
]
missing = [x for x in required if x not in s]
if missing:
    raise SystemExit("fine-tune LR patch verification failed: " + ", ".join(missing))

print("✓ Teach fine-tune learning-rate patch verified")
PY

START="${MICRODUCK_FINETUNE_LR_START:-${MICRODUCK_LR_START:-2e-4}}"
END="${MICRODUCK_FINETUNE_LR_END:-${MICRODUCK_LR_END:-3e-5}}"
echo "  Teach cross-run fine-tune LR: $START -> $END"
echo "  Override with MICRODUCK_FINETUNE_LR_START / MICRODUCK_FINETUNE_LR_END"
