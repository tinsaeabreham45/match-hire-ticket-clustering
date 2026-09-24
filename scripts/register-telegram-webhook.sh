#!/usr/bin/env bash
set -euo pipefail

project_dir="${1:-$(pwd)}"
env_file="$project_dir/.env"
webhook_url="${TELEGRAM_WEBHOOK_URL:-https://16.170.93.79.nip.io/webhook/telegram-support-v1}"

if [[ ! -r "$env_file" ]]; then
  echo "Cannot read $env_file." >&2
  exit 2
fi

webhook_secret="$({
  sed -n 's/^TELEGRAM_WEBHOOK_SECRET=//p' "$env_file" || true
} | tail -n 1)"
webhook_secret="${webhook_secret%$'\r'}"

if [[ ! "$webhook_secret" =~ ^[A-Za-z0-9_-]{1,256}$ ]]; then
  echo "TELEGRAM_WEBHOOK_SECRET is missing or invalid in $env_file." >&2
  exit 2
fi

if [[ ! "$webhook_url" =~ ^https://[^[:space:]]+/webhook/telegram-support-v1$ ]]; then
  echo "Refusing unexpected Telegram webhook URL: $webhook_url" >&2
  exit 2
fi

read -r -s -p "Paste the BotFather token (input hidden; it will not be stored): " bot_token
echo

if [[ ! "$bot_token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
  unset bot_token
  echo "The BotFather token format is invalid." >&2
  exit 2
fi

response_file="$(mktemp)"
trap 'unset bot_token webhook_secret; rm -f "$response_file"' EXIT

# Pass the token through curl's standard input so it is not exposed in the
# process command line, shell history, the repository, or n8n execution data.
curl --silent --show-error --fail-with-body --config - >"$response_file" <<CURL_CONFIG
url = "https://api.telegram.org/bot${bot_token}/setWebhook"
request = "POST"
form = "url=${webhook_url}"
form = "secret_token=${webhook_secret}"
form = "allowed_updates=[\"message\",\"callback_query\"]"
form = "drop_pending_updates=true"
CURL_CONFIG

unset bot_token webhook_secret

if command -v jq >/dev/null 2>&1; then
  if ! jq -e '.ok == true and .result == true' "$response_file" >/dev/null; then
    jq '{ok, error_code, description}' "$response_file" >&2
    exit 1
  fi
else
  if ! grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "$response_file"; then
    echo "Telegram rejected the webhook registration." >&2
    exit 1
  fi
fi

echo "Telegram accepted the production webhook. Pending pre-rollout updates were discarded."
