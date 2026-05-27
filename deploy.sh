#!/bin/bash

# Exit on error
set -e

# Auto-update script from git repository
if [ -z "$EASY_DEPLOY_UPDATED" ] && command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Checking for script updates..." >&2
  git fetch --quiet origin || true
  LOCAL=$(git rev-parse HEAD)
  REMOTE=$(git rev-parse @{u} 2>/dev/null || echo "")
  if [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
    echo "Updating script to latest version..." >&2
    if git pull --quiet; then
      echo "Script updated. Restarting..." >&2
      export EASY_DEPLOY_UPDATED=1
      if [ -x "$0" ]; then
        exec "$0" "$@"
      else
        exec bash "$0" "$@"
      fi
    fi
  fi
fi


# Update and upgrade Debian/Ubuntu system packages
if [ -f /etc/debian_version ] || command -v apt-get &>/dev/null; then
  echo "Debian/Ubuntu detected. Updating and upgrading packages..." >&2
  sudo apt-get update
  sudo apt-get upgrade -y
fi


# Load environment variables
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

# Ensure GIT_TOKEN is set
if [ -z "$GIT_TOKEN" ]; then
  echo "Error: GIT_TOKEN is not set." >&2
  echo "Please set it in .env file or environment." >&2
  exit 1
fi

# Auto-install fzf if missing using apt
if ! command -v fzf &>/dev/null; then
  echo "fzf not found. Installing via apt..." >&2
  sudo apt-get install -y fzf
fi

# Auto-install jq if missing using apt
if ! command -v jq &>/dev/null; then
  echo "jq not found. Installing via apt..." >&2
  sudo apt-get install -y jq
fi

# Fetch all repositories
echo "Fetching GitHub repositories..." >&2
PAGE=1
REPOS=""

while true; do
  RESPONSE_FILE=$(mktemp)
  CURL_EXIT=0
  HTTP_STATUS=$(curl -s -w "%{http_code}" -o "$RESPONSE_FILE" \
    --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer $GIT_TOKEN" \
    "https://api.github.com/user/repos?per_page=100&page=$PAGE") || CURL_EXIT=$?

  if [ "$CURL_EXIT" -ne 0 ]; then
    echo "Error: curl command failed with exit code $CURL_EXIT." >&2
    echo "Please check your network connection and DNS settings." >&2
    rm -f "$RESPONSE_FILE"
    exit 1
  fi

  if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "Error: GitHub API returned HTTP status $HTTP_STATUS." >&2
    cat "$RESPONSE_FILE" >&2
    echo "" >&2
    rm -f "$RESPONSE_FILE"
    exit 1
  fi

  RESPONSE=$(cat "$RESPONSE_FILE")
  rm -f "$RESPONSE_FILE"

  if ! echo "$RESPONSE" | jq empty &>/dev/null; then
    echo "Error: Invalid JSON response received from GitHub." >&2
    exit 1
  fi

  COUNT=$(echo "$RESPONSE" | jq '. | length' 2>/dev/null || echo 0)
  if [ "$COUNT" -eq 0 ]; then
    break
  fi

  PAGE_REPOS=$(echo "$RESPONSE" | jq -r '.[] | "\(.full_name) \(.html_url)"')
  if [ -n "$REPOS" ]; then
    REPOS="${REPOS}
${PAGE_REPOS}"
  else
    REPOS="$PAGE_REPOS"
  fi

  if [ "$COUNT" -lt 100 ]; then
    break
  fi
  PAGE=$((PAGE+1))
done

# Filter out any empty lines
REPOS=$(echo "$REPOS" | grep -v '^$')

if [ -z "$REPOS" ]; then
  echo "No repositories found." >&2
  exit 0
fi

# Count repositories
REPO_COUNT=$(echo "$REPOS" | wc -l)
echo "Fetched $REPO_COUNT repositories." >&2

# Select repository using fzf (optimized for mobile/narrow screens)
SELECTED=$(echo "$REPOS" | fzf --ansi \
  --header="Select repository to deploy (Type to search, Enter to select, Esc to cancel)" \
  --with-nth=1 \
  --preview='echo "URL: {2}"' \
  --preview-window='down:1:wrap') || SELECTED=""

if [ -z "$SELECTED" ]; then
  echo "Selection cancelled." >&2
  exit 1
fi

REPO_NAME=$(echo "$SELECTED" | awk '{print $1}')
REPO_URL=$(echo "$SELECTED" | awk '{print $2}')

# Extract directory name from URL
DIR_NAME=$(basename "$REPO_URL")

echo "Selected Repository: $REPO_NAME"

# Clone or pull repository
if [ -d "$DIR_NAME" ]; then
  echo "Directory $DIR_NAME already exists. Pulling latest..." >&2
  cd "$DIR_NAME"
  git pull
else
  echo "Cloning repository..." >&2
  AUTH_URL=$(echo "$REPO_URL" | sed "s|https://|https://${GIT_TOKEN}@|")
  git clone "$AUTH_URL"
  cd "$DIR_NAME"
fi

echo "Now in directory: $(pwd)"

