#!/bin/bash

# Exit on error
set -e

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

# Setup local bin directory
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
export PATH="$LOCAL_BIN:$PATH"

# Auto-install/download fzf if missing
if ! command -v fzf &>/dev/null; then
  echo "fzf not found. Downloading..." >&2
  
  # Determine architecture
  ARCH=$(uname -m)
  FZF_URL=""
  if [ "$ARCH" = "x86_64" ]; then
    FZF_URL="https://github.com/junegunn/fzf/releases/download/v0.52.1/fzf-0.52.1-linux_amd64.tar.gz"
  elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    FZF_URL="https://github.com/junegunn/fzf/releases/download/v0.52.1/fzf-0.52.1-linux_arm64.tar.gz"
  else
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
  fi

  # Download and extract to local bin
  TEMP_TAR=$(mktemp)
  curl -sSL "$FZF_URL" -o "$TEMP_TAR"
  tar -xzf "$TEMP_TAR" -C "$LOCAL_BIN" fzf
  rm -f "$TEMP_TAR"
  chmod +x "$LOCAL_BIN/fzf"
  echo "fzf downloaded successfully." >&2
fi

# Ensure jq is installed
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

# Fetch all repositories
echo "Fetching GitHub repositories..." >&2
PAGE=1
REPOS=""

while true; do
  RESPONSE=$(curl -s -H "Authorization: token $GIT_TOKEN" \
    "https://api.github.com/user/repos?per_page=100&page=$PAGE")
  
  # Check if request succeeded or if it returned an error (like invalid token)
  MESSAGE=$(echo "$RESPONSE" | jq -r '.message' 2>/dev/null)
  if [ "$MESSAGE" != "null" ] && [ -n "$MESSAGE" ]; then
    echo "GitHub API Error: $MESSAGE" >&2
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

# Select repository using fzf
SELECTED=$(echo "$REPOS" | fzf --ansi --header="Select repository to deploy (Type to search, Enter to select, Esc to cancel)" --preview 'echo "URL: {2}"')

if [ -z "$SELECTED" ]; then
  echo "Selection cancelled." >&2
  exit 1
fi

REPO_NAME=$(echo "$SELECTED" | awk '{print $1}')
REPO_URL=$(echo "$SELECTED" | awk '{print $2}')

echo "Selected Repository: $REPO_NAME"
echo "Repository URL: $REPO_URL"
