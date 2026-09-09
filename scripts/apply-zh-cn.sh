#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEWER="$ROOT/microduck-lab/duck-viewer"
OVERLAY="$ROOT/overlays/zh-cn/ChineseUI.tsx"
TARGET="$VIEWER/components/ChineseUI.tsx"
LAYOUT="$VIEWER/app/layout.tsx"

if [ ! -d "$VIEWER" ]; then
  echo "microduck-lab viewer not found: $VIEWER" >&2
  echo "Run: git submodule update --init --recursive" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is required to apply the Chinese UI overlay." >&2
  exit 1
fi

if [ ! -f "$OVERLAY" ]; then
  echo "Chinese UI overlay not found: $OVERLAY" >&2
  exit 1
fi

cp "$OVERLAY" "$TARGET"

# Keep the overlay resilient while it lives outside the upstream submodule:
# fix small implementation details and add translations for local behavior
# overlays at apply time. This lets user-specific reward experiments live in
# the superproject without permanently forking the upstream viewer.
node - "$TARGET" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
let s = fs.readFileSync(path, "utf8");
s = s.replace(
  '} else if (lang === "en" && current !== original) {\n      original = current;',
  '} else if (lang === "en" && current !== original && current !== expected) {\n      original = current;'
);
s = s.replace(
  'function applyLanguage(root: ParentNode, lang: Lang) {',
  'function applyLanguage(root: Node, lang: Lang) {'
);

const anchor = 'const exact: Record<string, string> = {';
if (!s.includes(anchor)) {
  throw new Error("Could not locate ChineseUI exact-string table.");
}
const localTranslations = [
  [
    "Points for holding the right foot ~8 cm off the ground",
    "奖励：右脚保持离地约 8 cm",
  ],
  [
    "Big points for holding the right foot steady near 8 cm",
    "高额奖励：右脚在约 8 cm 高度稳定悬停",
  ],
  [
    "Penalty for moving the lifted right foot up and down after it is raised",
    "惩罚：右脚抬起后继续上下运动",
  ],
  [
    "Penalty for repeatedly reversing the lifted right foot up and down",
    "惩罚：右脚反复上下换向",
  ],
  [
    "Penalty for drifting away from the 8 cm right-foot hover height",
    "惩罚：右脚偏离 8 cm 悬停高度",
  ],
  [
    "Penalty for sustained oscillation of the lifted right foot over a short time window",
    "惩罚：右脚在短时间窗口内持续振荡",
  ],
];
for (const [en, zh] of localTranslations) {
  const key = JSON.stringify(en);
  if (!s.includes(key)) {
    const entry = `\n  ${key}: ${JSON.stringify(zh)},`;
    s = s.replace(anchor, anchor + entry);
  }
}

fs.writeFileSync(path, s);
NODE

node - "$LAYOUT" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
let s = fs.readFileSync(path, "utf8");

if (!s.includes('import ChineseUI from "@/components/ChineseUI";')) {
  const anchor = 'import type { Metadata } from "next";';
  if (!s.includes(anchor)) {
    throw new Error("Could not find the Metadata import in app/layout.tsx; upstream layout changed.");
  }
  s = s.replace(anchor, `${anchor}\nimport ChineseUI from "@/components/ChineseUI";`);
}

s = s.replace(/<html\s+lang="en">/, '<html lang="zh-CN">');

if (!s.includes("<ChineseUI />")) {
  const bodyWithChildren = /<body([^>]*)>\s*\{children\}\s*<\/body>/m;
  if (!bodyWithChildren.test(s)) {
    throw new Error("Could not inject <ChineseUI /> into app/layout.tsx; upstream layout changed.");
  }
  s = s.replace(bodyWithChildren, '<body$1><ChineseUI />{children}</body>');
}

fs.writeFileSync(path, s);
NODE

echo "✓ Chinese UI overlay applied"
echo "  Default: 中文"
echo "  Toggle: top-right EN / 中文 button"
