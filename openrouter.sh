#!/usr/bin/env bash
set -e

echo "=== Configuring OpenRouter for Claude Code ==="
read -rp "Paste your OpenRouter API Key (sk-or-...): " OR_KEY

if [ -z "$OR_KEY" ]; then
  echo "Error: API key cannot be empty."
  exit 1
fi

# Remove any previous OpenRouter block in ~/.bashrc to avoid duplicates
sed -i '/# >>> CLAUDE_OPENROUTER_CONFIG >>>/,/# <<< CLAUDE_OPENROUTER_CONFIG <<</d' "$HOME/.bashrc"

cat << EOF >> "$HOME/.bashrc"
# >>> CLAUDE_OPENROUTER_CONFIG >>>
export PATH="\$HOME/.npm-global/bin:\$PATH"
export OPENROUTER_API_KEY="$OR_KEY"
export ANTHROPIC_BASE_URL="https://openrouter.ai"
export ANTHROPIC_AUTH_TOKEN="\$OPENROUTER_API_KEY"
export ANTHROPIC_API_KEY=""
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
# <<< CLAUDE_OPENROUTER_CONFIG <<<
EOF

echo "=== Configuration Saved! ==="
echo "Run the following two commands to start Claude Code:"
echo "  source ~/.bashrc"
echo "  claude"
