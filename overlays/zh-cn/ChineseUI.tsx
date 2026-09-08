"use client";

import { useEffect, useState } from "react";

const STORAGE_KEY = "microduck-ui-language";

type Lang = "zh-CN" | "en";

/**
 * Chinese overlay for the upstream Microduck Lab viewer.
 *
 * Keep policy/run/file names and technical units untouched. We translate
 * human-facing UI copy only. The upstream React UI frequently splits one
 * sentence into several text nodes around dynamic values, so this table
 * intentionally contains BOTH complete sentences and fragments.
 */
const exact: Record<string, string> = {
  // --- navigation / common UI ------------------------------------------------
  "Teach": "教动作（Teach）",
  "teach": "教动作",
  "Policies": "策略（Policies）",
  "Policy": "策略",
  "policy": "策略",
  "Animate": "动作编辑（Animate）",
  "Record": "录制（Record）",
  "Settings": "设置",
  "settings": "设置",
  "Reset": "重置",
  "reset": "重置",
  "Close": "关闭",
  "close": "关闭",
  "Cancel": "取消",
  "cancel": "取消",
  "Save": "保存",
  "save": "保存",
  "Delete": "删除",
  "delete": "删除",
  "Start training": "开始训练",
  "Train": "训练",
  "train": "训练",
  "Stop": "停止",
  "stop": "停止",
  "Fine-tune": "继续微调",
  "Fine tune": "继续微调",
  "Retrain": "重新训练",
  "Retrain from scratch": "从零重新训练",
  "Training": "训练",
  "training": "训练中",
  "Done": "已完成",
  "done": "已完成",
  "Failed": "失败",
  "failed": "失败",
  "Paused": "已暂停",
  "paused": "已暂停",
  "live": "实时",
  "offline": "离线",
  "stalled": "停滞",
  "loading…": "加载中…",
  "restarting…": "正在重启…",
  "Score": "得分",
  "Reward": "奖励",
  "Rewards": "奖励项",
  "Steps": "训练步数",
  "steps": "步",
  "Status": "状态",
  "Stage": "阶段",
  "stage": "阶段",
  "Practice": "训练",
  "Practice budget": "训练预算",
  "Success metric": "成功指标",
  "How it learns": "它是怎么学会的",
  "Recipe": "奖励配方",
  "recipe": "默认配方",
  "Suggestions": "推荐动作",
  "falls": "摔倒",
  "sim →": "仿真 →",
  "collapse": "收起",
  "keyboard controls": "键盘与视角控制",
  "clear the conversation and any finished training card": "清空对话和已完成的训练卡片",
  "back to the narrow panel": "恢复窄面板",
  "widen the panel — full recipe sentences": "加宽面板，完整显示奖励项说明",

  // --- bottom-left viewport help ---------------------------------------------
  "↺ R restart sim — every duck's episode from zero":
    "↺ R 重置模拟 — 所有鸭子从新回合开始",
  "🖱 click a duck to select · ⌫ remove it · esc deselect":
    "🖱 点击鸭子选择 · ⌫ 删除 · Esc 取消选择",
  "🎥 drag orbit · scroll zoom · 2-finger swipe slide · A/D slide ·":
    "🎥 拖拽环绕 · 滚轮缩放 · 双指横滑平移 · A/D 平移 ·",
  "W/S·↑↓ dolly · ←/→ orbit · Q/E up·down · Shift+R reset view":
    "W/S·↑↓ 前后移动 · ←/→ 环绕 · Q/E 上下移动 · Shift+R 重置视角",
  "⌨ click the scene to enable keys": "⌨ 点击场景后启用快捷键",
  "🎥 controls": "🎥 视角控制",

  // --- HUD tooltips / status --------------------------------------------------
  "the world page — rooms, sensors, brains": "世界仿真页面 — 场景、传感器、控制大脑",
  "hide duck name labels": "隐藏鸭子名称标签",
  "show duck name labels": "显示鸭子名称标签",
  "settings — connect Hugging Face for real GPU training": "设置 — 连接 Hugging Face 用于 GPU 训练",
  "not connected to the lab": "尚未连接到实验室后端",
  "frames arriving": "仿真画面正在实时更新",
  "click to select": "点击选择",
  "selected — ⌫ removes it": "已选择 — 按 ⌫ 删除",
  "remove this helper": "移除这个辅助鸭子",
  "remove this duck from the lab": "从实验室移除这只鸭子",
  "add a helper — another viewer of the same live policy (does not change training speed)":
    "添加辅助鸭子 — 使用同一实时策略进行展示，不会提高训练速度",

  // --- Teach greeting / suggestions ------------------------------------------
  "+ add a term": "+ 添加奖励项",
  "+ Add a term": "+ 添加奖励项",
  "Add a term": "添加奖励项",
  "Ask me to teach the duck a trick — try one of the suggestions below.":
    "告诉我想教鸭子什么动作。第一次建议直接点下面的推荐动作。",
  "On it! Here's the deal I'm offering the duck:":
    "好的！下面是这次训练给鸭子设定的目标和奖励规则：",
  "stand still": "稳定站立（stand still）",
  "stand on one leg": "单脚站立（stand on one leg）",
  "crouch down": "下蹲（crouch）",
  "spin in place": "原地旋转（spin）",
  "do a headstand": "头倒立（headstand）",
  "teach the duck a new policy…": "输入想教它的动作，例如 crouch、spin、backflip…",

  // --- behavior titles --------------------------------------------------------
  "Stand still": "稳定站立",
  "Stand on one leg": "单脚站立",
  "Crouch down low": "下蹲",
  "Deep squat": "深蹲",
  "Spin in place": "原地旋转",
  "Do a headstand": "头倒立",
  "Do a backflip": "后滚翻",
  "Jump backflip": "跳跃后空翻",
  "Copy the animation": "模仿动画动作",
  "Run forward": "向前跑",
  "Find the ball": "寻找并对准小球",

  // --- behavior descriptions -------------------------------------------------
  "Balance flamingo-style: right foot in the air, all weight on the left leg — calmly, stance foot flat, no flailing.":
    "像火烈鸟一样单脚平衡：右脚抬起、左脚承重，同时保持身体稳定、支撑脚平放，不要乱甩。",
  "Just stand: both feet flat, body at full height, head up, holding still in the normal standing pose.":
    "保持正常站姿：双脚平放、身体站直、抬头，并尽量稳定不动。",
  "Bend the knees and hold a steady squat about 3.5 cm lower than normal standing.":
    "弯曲膝盖并稳定保持一个比正常站姿低约 3.5 cm 的蹲姿。",
  "Sink into a deep squat about 5.5 cm below normal standing, under the walk env's fall line, and hold it calmly with both feet flat and the head up.":
    "下沉到比正常站姿低约 5.5 cm 的深蹲位置，双脚平放、抬头并稳定保持。",
  "Turn on the spot as fast as it can without falling or walking away.":
    "尽可能快地原地旋转，同时不能摔倒，也不能越转越跑偏。",
  "Tip forward, plant the head on the floor, and balance upside down with the feet in the air.":
    "身体向前翻，把头部支撑在地面上，并让双脚离地完成倒立平衡。",
  "Lean back, roll backwards over the back with the neck tucked, carry the feet over the top, and land standing.":
    "向后倾倒并沿背部向后滚，收紧颈部，让双脚越过头顶，最后双脚落地并站起来。",
  "Jump and throw the head back at the same time, rotate backwards in the air, and land on both feet.":
    "起跳的同时向后甩头，在空中完成向后旋转，并尝试双脚落地。",
  "Physically perform a keyframed motion clip: match the authored pose and rotation at every instant, then land and stand.":
    "按照关键帧动画去真实完成动作：每个时刻都尽量匹配目标姿态和旋转，并最终落地站稳。",
  "Run forward at a steady clip: quick alternating steps, feet clearing the floor, body upright and travelling in a straight line.":
    "稳定向前跑：快速交替迈步、脚要离地、身体保持直立，并尽量沿直线前进。",
  "Scan for the ball, turn to face it, and keep it centred in the camera — even when it rolls off or reappears somewhere else.":
    "扫描寻找小球，转身朝向它，并持续把球保持在摄像头画面中央；球移动或重新出现后也要能再次找到。",

  // --- Teach card headings; many are React text-node fragments ----------------
  "how it trains —": "训练方式 —",
  "how will it learn this?": "它会怎样学会这个动作？",
  "the scorecard (checked 50× per second):": "评分项（每秒检查 50 次）：",
  "The sim runs far faster than real life, so": "模拟运行速度远快于现实，因此",
  "practice steps run on this": "个训练步会直接在这台",
  "Mac without you waiting on a real robot.": "Mac 上完成，不需要等待真机反复练习。",
  "green = points to win · red = points lost · bar = how much it matters":
    "绿色 = 奖励 · 红色 = 惩罚 · 条越长表示权重越大",

  // --- curriculum stage labels: headstand ------------------------------------
  "holding the headstand (training wheels)": "保持头倒立（辅助训练）",
  "holding it on real servos": "使用真实舵机保持倒立",
  "standing taller": "把倒立姿态撑得更高",
  "impressing the judges": "提高倒立姿态标准",
  "finishing the kick-over": "完成从站立翻入倒立",

  // backflip
  "learning to stand steady": "先学会稳定站立",
  "learning to land and stand up": "学习落地并重新站起来",
  "carrying the roll over the top": "练习把翻滚带过顶部",
  "punching through the middle": "突破翻滚最难的中段",
  "the whole flip from standing": "从站立完成整套后滚翻",

  // find-ball
  "finding a ball in front": "寻找前方的小球",
  "turning around to find it": "转身寻找四周的小球",
  "keeping up with a rolling ball": "持续跟踪滚动的小球",

  // --- Teach recipe editor ----------------------------------------------------
  "the recipe": "奖励配方",
  "(read-only while training)": "（训练中只读）",
  "— edit it:": "— 可以编辑：",
  "green terms pay points, red ones charge — drag to change how much each":
    "绿色项目给奖励，红色项目扣分 — 拖动滑块可调整每一项的",
  "matters, then retrain.": "权重，然后重新训练。",
  "what pays points": "奖励项",
  "what costs points": "惩罚项",
  "every catalog term is already in the recipe": "所有可用奖励项都已经加入配方",
  "↻ retrain with edited recipe": "↻ 按修改后的配方重新训练",
  "✨ fine-tune the result": "✨ 在当前结果上继续微调",
  "fine-tune keeps what it learned and adjusts; retrain starts fresh":
    "微调会保留已经学会的能力继续调整；重新训练则从头开始",
  "default weight": "默认权重",
  "currently": "当前",
  "added — ✕ puts it back in the picker": "已添加 — 点 ✕ 可移回候选列表",

  // --- Teach live progress ----------------------------------------------------
  "practicing on": "正在并行训练",
  "parallel ducks": "只鸭子",
  "now going": "当前速度",
  "restarting the trainer…": "正在重启训练器…",
  "active": "当前",
  "started at stage": "从阶段开始",
  "skipped this run — its result came from an earlier training":
    "本轮跳过这个阶段 — 直接使用之前训练得到的结果",
  "practices for": "训练",
  "M steps": "M 步",
  "· set by you": "· 由你指定",
  "· its share": "· 按比例分配",
  "this stage's weights (stage overrides win over the chain sliders):":
    "本阶段奖励权重（阶段设置优先于整条训练链的设置）：",
  "✓ apply stage weights": "✓ 应用本阶段权重",
  "▶ start from this stage": "▶ 从这个阶段开始训练",
  "score per practice run (higher = doing the trick better)":
    "每轮训练得分（越高表示动作完成得越好）",
  "where the points come from right now": "当前得分来自哪些奖励项",
  "practice for": "训练总量",
  "↺ recipe": "↺ 恢复默认配方",

  // --- headstand reward terms -------------------------------------------------
  "The one salary: head down, body above it, feet on top, all airborne":
    "核心奖励：头部在下、身体在上、双脚抬高且离地，形成完整头倒立",
  "Points for keeping the body stacked tall on the head":
    "奖励：倒立时身体在头部上方撑高并保持堆叠",
  "Points for keeping the legs straight up while upside down":
    "奖励：倒立时双腿尽量向上伸直",
  "Points for keeping the chin tucked so it stays on the crown":
    "奖励：收紧下巴，让支撑点保持在头顶而不是脸部",
  "Points for kicking BOTH feet up overhead while upside down":
    "奖励：倒立过程中把双脚都踢到头部上方",
  "Points for getting MORE upside down than before":
    "奖励：比前一步进一步接近完全倒立",
  "Points for lifting the feet higher than before":
    "奖励：双脚比前一步抬得更高",
  "Penalty for going over backwards instead":
    "惩罚：向错误方向后翻",
  "Small rent for lying on the ground instead of trying":
    "惩罚：躺在地上不继续尝试",
  "Penalty for resting on the face or underside instead of the crown":
    "惩罚：用脸部或头部下侧撑地，而不是头顶",

  // --- common reward terms ----------------------------------------------------
  "Big points for being upright with ONLY the left foot down": "高额奖励：身体直立且只有左脚着地",
  "Points for holding the right foot ~5 cm off the ground": "奖励：右脚保持离地约 5 cm",
  "Points for keeping the left foot flat on the floor": "奖励：左脚平贴地面",
  "Points for holding the head up in its natural pose": "奖励：头部保持自然抬起姿态",
  "Points for holding the head level and up": "奖励：头部保持水平并抬起",
  "Points for keeping the left foot on the ground": "奖励：左脚稳定着地",
  "Penalty for wobbling and thrashing the body": "惩罚：身体大幅摇晃或乱甩",
  "Penalty for wandering away from the starting spot": "惩罚：偏离起始位置",
  "Penalty for twisting away from the starting direction": "惩罚：身体转离起始朝向",
  "Penalty for drifting away from the spot": "惩罚：慢慢漂离原地",
  "Penalty for jerky, twitchy movements": "惩罚：动作突兀、抖动",
  "Penalty for flailing the joints fast": "惩罚：关节高速乱甩",
  "Penalty for straining the motors": "惩罚：电机持续高负载",
  "Big points for standing at full height": "高额奖励：身体站到正常高度",
  "Points for keeping the body upright": "奖励：身体保持直立",
  "Points for keeping the body level": "奖励：身体保持水平稳定",
  "Points for both feet on the ground": "奖励：双脚着地",
  "Points for keeping both feet on the ground": "奖励：双脚保持着地",
  "Points for keeping the feet flat on the floor": "奖励：双脚平贴地面",
  "Points for standing in the normal ready pose": "奖励：保持正常准备姿态",
  "Penalty for swaying and fidgeting": "惩罚：身体晃动和小动作过多",
  "Penalty for grinding joints against their end stops": "惩罚：关节长期顶在机械限位",
  "Big points for holding the body ~3.5 cm lower than standing": "高额奖励：身体保持在比站立低约 3.5 cm 的高度",
  "Big points for the body near the deep-squat height": "高额奖励：身体接近深蹲目标高度",
  "Points for yaw speed (capped — no points for violence)": "奖励：原地旋转速度（有上限，不鼓励暴力甩动）",
  "Points for lifting the feet to step around (no skid-steering)": "奖励：转身时抬脚迈步，避免贴地打滑",
  "Big points for matching the commanded body-frame speed": "高额奖励：实际速度跟上目标速度",
  "Points for matching the commanded yaw rate": "奖励：转向速度跟上目标指令",
  "Points each step a foot is in a running-length flight": "奖励：跑步时脚有合适的腾空时间",
  "Points for a speed-appropriate leg pose": "奖励：腿部姿态适合当前速度",
  "Points for tracking the head-pose command": "奖励：头部姿态跟随目标",
  "Big points for holding the ball dead centre in the camera": "高额奖励：把球保持在摄像头正中央",
  "Points every step the ball is anywhere in the camera": "奖励：球持续出现在摄像头画面内",
  "Points for squaring the body up to the ball": "奖励：身体正面对准小球",
  "While the ball is lost: points for looking somewhere new": "球丢失时奖励：继续扫描新的方向",
  "While the ball is lost: points for turning the body the way it went": "球丢失时奖励：身体朝球最后出现的方向转动",
  "Penalty for cranking joints to their end stops": "惩罚：关节长时间顶在机械限位",
  "Penalty for shuddering motor forces": "惩罚：电机输出快速抖动",
  "Penalty for slamming down hard": "惩罚：落地冲击过大",
  "Penalty for straining a motor that isn't moving (pure heat)": "惩罚：电机堵转发热"
};

