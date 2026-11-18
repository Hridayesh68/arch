#!/usr/bin/env bash
set -e

echo "=== 1. Configuring npm Global Directory ==="
mkdir -p "$HOME/.npm-global"
npm config set prefix "$HOME/.npm-global"
export PATH="$HOME/.npm-global/bin:$PATH"

if ! grep -q '.npm-global/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.bashrc"
fi

echo "=== 2. Installing Claude Code & Native Binary ==="
npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code

# Fallback check if native binary still needs manual postinstall
INSTALL_SCRIPT="$HOME/.npm-global/lib/node_modules/@anthropic-ai/claude-code/install.cjs"
if [ -f "$INSTALL_SCRIPT" ]; then
  node "$INSTALL_SCRIPT" || true
fi

echo "=== 3. Verifying Claude Code Installation ==="
claude --version
echo "=== Claude Code Binary Verified! ==="
