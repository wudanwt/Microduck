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

helper = r'''
# MICRODUCK_USER_ONE_LEG_REVERSE_SPAWN_V1
def _one_leg_spawn_pre_lift(env):
    """Reverse-curriculum spawn with the right foot already slightly airborne.

    Stages 2-5 use this only on a fraction of episodes.  We solve a tiny IK
    problem against the live MuJoCo model instead of hard-coding one robot pose:
    nudge the right-leg joints until right-foot Z is `MICRODUCK_ONELEG_SPAWN_H`
    above the left foot, keep the left foot at its pre-spawn ground height, and
    zero velocities.  The spawn probability decays by stage and is zero in the
    final stage, so the finished policy must perform the lift from a normal start.
    """
    try:
        target = float(_spawn_knob(env, "MICRODUCK_ONELEG_SPAWN_H", "0.008") or "0.008")
    except (TypeError, ValueError):
        target = 0.008
    target = float(np.clip(target, 0.004, 0.040))

    d, m = env.data, env.model
    left_gid = env.foot_geoms["left"]
    right_gid = env.foot_geoms["right"]
    mujoco.mj_forward(m, d)
    left_z_ref = float(d.geom_xpos[left_gid][2])

    # Right leg logical joints: hip roll/pitch, knee, ankle (exclude yaw).
    q_idx = np.asarray(env.joint_qpos_adr[[10, 11, 12, 13]], dtype=int)
    v_idx = np.asarray(env.joint_qvel_adr[[10, 11, 12, 13]], dtype=int)

    # Break the near-straight-knee singularity very gently before Jacobian IK.
    # The model's right-knee flex direction is negative (same sign used by the
    # lab's folded stand spawn); 5-7 degrees is enough to make vertical leverage.
    cur_h = float(d.geom_xpos[right_gid][2] - d.geom_xpos[left_gid][2])
    if cur_h < target - 0.001:
        d.qpos[env.joint_qpos_adr[12]] -= 0.10
        mujoco.mj_forward(m, d)

    jacp = np.zeros((3, m.nv), dtype=float)
    for _ in range(10):
        cur_h = float(d.geom_xpos[right_gid][2] - d.geom_xpos[left_gid][2])
        err = target - cur_h
        if abs(err) < 0.0005:
            break
        jacp.fill(0.0)
        mujoco.mj_jacGeom(m, d, jacp, None, right_gid)
        grad = jacp[2, v_idx]
        denom = float(np.dot(grad, grad))
        if denom < 1e-10:
            break
        dq = grad * (err / (denom + 1e-8))
        dq = np.clip(dq, -0.08, 0.08)
        d.qpos[q_idx] += dq
        mujoco.mj_forward(m, d)

    # Re-plant the left stance foot at exactly the height it had before the IK.
    # A free-root Z translation shifts both feet equally, so relative lift stays.
    left_now = float(d.geom_xpos[left_gid][2])
    d.qpos[2] += left_z_ref - left_now
    d.qvel[:] = 0.0
    d.ctrl[:] = d.qpos[env.joint_qpos_adr]
    mujoco.mj_forward(m, d)

    if env.bam is not None:
        env.bam.reset(d.qpos[env.joint_qpos_adr])
    env.prev_joint_vel = env._joint_vel().copy()
    return env._get_obs()

'''

if "# MICRODUCK_USER_ONE_LEG_REVERSE_SPAWN_V1" not in s:
    anchor = "_register(Behavior("
    idx = s.find(anchor)
    if idx < 0:
        raise SystemExit("Could not locate first behavior registration")
    s = s[:idx] + helper + s[idx:]

one_id = s.find('id="one_leg"')
if one_id < 0:
    raise SystemExit("Could not locate one_leg behavior")
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id)
if reg_start < 0 or reg_end < 0:
    raise SystemExit("Could not locate complete one_leg registration")
reg_end += len("\n))")
block = s[reg_start:reg_end]

# One family, base probability zero. Curriculum stages override it via
# MICRODUCK_SPAWN_FAMILY_PROBS, so ordinary previews/evals do not get assisted.
spawn_line = '    spawn_families=((0.0, _one_leg_spawn_pre_lift),),'
if "spawn_families=" in block:
    block = re.sub(r'(?m)^    spawn_families=.*$', spawn_line, block, count=1)
else:
    anchor = "    symmetric=False,"
    if anchor not in block:
        raise SystemExit("Could not locate one_leg symmetric=False anchor")
    block = block.replace(anchor, anchor + "\n" + spawn_line, 1)

# Replace the six curriculum stages wholesale so the spawn mix and training
# budget are explicit and cannot be silently undone by earlier installers.
cur_idx = block.find("\n    curriculum=(")
if cur_idx < 0:
    raise SystemExit("Could not locate one_leg curriculum")
block = block[:cur_idx] + "\n))"