/** Whole-paragraph translations for behavior explanations and stage details. */
const paragraphRules: Array<[RegExp, string]> = [
  [/^The duck tries random wiggles at first and mostly falls over\./,
    "一开始鸭子会随机尝试各种动作并经常摔倒。PPO 会根据每一步的奖励，逐渐保留那些能让它单脚站稳的动作。这个配方还会惩罚乱甩和支撑脚不平。"],
  [/^The simplest trick in the book, and the one everything else is built on\./,
    "这是最基础的动作。它不仅要求身体直立，还要求达到正常站立高度、双脚稳定着地、头部自然，并且能从较低或倾倒姿态重新站起来。"],
  [/^The recipe pays the duck for having its body at the crouch height/,
    "训练会奖励身体达到目标蹲姿高度，同时保持双脚着地和身体直立。站着不动得分不高，直接瘫倒也得不到有效奖励，因此 PPO 会逐渐找到合适的屈膝姿态。"],
  [/^Like crouch, but the target sits under the height/,
    "和普通下蹲类似，但目标更低。为了允许真正深蹲，这个任务关闭了过低高度的终止条件，只保留身体倾倒判定。"],
  [/^Points flow for yaw speed/,
    "主要奖励原地旋转速度，但只有在身体保持稳定、不跑偏时才划算；同时鼓励抬脚转动，避免两只脚贴地打滑。"],
  [/^The salary is the real headstand/,
    "真正的高分来自完整头倒立：头顶接触地面、身体在头上方、双脚抬高并保持稳定。训练还会惩罚压脸、身体拖地和错误方向翻倒。"],
  [/^The duck earns a little for leaning back at all/,
    "后滚翻采用分阶段训练：先学落地站稳，再练翻滚中段，最后把完整动作串起来。真正的大额奖励来自完成一整圈后重新双脚站立。"],
  [/^No stages, no help: every attempt starts from standing\./,
    "这是更激进的后空翻实验：每次都从站立开始，没有辅助和分阶段出生点。它会奖励起跳、向后旋转、收腿以及最终双脚落地。"],
  [/^This one is not asked to invent anything\./,
    "这个模式不是让策略自己发明动作，而是跟随你制作的关键帧动画。策略仍然需要自己解决真实物理中的惯性、接触和平衡。"],
  [/^The scorecard is the official GPU run task/,
    "跑步任务重点奖励实际速度跟随目标速度，并结合腾空时间、姿态和稳定性。它比站立类动作困难得多，本地通常需要很大的训练预算。"],
  [/^The duck is paid every step the ball is in its camera/,
    "球在画面中就有奖励，越接近画面中央奖励越高；球丢失时则奖励继续扫描和转向。最终目标是让身体本身对准球，为后续踢球策略做好姿态。"],

  // Headstand curriculum detail tooltips.
  [/^Almost every rep starts dropped into the stack/,
    "绝大多数练习会直接从接近倒立的姿态开始，并使用较强的辅助舵机。这样新策略能先体验到“成功保持倒立”是什么样，再学会它的价值。"],
  [/^Same drill, servos step down toward the real XL330s/,
    "继续练同一动作，但把舵机模型逐步换成更接近真实 XL330 的 BAM 模型，并加入更真实的初始扰动。"],
  [/^Honest servos, judged harder on DEPTH/,
    "使用真实舵机模型，同时提高倒立垂直度要求：越接近头顶正下、身体垂直向上，每秒获得的奖励越高。"],
  [/^Full competition pricing: only the tall, stacked, crown-vertical hold/,
    "进入高标准阶段：只有身体真正撑高、上下堆叠并接近头顶垂直支撑的姿态，才能拿到主要奖励。"],
  [/^The entry: mostly rolling mid-flip catches plus a 15% share of true standing starts/,
    "最后练习完整进入动作：多数从翻转中段开始接住倒立，另有约 15% 从真正站立姿态起步，把前面的能力串成完整动作。"],

  // Viewport help can arrive as one text node with a source-code newline.
  [/^🎥 drag orbit · scroll zoom · 2-finger swipe slide · A\/D slide ·\s*W\/S·↑↓ dolly · ←\/→ orbit · Q\/E up·down · Shift\+R reset view$/,
    "🎥 拖拽环绕 · 滚轮缩放 · 双指横滑平移 · A/D 平移 · W/S·↑↓ 前后移动 · ←/→ 环绕 · Q/E 上下移动 · Shift+R 重置视角"],
  [/^green terms pay points, red ones charge — drag to change how much each\s+matters, then retrain\.$/,
    "绿色项目给奖励，红色项目扣分 — 拖动滑块调整每项权重，然后重新训练。"],
  [/^The sim runs far faster than real life, so\s*$/,
    "模拟运行速度远快于现实，因此"],
  [/^practice steps run on this\s*Mac without you waiting on a real robot\.$/,
    "个训练步会直接在这台 Mac 上完成，不需要等待真机反复练习。"]
];

