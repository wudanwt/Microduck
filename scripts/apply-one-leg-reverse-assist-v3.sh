#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL="$ROOT/microduck-lab/microduck_local"
TARGET="$LOCAL/src/microduck_local/behaviors/poses.py"

if [ ! -f "$TARGET" ]; then
  echo "Microduck Lab behavior file not found: $TARGET" >&2
  exit 1
fi

python3 - "$TARGET" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
s = path.read_text()


def remove_all_top_level_functions(src: str, name: str) -> str:
    """Remove every top-level definition of `name` without touching neighbors."""
    start_re = re.compile(rf'(?m)^def {re.escape(name)}\([^\n]*\)(?:\s*->\s*[^:]+)?:\s*\n')
    boundary = re.compile(r'(?m)^(?=def |class |@|_register\(Behavior\()')
    while True:
        m = start_re.search(src)
        if not m:
            return src
        n = boundary.search(src, m.end())
        end = n.start() if n else len(src)
        src = src[:m.start()] + src[end:]


# Remove all stale/duplicate reverse-spawn implementations first. Previous V2
# used a marker->first-register replacement and could delete helpers installed
# later; V3 owns ONLY its two functions and never consumes neighboring helpers.
s = remove_all_top_level_functions(s, "_one_leg_spawn_pre_lift")
s = remove_all_top_level_functions(s, "_one_leg_reverse_assist_state")
for marker in (
    "# MICRODUCK_USER_ONE_LEG_REVERSE_SPAWN_V1",
    "# MICRODUCK_USER_ONE_LEG_REVERSE_ASSIST_V2",
    "# MICRODUCK_USER_ONE_LEG_REVERSE_ASSIST_V3",
):
    s = s.replace(marker + "\n", "")

helper_v3 = r'''
# MICRODUCK_USER_ONE_LEG_REVERSE_SPAWN_V1
# Sentinel retained so the older reverse-spawn installer does not re-insert a
# duplicate V1 helper on later launches. The real implementation is V3 below.
# MICRODUCK_USER_ONE_LEG_REVERSE_ASSIST_V3
def _one_leg_spawn_pre_lift(env):
    """Reverse-curriculum spawn with a visibly airborne right foot."""
    try:
        target = float(_spawn_knob(env, "MICRODUCK_ONELEG_SPAWN_H", "0.025") or "0.025")
    except (TypeError, ValueError):
        target = 0.025
    target = float(np.clip(target, 0.015, 0.060))

    d, m = env.data, env.model
    left_gid = env.foot_geoms["left"]
    right_gid = env.foot_geoms["right"]
    mujoco.mj_forward(m, d)
    left_z_ref = float(d.geom_xpos[left_gid][2])

    # Right leg logical joints: hip roll/pitch, knee, ankle (exclude yaw).
    q_idx = np.asarray(env.joint_qpos_adr[[10, 11, 12, 13]], dtype=int)
    v_idx = np.asarray(env.joint_qvel_adr[[10, 11, 12, 13]], dtype=int)

    # Correct mirrored knee-flex direction: right knee is positive.
    cur_h = float(d.geom_xpos[right_gid][2] - d.geom_xpos[left_gid][2])
    if cur_h < target - 0.001:
        d.qpos[env.joint_qpos_adr[12]] += 0.12
        mujoco.mj_forward(m, d)

    jacp = np.zeros((3, m.nv), dtype=float)
    for _ in range(24):
        cur_h = float(d.geom_xpos[right_gid][2] - d.geom_xpos[left_gid][2])
        err = target - cur_h
        if abs(err) < 0.0004:
            break
        jacp.fill(0.0)
        mujoco.mj_jacGeom(m, d, jacp, None, right_gid)
        grad = jacp[2, v_idx]
        denom = float(np.dot(grad, grad))
        if denom < 1e-10:
            break
        dq = grad * (err / (denom + 1e-8))
        d.qpos[q_idx] += np.clip(dq, -0.06, 0.06)
        mujoco.mj_forward(m, d)

    # Replant the left stance foot at its pre-IK floor height.
    left_now = float(d.geom_xpos[left_gid][2])
    d.qpos[2] += left_z_ref - left_now
    d.qvel[:] = 0.0
    d.ctrl[:] = d.qpos[env.joint_qpos_adr]
    mujoco.mj_forward(m, d)

    if env.bam is not None:
        env.bam.reset(d.qpos[env.joint_qpos_adr])
    env.prev_joint_vel = env._joint_vel().copy()

    try:
        assist_s = float(_spawn_knob(env, "MICRODUCK_ONELEG_ASSIST_S", "0.35") or "0.35")
    except (TypeError, ValueError):
        assist_s = 0.35
    try:
        assist_force = float(_spawn_knob(env, "MICRODUCK_ONELEG_ASSIST_FORCE", "4.0") or "4.0")
    except (TypeError, ValueError):
        assist_force = 4.0

    env._one_leg_assist_episode = env.episode_id
    env._one_leg_assist_steps_left = max(0, int(round(assist_s / 0.02)))
    env._one_leg_assist_force = max(0.0, assist_force)

    # Seed the first physics step too; the state hook runs after a step.
    jacp.fill(0.0)
    mujoco.mj_jacGeom(m, d, jacp, None, right_gid)
    grad = jacp[2, v_idx]
    d.qfrc_applied[v_idx] = grad * env._one_leg_assist_force
    return env._get_obs()


def _one_leg_reverse_assist_state(env) -> None:
    """Short per-episode lifting training wheel for assisted spawn episodes."""
    v_idx = np.asarray(env.joint_qvel_adr[[10, 11, 12, 13]], dtype=int)
    env.data.qfrc_applied[v_idx] = 0.0

    if getattr(env, "_one_leg_assist_episode", -1) != env.episode_id:
        return
    left = int(getattr(env, "_one_leg_assist_steps_left", 0))
    if left <= 0:
        return

    right_gid = env.foot_geoms["right"]
    jacp = getattr(env, "_one_leg_assist_jacp", None)
    if jacp is None or jacp.shape != (3, env.model.nv):
        jacp = env._one_leg_assist_jacp = np.zeros((3, env.model.nv), dtype=float)
    jacp.fill(0.0)
    mujoco.mj_jacGeom(env.model, env.data, jacp, None, right_gid)
    grad = jacp[2, v_idx]

    fade = min(1.0, left / 5.0)
    force = float(getattr(env, "_one_leg_assist_force", 0.0)) * fade
    env.data.qfrc_applied[v_idx] = grad * force
    env._one_leg_assist_steps_left = left - 1

'''

