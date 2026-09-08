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
# fix two small implementation details at apply time so switching back to EN
# restores the original React text and TypeScript sees createTreeWalker's root
# as a DOM Node. These replacements are idempotent and harmless once the
# overlay source itself already contains the fixed forms.
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