const dynamicRules: Array<[RegExp, (...m: string[]) => string]> = [
  // React splits “how it trains — 5 stages, each building on the last:”
  // around the numeric stage count, so translate both neighboring fragments.
  [/^stages,\s*each building on the\s*last:$/i, () => "个阶段，逐步递进："],
  [/^stage (\d+) of (\d+)(.*)$/i, (_all, a, b, rest) => `第 ${a}/${b} 阶段${rest}`],
  [/^stage (\d+)(.*)$/i, (_all, a, rest) => `阶段 ${a}${rest}`],
  [/^started at stage (\d+)$/i, (_all, a) => `从阶段 ${a} 开始`],
  [/^(\d+) helpers?$/i, (_all, n) => `${n} 个辅助鸭子`],
  [/^(\d+) snapshots?$/i, (_all, n) => `${n} 个策略快照`],
  [/^(\d+(?:\.\d+)?)M steps$/i, (_all, n) => `${n}M 步`],
  [/^(\d+(?:\.\d+)?)k steps$/i, (_all, n) => `${n}k 步`],
  [/^(\d+(?:\.\d+)?) practice steps in total$/i, (_all, n) => `总计 ${n} 个训练步`],
  [/^(\d+) stages:\s*(.*)$/i, (_all, n, rest) => `共 ${n} 个阶段：${rest}`],
  [/^practicing on (\d+) parallel ducks \((\d+) helpers?\)$/i,
    (_all, envs, helpers) => `正在使用 ${envs} 个并行环境训练（${helpers} 个辅助鸭子）`],
  [/^training\s*[·:]\s*(.*)$/i, (_all, rest) => `训练中 · ${rest}`],
  [/^done\s*[·:]\s*(.*)$/i, (_all, rest) => `已完成 · ${rest}`],
  [/^How long should it practice\??$/i, () => "训练多久？"],
  [/^Ask.*trick.*$/i, () => "输入英文动作命令，例如 crouch、spin、backflip，或直接点推荐动作"],
  [/^📸 (\d+) snapshots? sent to the 🎓 duck —\s*watch it improve in the scene$/i,
    (_all, n) => `📸 已向 🎓 鸭子发送 ${n} 个策略快照 — 可以在场景里观察它逐步变好`],
  [/^helper cap \((\d+)\)$/i, (_all, n) => `辅助鸭子数量已达上限（${n}）`],
  [/^remove (.+) from the recipe$/i, (_all, key) => `从奖励配方中移除 ${key}`],
  [/^give stage (\d+) its share of the total back$/i, (_all, n) => `让阶段 ${n} 恢复按总训练量自动分配`]
];

