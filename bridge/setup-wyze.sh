#!/bin/bash
# Prompts for your Wyze login + API key pair and writes them into .env.
# Nothing is echoed back; the password is typed blind. Re-run any time to change them.
cd "$(dirname "$0")"
echo "Wyze credentials -> .env   (API key pair from https://developer-api-console.wyze.com/)"
read -r  -p "Wyze account email : " email
read -rs -p "Wyze password      : " pw; echo
read -r  -p "Key Id             : " kid
read -r  -p "API Key            : " key
[ -n "$email" ] && [ -n "$pw" ] && [ -n "$kid" ] && [ -n "$key" ] || { echo "all four are required; nothing written"; exit 1; }
esc(){ printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }
sed -i '' -e "s|^WYZE_EMAIL=.*|WYZE_EMAIL=$(esc "$email")|" \
          -e "s|^WYZE_PASSWORD=.*|WYZE_PASSWORD=$(esc "$pw")|" \
          -e "s|^WYZE_API_ID=.*|WYZE_API_ID=$(esc "$kid")|" \
          -e "s|^WYZE_API_KEY=.*|WYZE_API_KEY=$(esc "$key")|" .env
chmod 600 .env; echo "saved to .env"
