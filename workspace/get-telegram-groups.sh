#!/bin/bash
# Get Telegram group IDs for whitelist configuration

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"

if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
  echo "Error: TELEGRAM_BOT_TOKEN not set"
  echo "Export it first: export TELEGRAM_BOT_TOKEN='your-token'"
  exit 1
fi

echo "Fetching recent updates from Telegram bot..."
echo ""

curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" | \
  jq -r '.result[] | select(.message.chat.type == "group" or .message.chat.type == "supergroup") |
    "Group: \(.message.chat.title)\nID: \(.message.chat.id)\nType: \(.message.chat.type)\n"' | \
  sort -u

echo ""
echo "Add these IDs to groupAllowFrom in openclaw.json"
echo "Example: \"groupAllowFrom\": [\"-100XXXXXXXXXX\", \"-100YYYYYYYYYY\"]"
