# Microduck Workspace 🦆

Dan's Microduck reinforcement-learning workspace, optimized for Apple Silicon Mac development.

This repository is a **superproject** that pins the complete Microduck toolchain as Git submodules:

- `microduck` — official Pollen Robotics robot software / deployment stack.
- `microduck_rl` — official MuJoCo Warp + PPO training and Sim2Real stack (CUDA GPU for full training).
- `microduck-lab` — community Apple Silicon local-training harness (CPU/MPS), browser viewer, reward prototyping and ONNX export.

## Why this layout

The three upstream projects evolve independently. Keeping them as pinned submodules means this repository records an exact reproducible combination while still allowing each upstream to be updated cleanly later.

## Clone everything

```bash
git clone --recursive https://github.com/wudanwt/Microduck.git
cd Microduck
```

If you already cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

## Mac quick start

Prerequisites:

```bash
brew install uv node git
```

Then run:

```bash
./scripts/setup-mac.sh
```

Train a first walking policy:

```bash
cd microduck-lab/microduck_local
uv run train-walk --envs 32 --steps 3_000_000 --run-name first-gait
uv run export-walk runs/first-gait
uv run eval-walk runs/first-gait/policy.onnx
```

Start the lab backend:

```bash
cd microduck-lab/microduck_local
uv run duck-lab runs/first-gait ../../microduck/policies/alpha_walking.onnx
```

In another terminal start the browser viewer:

```bash
cd microduck-lab/duck-viewer
npm run dev
```

## What runs where

| Task | Apple Silicon Mac | NVIDIA CUDA GPU | Microduck robot |
|---|---:|---:|---:|
| MuJoCo simulation | ✅ | ✅ | — |
| Local PPO prototyping | ✅ CPU/MPS | ✅ | — |
| Browser training viewer | ✅ | ✅ | — |
| Official `microduck_rl` full training | ❌ CUDA required | ✅ | — |
| ONNX evaluation/export | ✅ | ✅ | — |
| Final policy execution | — | — | ✅ |

## Recommended workflow

1. Prototype rewards and behaviors locally in `microduck-lab` on the Mac.
2. Inspect rollouts visually and evaluate metrics.
3. Export ONNX for compatibility checks.
4. Port successful behavior/reward design to `microduck_rl`.
5. Run the final domain-randomized Sim2Real training on a CUDA GPU.
6. Deploy the verified ONNX policy to the real Microduck.

## Important

`microduck-lab` is a community project and is not affiliated with Pollen Robotics. For real-hardware deployment, treat the official `microduck_rl` stack as the authoritative Sim2Real path.

## Upstreams

- https://github.com/pollen-robotics/microduck
- https://github.com/pollen-robotics/microduck_rl
- https://github.com/jonathanhawkins/microduck-lab

All three upstream repositories currently use Apache-2.0 licenses.