anchor = "_register(Behavior("
idx = s.find(anchor)
if idx < 0:
    raise SystemExit("Could not locate first behavior registration")
s = s[:idx] + helper_v3 + s[idx:]

# Bind the state hook and normalize per-stage assist knobs.
one_id = s.find('id="one_leg"')
if one_id < 0:
    raise SystemExit("Could not locate one_leg behavior")
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id)
if reg_start < 0 or reg_end < 0:
    raise SystemExit("Could not locate complete one_leg registration")
reg_end += len("\n))")
block = s[reg_start:reg_end]

if re.search(r'(?m)^    state_fn=', block):
    block = re.sub(r'(?m)^    state_fn=.*$', '    state_fn=_one_leg_reverse_assist_state,', block, count=1)
else:
    anchor_line = '    spawn_families=((0.0, _one_leg_spawn_pre_lift),),'
    if anchor_line not in block:
        raise SystemExit("Could not locate one_leg spawn_families anchor")
    block = block.replace(anchor_line, anchor_line + '\n    state_fn=_one_leg_reverse_assist_state,', 1)

stage_cfg = {
    "1": ("0.008", "0.0", "0.0"),
    "2": ("0.025", "4.0", "0.35"),
    "3": ("0.035", "3.0", "0.30"),
    "4": ("0.045", "2.0", "0.25"),
    "5": ("0.055", "1.0", "0.20"),
    "6": ("0.055", "0.0", "0.0"),
}

for stage, (spawn_h, force, dur) in stage_cfg.items():
    needle = f'"MICRODUCK_ONELEG_STAGE": "{stage}"'
    pos = block.find(needle)
    if pos < 0:
        raise SystemExit(f"Could not locate stage {stage}")
    env_start = block.rfind("env={", 0, pos)
    env_end = block.find("\n            },", pos)
    if env_start < 0 or env_end < 0:
        raise SystemExit(f"Could not locate stage {stage} env block")
    env_text = block[env_start:env_end]

    if '"MICRODUCK_ONELEG_SPAWN_H"' not in env_text:
        raise SystemExit(f"Stage {stage} missing SPAWN_H")
    env_text = re.sub(
        r'("MICRODUCK_ONELEG_SPAWN_H"\s*:\s*")[^"]+("\s*,)',
        lambda m: m.group(1) + spawn_h + m.group(2),
        env_text,
        count=1,
    )
    env_text = re.sub(r'\n\s*"MICRODUCK_ONELEG_ASSIST_FORCE"\s*:\s*"[^"]+"\s*,', '', env_text)
    env_text = re.sub(r'\n\s*"MICRODUCK_ONELEG_ASSIST_S"\s*:\s*"[^"]+"\s*,', '', env_text)
    env_text = re.sub(
        r'("MICRODUCK_ONELEG_SPAWN_H"\s*:\s*"[^"]+"\s*,)',
        lambda m: m.group(1)
        + f'\n                "MICRODUCK_ONELEG_ASSIST_FORCE": "{force}",'
        + f'\n                "MICRODUCK_ONELEG_ASSIST_S": "{dur}",',
        env_text,
        count=1,
    )
    block = block[:env_start] + env_text + block[env_end:]