function translateCore(core: string): string {
  if (exact[core]) return exact[core];
  for (const [re, zh] of paragraphRules) {
    if (re.test(core)) return zh;
  }
  for (const [re, fn] of dynamicRules) {
    const m = core.match(re);
    if (m) return fn(...m);
  }
  return core;
}

function translateKeepingSpace(text: string): string {
  const m = text.match(/^(\s*)([\s\S]*?)(\s*)$/);
  if (!m) return text;
  const core = m[2];
  if (!core) return text;
  const translated = translateCore(core);
  return `${m[1]}${translated}${m[3]}`;
}

const originalText = new WeakMap<Text, string>();
const originalAttrs = new WeakMap<Element, Record<string, string>>();
const SKIP = new Set(["SCRIPT", "STYLE", "CODE", "PRE", "TEXTAREA"]);

function handleText(node: Text, lang: Lang) {
  const parent = node.parentElement;
  if (!parent || SKIP.has(parent.tagName)) return;

  const current = node.nodeValue ?? "";
  let original = originalText.get(node);
  if (original == null) {
    original = current;
    originalText.set(node, original);
  } else if (current !== original) {
    // If current equals our translation, the MutationObserver is simply
    // seeing our own edit (or a language switch). Otherwise React has reused
    // this Text node for fresh dynamic English and it becomes the new source.
    const translatedOriginal = translateKeepingSpace(original);
    if (current !== translatedOriginal) {
      original = current;
      originalText.set(node, original);
    }
  }

  const next = lang === "zh-CN" ? translateKeepingSpace(original) : original;
  if (node.nodeValue !== next) node.nodeValue = next;
}

