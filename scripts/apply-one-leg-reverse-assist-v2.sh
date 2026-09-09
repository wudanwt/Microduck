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

helper_v2 = r'''
# MICRODUCK_USER_ONE_LEG_REVERSE_ASSIST_V2
def _one_leg_spawn_pre_lift(env):
    """Reverse-curriculum spawn with a visibly airborne right foot.

    The old V1 started by bending the right knee in the wrong sign and only
    asked for 8 mm, so a warm-started standing policy could immediately stamp
    the foot back down.  V2 uses the correct mirrored knee-flex sign, solves a
    larger live-model IK target, and seeds a short-lived Jacobian-transpose
    lifting assist that is removed after a few control steps.
    """
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

    # IMPORTANT: right-knee flex is the POSITIVE mirrored direction.  The old
    # reverse-spawn V1 used -0.10 here; upstream's folded poses use +knee on
    # right and -knee on left.
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
        dq = np.clip(dq, -0.06, 0.06)
        d.qpos[q_idx] += dq
        mujoco.mj_forward(m, d)

    # Replant the left stance foot at the same floor height.  This preserves
    # the relative right-foot clearance produced by the IK.
    left_now = float(d.geom_xpos[left_gid][2])
    d.qpos[2] += left_z_ref - left_now
    d.qvel[:] = 0.0
    d.ctrl[:] = d.qpos[env.joint_qpos_adr]
    mujoco.mj_forward(m, d)

    if env.bam is not None:
        env.bam.reset(d.qpos[env.joint_qpos_adr])
    env.prev_joint_vel = env._joint_vel().copy()

    # Training-wheel state.  It only exists on episodes that actually used
    # this spawn family; normal-start episodes have a different episode_id and
    # therefore receive no assist.
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

    # Seed the first physics step too. state_fn runs after a step, so without
    # this the warm-start policy gets one free chance to stamp the foot down.
    jacp.fill(0.0)
    mujoco.mj_jacGeom(m, d, jacp, None, right_gid)
    grad = jacp[2, v_idx]
    d.qfrc_applied[v_idx] = grad * env._one_leg_assist_force
    return env._get_obs()


def _one_leg_reverse_assist_state(env) -> None:
    """Short per-episode lifting training wheel for reverse-curriculum spawns."""
    v_idx = np.asarray(env.joint_qvel_adr[[10, 11, 12, 13]], dtype=int)
    # Always clear our own generalized force slots first so no assist leaks
    # from an early-terminated episode into the next normal-start episode.
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

    # Fade over the final five control steps instead of switching off abruptly.
    fade = min(1.0, left / 5.0)
    force = float(getattr(env, "_one_leg_assist_force", 0.0)) * fade
    env.data.qfrc_applied[v_idx] = grad * force
    env._one_leg_assist_steps_left = left - 1

'''

# V1 is installed immediately before this script by start-lab. Replace that
# entire helper block in-place. Re-running V2 is idempotent.
if "# MICRODUCK_USER_ONE_LEG_REVERSE_ASSIST_V2" in s:
    pat = re.compile(
        r'(?ms)^# MICRODUCK_USER_ONE_LEG_REVERSE_ASSIST_V2\n'
        r'def _one_leg_spawn_pre_lift\(env\):\n.*?'
        r'(?=^_register\(Behavior\()'
    )
    s, count = pat.subn(helper_v2, s, count=1)
    if count != 1:
        raise SystemExit("Could not refresh reverse-assist V2 helper")
elif "# MICRODUCK_USER_ONE_LEG_REVERSE_SPAWN_V1" in s:
    pat = re.compile(
        r'(?ms)^# MICRODUCK_USER_ONE_LEG_REVERSE_SPAWN_V1\n'
        r'def _one_leg_spawn_pre_lift\(env\):\n.*?'
        r'(?=^_register\(Behavior\()'
    )
    s, count = pat.subn(helper_v2, s, count=1)
    if count != 1:
        raise SystemExit("Could not upgrade reverse-spawn V1 to V2")
else:
    raise SystemExit("Reverse-spawn V1 helper missing; run apply-one-leg-reverse-spawn.sh first")

# Locate one_leg registration and bind the per-step assist state hook.
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
    anchor = '    spawn_families=((0.0, _one_leg_spawn_pre_lift),),'
    if anchor not in block:
        raise SystemExit("Could not locate one_leg spawn_families anchor")
    block = block.replace(anchor, anchor + '\n    state_fn=_one_leg_reverse_assist_state,', 1)