s = s[:reg_start] + block + s[reg_end:]
path.write_text(s)

# Source verification: exactly one canonical definition of each V3 helper and
# no old V2 marker-driven region replacement remains necessary.
s = path.read_text()
if s.count("def _one_leg_spawn_pre_lift(env)") != 1:
    raise SystemExit(f"Expected exactly one pre-lift helper, found {s.count('def _one_leg_spawn_pre_lift(env)')}")
if s.count("def _one_leg_reverse_assist_state(env)") != 1:
    raise SystemExit(f"Expected exactly one assist-state helper, found {s.count('def _one_leg_reverse_assist_state(env)')}")
one_id = s.find('id="one_leg"')
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id) + len("\n))")
one = s[reg_start:reg_end]
for needle in (
    "# MICRODUCK_USER_ONE_LEG_REVERSE_ASSIST_V3",
    "# MICRODUCK_USER_ONE_LEG_REVERSE_SPAWN_V1",
    "state_fn=_one_leg_reverse_assist_state",
    '"MICRODUCK_ONELEG_SPAWN_H": "0.025"',
    '"MICRODUCK_ONELEG_ASSIST_FORCE": "4.0"',
    '"MICRODUCK_ONELEG_ASSIST_S": "0.35"',
):
    if needle not in s and needle not in one:
        raise SystemExit(f"reverse-assist V3 source verification failed: {needle}")

print("✓ one_leg reverse-assist V3 source patch verified")
print("  idempotent: owns only pre-lift + assist-state functions")
print("  preserves later liftoff/COM helpers across restarts")
print("  stage2: ~25 mm + 4 N / 0.35 s")
print("  stage3: ~35 mm + 3 N / 0.30 s")
print("  stage4: ~45 mm + 2 N / 0.25 s")
print("  stage5: ~55 mm + 1 N / 0.20 s")
print("  stage6: no assist")
PY

(
  cd "$LOCAL"
  uv run python - <<'PY'
import numpy as np
from microduck_local.behaviors import BEHAVIORS
from microduck_local.behaviors.env import BehaviorEnv

b = BEHAVIORS["one_leg"]
if b.state_fn is None or b.state_fn.__name__ != "_one_leg_reverse_assist_state":
    raise SystemExit(f"one_leg reverse-assist V3 state hook wrong: {b.state_fn}")
prob, spawn_fn = b.spawn_families[0]
if spawn_fn.__name__ != "_one_leg_spawn_pre_lift":
    raise SystemExit(f"one_leg pre-lift spawn binding wrong: {spawn_fn.__name__}")

stage2 = b.curriculum[1]
env = BehaviorEnv("one_leg", spawn_overrides=stage2.env)
env.reset()
spawn_fn(env)
left = env.foot_geoms["left"]
right = env.foot_geoms["right"]
h = float(env.data.geom_xpos[right][2] - env.data.geom_xpos[left][2])
if h < 0.015:
    raise SystemExit(f"reverse-assist V3 physical check failed: right-foot clearance only {h*1000:.1f} mm")

env.behavior.state_fn(env)
v_idx = np.asarray(env.joint_qvel_adr[[10, 11, 12, 13]], dtype=int)
assist_norm = float(np.linalg.norm(env.data.qfrc_applied[v_idx]))
if assist_norm <= 1e-6:
    raise SystemExit("reverse-assist V3 physical check failed: zero right-leg assist")

print("✓ one_leg reverse-assist V3 physical runtime check passed")
print(f"  measured stage2 pre-lift clearance: {h*1000:.1f} mm")
print(f"  generalized assist norm: {assist_norm:.4f}")
env.close()
PY
)
