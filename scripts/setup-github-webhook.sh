#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <owner/repo> <tau-api-base>" >&2
  echo "Example: $0 ficushq/tau https://tau.xyz" >&2
  exit 1
fi

REPO="$1"
API_BASE="$2"
WEBHOOK_URL="$API_BASE/api/webhooks/github"

CONTENT_TYPE="json"
EVENTS=(
  "issues"
  "issue_comment"
  "pull_request"
  "pull_request_review"
  "pull_request_review_comment"
  "workflow_run"
)

: "${FICUS_GITHUB_HOOK_SETUP_SECRET:?Set FICUS_GITHUB_HOOK_SETUP_SECRET to the same new secret entered in Settings > Integrations > GitHub > Webhook delivery}"

echo "Checking GitHub auth..."
gh auth status

echo "Checking repo permission..."
gh repo view "$REPO" --json nameWithOwner,viewerPermission,visibility

echo "Looking for existing webhook for $WEBHOOK_URL..."
HOOK_ID="$(
  gh api "repos/$REPO/hooks" \
    --jq ".[] | select(.config.url == \"$WEBHOOK_URL\") | .id" \
    | head -n1
)"

if [ -n "$HOOK_ID" ]; then
  echo "Existing webhook found: $HOOK_ID"
  echo "Updating webhook..."

  cmd=(gh api --method PATCH "repos/$REPO/hooks/$HOOK_ID"
    -f "config[url]=$WEBHOOK_URL"
    -f "config[content_type]=$CONTENT_TYPE"
    -f "config[secret]=$FICUS_GITHUB_HOOK_SETUP_SECRET"
    -f "config[insecure_ssl]=0"
    -F active=true
  )

  for event in "${EVENTS[@]}"; do
    cmd+=(-f "events[]=$event")
  done

  "${cmd[@]}" >/dev/null
else
  echo "Creating webhook..."

  cmd=(gh api --method POST "repos/$REPO/hooks"
    -f name=web
    -f "config[url]=$WEBHOOK_URL"
    -f "config[content_type]=$CONTENT_TYPE"
    -f "config[secret]=$FICUS_GITHUB_HOOK_SETUP_SECRET"
    -f "config[insecure_ssl]=0"
    -F active=true
  )

  for event in "${EVENTS[@]}"; do
    cmd+=(-f "events[]=$event")
  done

  HOOK_ID="$("${cmd[@]}" --jq '.id')"
fi

echo "Verifying webhook..."
gh api "repos/$REPO/hooks/$HOOK_ID" \
  --jq '{id, active, events, url: .config.url, content_type: .config.content_type, last_response}'

echo "Done. Webhook ID: $HOOK_ID"