# Patch each stage's reverse-spawn height and short assist knobs.
stage_cfg = {
    "1": ("0.008", "0.0", "0.0"),
    "2": ("0.025", "4.0", "0.35"),
    "3": ("0.035", "3.0", "0.30"),
    "4": ("0.045", "2.0", "0.25"),
    "5": ("0.055", "1.0", "0.20"),
    "6": ("0.055", "0.0", "0.0"),
}
for stage, (spawn_h, force, dur) in stage_cfg.items():
    pat = re.compile(
        r'(?ms)("MICRODUCK_ONELEG_STAGE": "' + stage + r'".*?'
        r'"MICRODUCK_ONELEG_SPAWN_H": ")([^"]+)(",)'
    )
    block, count = pat.subn(lambda m: m.group(1) + spawn_h + m.group(3), block, count=1)
    if count != 1:
        raise SystemExit(f"Could not patch stage {stage} spawn height")

    # Insert/update assist knobs just after SPAWN_H.
    stage_pat = re.compile(
        r'(?ms)("MICRODUCK_ONELEG_STAGE": "' + stage + r'".*?'
        r'"MICRODUCK_ONELEG_SPAWN_H": "[^"]+",)'
    )
    m = stage_pat.search(block)
    if not m:
        raise SystemExit(f"Could not locate stage {stage} for assist knobs")
    segment_start = m.start(1)
    # Scope replacement to this stage by finding the next detail/close.
    segment_end = block.find("            },", m.end(1))
    if segment_end < 0:
        raise SystemExit(f"Could not locate stage {stage} env end")
    segment = block[segment_start:segment_end]
    segment = re.sub(r'\n\s*"MICRODUCK_ONELEG_ASSIST_FORCE": "[^"]+",', '', segment)
    segment = re.sub(r'\n\s*"MICRODUCK_ONELEG_ASSIST_S": "[^"]+",', '', segment)
    insertion = (
        f'\n                "MICRODUCK_ONELEG_ASSIST_FORCE": "{force}",'
        f'\n                "MICRODUCK_ONELEG_ASSIST_S": "{dur}",'
    )
    # Append right after spawn_h line.
    segment = re.sub(
        r'("MICRODUCK_ONELEG_SPAWN_H": "[^"]+",)',
        lambda mm: mm.group(1) + insertion,
        segment,
        count=1,
    )
    block = block[:segment_start] + segment + block[segment_end:]

s = s[:reg_start] + block + s[reg_end:]
path.write_text(s)

# Text verification.
s = path.read_text()
one_id = s.find('id="one_leg"')
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id) + len("\n))")
one = s[reg_start:reg_end]
for needle in (
    "# MICRODUCK_USER_ONE_LEG_REVERSE_ASSIST_V2",
    "right-knee flex is the POSITIVE mirrored direction",
    "def _one_leg_reverse_assist_state(env)",
    "state_fn=_one_leg_reverse_assist_state",
    '"MICRODUCK_ONELEG_SPAWN_H": "0.025"',
    '"MICRODUCK_ONELEG_ASSIST_FORCE": "4.0"',
    '"MICRODUCK_ONELEG_ASSIST_S": "0.35"',
):
    if needle not in s and needle not in one:
        raise SystemExit(f"reverse-assist V2 source verification failed: {needle}")

print("✓ one_leg reverse-assist V2 source patch verified")
print("  fixed : right-knee pre-flex sign")
print("  stage2: ~25 mm pre-lift + 4 N Jacobian assist for ~0.35 s")
print("  stage3: ~35 mm + 3 N / 0.30 s")
print("  stage4: ~45 mm + 2 N / 0.25 s")
print("  stage5: ~55 mm + 1 N / 0.20 s")
print("  stage6: no assist")
PY

# Runtime + physical verification. Unlike earlier installers, this actually
# instantiates an environment and calls the spawn helper so a no-op IK cannot
# hide behind a successful import.
(
  cd "$LOCAL"
  uv run python - <<'PY'
import numpy as np
from microduck_local.behaviors import BEHAVIORS
from microduck_local.behaviors.env import BehaviorEnv

b = BEHAVIORS["one_leg"]
if b.state_fn is None or b.state_fn.__name__ != "_one_leg_reverse_assist_state":
    raise SystemExit(f"one_leg reverse-assist state hook wrong: {b.state_fn}")
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
    raise SystemExit(f"reverse-assist physical check failed: right-foot clearance only {h*1000:.1f} mm")

# The state hook must produce a non-zero generalized lifting assist on the
# right leg while this assisted episode is active.
env.behavior.state_fn(env)
v_idx = np.asarray(env.joint_qvel_adr[[10, 11, 12, 13]], dtype=int)
assist_norm = float(np.linalg.norm(env.data.qfrc_applied[v_idx]))
if assist_norm <= 1e-6:
    raise SystemExit("reverse-assist physical check failed: zero right-leg assist")

print("✓ one_leg reverse-assist V2 physical runtime check passed")
print(f"  measured stage2 pre-lift clearance: {h*1000:.1f} mm")
print(f"  generalized assist norm: {assist_norm:.4f}")
env.close()
PY
)