function handleAttributes(el: Element, lang: Lang) {
  if (SKIP.has(el.tagName)) return;
  const attrs = ["placeholder", "title", "aria-label"];
  let saved = originalAttrs.get(el);
  if (!saved) {
    saved = {};
    originalAttrs.set(el, saved);
  }

  for (const name of attrs) {
    const current = el.getAttribute(name);
    if (current == null) continue;
    let original = saved[name];
    if (original == null) {
      original = current;
      saved[name] = original;
    } else if (current !== original && current !== translateCore(original)) {
      // React updated a dynamic title/aria label; remember the new English.
      original = current;
      saved[name] = original;
    }
    const next = lang === "zh-CN" ? translateCore(original) : original;
    if (current !== next) el.setAttribute(name, next);
  }
}

function applyLanguage(root: ParentNode, lang: Lang) {
  if (root instanceof Element) handleAttributes(root, lang);

  const walker = document.createTreeWalker(
    root,
    NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT
  );
  let n: Node | null = walker.nextNode();
  while (n) {
    if (n.nodeType === Node.TEXT_NODE) handleText(n as Text, lang);
    else handleAttributes(n as Element, lang);
    n = walker.nextNode();
  }
}

export default function ChineseUI() {
  const [lang, setLang] = useState<Lang>("zh-CN");

  useEffect(() => {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved === "en" || saved === "zh-CN") setLang(saved);
  }, []);

  useEffect(() => {
    localStorage.setItem(STORAGE_KEY, lang);
    document.documentElement.lang = lang;
    if (document.body) applyLanguage(document.body, lang);

    let queued = false;
    const observer = new MutationObserver(() => {
      if (queued) return;
      queued = true;
      queueMicrotask(() => {
        queued = false;
        if (document.body) applyLanguage(document.body, lang);
      });
    });
    observer.observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true,
      attributes: true,
      attributeFilter: ["placeholder", "title", "aria-label"],
    });
    return () => observer.disconnect();
  }, [lang]);

  const chinese = lang === "zh-CN";
  return (
    <button
      type="button"
      title={chinese ? "Switch to English" : "切换到中文"}
      onClick={() => setLang(chinese ? "en" : "zh-CN")}
      style={{
        position: "fixed",
        top: 10,
        right: 10,
        zIndex: 10000,
        border: "1px solid rgba(255,255,255,0.18)",
        borderRadius: 7,
        background: "rgba(18,21,27,0.88)",
        color: "#e8e6e1",
        padding: "6px 9px",
        fontSize: 12,
        fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
        cursor: "pointer",
        backdropFilter: "blur(8px)",
        boxShadow: "0 3px 12px rgba(0,0,0,0.28)",
      }}
    >
      {chinese ? "EN" : "中文"}
    </button>
  );
}
