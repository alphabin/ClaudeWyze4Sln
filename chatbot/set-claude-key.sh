#!/bin/bash
# Stores your Anthropic API key in ../.env so CleoBot can answer free-form questions with Claude.
# Get a key at https://console.anthropic.com/  ->  API Keys  ->  Create Key.  Typed blind; never echoed.
cd "$(dirname "$0")/.."
read -rs -p "Anthropic API key (starts with sk-ant-): " key; echo
[ -n "$key" ] || { echo "nothing entered; .env unchanged"; exit 1; }
if grep -qE "^#? ?ANTHROPIC_API_KEY=" .env; then
  sed -i '' -E "s|^#? ?ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=$key|" .env
else
  echo "ANTHROPIC_API_KEY=$key" >> .env
fi
chmod 600 .env
echo "saved. Restarting the bot…"
launchctl unload ~/Library/LaunchAgents/com.snakecam.chatbot.plist 2>/dev/null; sleep 1; launchctl load ~/Library/LaunchAgents/com.snakecam.chatbot.plist
sleep 5; tail -2 ~/Library/Logs/snakecam-chatbot.log