curriculum = r'''    curriculum=(
        CurriculumStage(
            "阶段 1：重心左移 + 双脚保持平整",
            300_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "1",
                "MICRODUCK_ONELEG_TARGET_H": "0.000",
                "MICRODUCK_EPISODE_S": "12",
                "MICRODUCK_SPAWN_FAMILY_PROBS": "0.0",
                "MICRODUCK_ONELEG_SPAWN_H": "0.008",
            },
            detail="短暂学习把重量转到左脚；这一阶段没有预抬辅助。",
        ),
        CurriculumStage(
            "阶段 2：从预抬姿势学习真正离地",
            1_500_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "2",
                "MICRODUCK_ONELEG_TARGET_H": "0.015",
                "MICRODUCK_EPISODE_S": "12",
                "MICRODUCK_SPAWN_FAMILY_PROBS": "0.70",
                "MICRODUCK_ONELEG_SPAWN_H": "0.008",
            },
            detail="约70%回合从右脚已离地约8 mm开始，30%仍从正常站姿开始；先学会保持离地，再反向学会自己完成最后的抬脚。",
        ),
        CurriculumStage(
            "阶段 3：右脚抬到 3 cm",
            1_000_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "3",
                "MICRODUCK_ONELEG_TARGET_H": "0.030",
                "MICRODUCK_EPISODE_S": "13",
                "MICRODUCK_SPAWN_FAMILY_PROBS": "0.45",
                "MICRODUCK_ONELEG_SPAWN_H": "0.014",
            },
            detail="预抬辅助降到45%，其余55%必须从正常着地状态自己完成卸载和离地。",
        ),
        CurriculumStage(
            "阶段 4：右脚抬到 5 cm",
            1_000_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "4",
                "MICRODUCK_ONELEG_TARGET_H": "0.050",
                "MICRODUCK_EPISODE_S": "14",
                "MICRODUCK_SPAWN_FAMILY_PROBS": "0.25",
                "MICRODUCK_ONELEG_SPAWN_H": "0.018",
            },
            detail="只保留25%预抬回合，逐步撤掉训练轮。",
        ),
        CurriculumStage(
            "阶段 5：达到最终 8 cm",
            900_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "5",
                "MICRODUCK_ONELEG_TARGET_H": "0.080",
                "MICRODUCK_EPISODE_S": "16",
                "MICRODUCK_SPAWN_FAMILY_PROBS": "0.10",
                "MICRODUCK_ONELEG_SPAWN_H": "0.025",
            },
            detail="只剩10%辅助回合，主要从正常站姿完成8 cm抬脚。",
        ),
        CurriculumStage(
            "阶段 6：无辅助静态平衡精修与消抖",
            1_300_000,
            env={
                "MICRODUCK_ONELEG_STAGE": "6",
                "MICRODUCK_ONELEG_TARGET_H": "0.080",
                "MICRODUCK_EPISODE_S": "20",
                "MICRODUCK_SPAWN_FAMILY_PROBS": "0.0",
                "MICRODUCK_ONELEG_SPAWN_H": "0.025",
            },
            detail="完全取消预抬辅助；最终策略必须从正常站姿自行卸载、抬脚并稳定保持。",
        ),
    ),'''

block = block[:-len("\n))")] + "\n" + curriculum + "\n))"
s = s[:reg_start] + block + s[reg_end:]
path.write_text(s)

# Source verification.
s = path.read_text()
one_id = s.find('id="one_leg"')
reg_start = s.rfind("_register(Behavior(", 0, one_id)
reg_end = s.find("\n))", one_id) + len("\n))")
one = s[reg_start:reg_end]
for needle in (
    "# MICRODUCK_USER_ONE_LEG_REVERSE_SPAWN_V1",
    "def _one_leg_spawn_pre_lift(env)",
    "mj_jacGeom",
    "spawn_families=((0.0, _one_leg_spawn_pre_lift),)",
    '"MICRODUCK_SPAWN_FAMILY_PROBS": "0.70"',
    '"MICRODUCK_SPAWN_FAMILY_PROBS": "0.0"',
    "阶段 6：无辅助静态平衡精修与消抖",
):
    if needle not in s and needle not in one:
        raise SystemExit(f"one_leg reverse-spawn source verification failed: {needle}")
if one.count("CurriculumStage(") != 6:
    raise SystemExit(f"Expected 6 stages, found {one.count('CurriculumStage(')}")
print("✓ one_leg reverse-curriculum pre-lift source patch verified")
print("  stage 2 spawn assist: 70% at ~8 mm")
print("  stage 3 spawn assist: 45% at ~14 mm")
print("  stage 4 spawn assist: 25% at ~18 mm")
print("  stage 5 spawn assist: 10% at ~25 mm")
print("  stage 6 spawn assist: 0% (fully unassisted)")
PY

(
  cd "$LOCAL"
  uv run python - <<'PY'
from microduck_local.behaviors import BEHAVIORS
b = BEHAVIORS["one_leg"]
if len(b.spawn_families) != 1:
    raise SystemExit(f"one_leg reverse-spawn family count wrong: {len(b.spawn_families)}")
prob, fn = b.spawn_families[0]
if prob != 0.0 or fn.__name__ != "_one_leg_spawn_pre_lift":
    raise SystemExit(f"one_leg reverse-spawn binding wrong: {(prob, fn.__name__)}")
expected_probs = ["0.0", "0.70", "0.45", "0.25", "0.10", "0.0"]
actual_probs = [st.env.get("MICRODUCK_SPAWN_FAMILY_PROBS") for st in b.curriculum]
if actual_probs != expected_probs:
    raise SystemExit(f"one_leg reverse-spawn stage mix wrong: {actual_probs}")
steps = [st.steps for st in b.curriculum]
if sum(steps) != 6_000_000:
    raise SystemExit(f"one_leg reverse-spawn total steps wrong: {steps}")
print("✓ one_leg reverse-curriculum pre-lift runtime verified")
print("  stage spawn probs:", actual_probs)
print("  curriculum steps:", steps)
PY
)
