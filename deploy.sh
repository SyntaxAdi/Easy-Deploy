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

# Auto-install python3 and pip3 if missing using apt
if ! command -v python3 &>/dev/null || ! command -v pip3 &>/dev/null; then
  echo "Python3 or pip3 not found. Installing via apt..." >&2
  sudo apt-get install -y python3 python3-pip
fi

# Auto-install screen if missing using apt
if ! command -v screen &>/dev/null; then
  echo "screen not found. Installing via apt..." >&2
  sudo apt-get install -y screen
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

# Install requirements.txt if present
if [ -f requirements.txt ]; then
  echo "requirements.txt found. Installing Python packages..." >&2
  if pip3 install --help | grep -q 'break-system-packages'; then
    pip3 install -r requirements.txt --break-system-packages
  else
    pip3 install -r requirements.txt
  fi
fi

# Scan for .env file or create it
if [ -f .env ]; then
  echo ".env exists." >&2
else
  echo ".env file not found. Let's configure it." >&2
  while true; do
    echo "Choose configuration method:" >&2
    echo "1) Paste entire .env file (multi-line)" >&2
    echo "2) Enter keys manually (one by one)" >&2
    if [ -f config.py ]; then
      echo "3) Scan config.py and fill values" >&2
    fi
    read -p "Select option: " ENV_OPT
    
    if [ "$ENV_OPT" = "1" ] || [ "$ENV_OPT" = "2" ] || { [ "$ENV_OPT" = "3" ] && [ -f config.py ]; }; then
      break
    fi
    echo "Invalid option." >&2
  done

  if [ "$ENV_OPT" = "1" ]; then
    echo "Paste your .env content below, then press Enter and Ctrl+D to save:" >&2
    cat > .env
    echo ".env file created." >&2
  elif [ "$ENV_OPT" = "2" ]; then
    echo "Enter environment variables (press Enter on empty key to finish):" >&2
    while true; do
      read -p "Enter KEY (or KEY=VALUE): " INPUT_KEY
      if [ -z "$INPUT_KEY" ]; then
        break
      fi
      if [[ "$INPUT_KEY" == *"="* ]]; then
        echo "$INPUT_KEY" >> .env
      else
        read -p "Enter value for $INPUT_KEY: " INPUT_VAL
        echo "${INPUT_KEY}=${INPUT_VAL}" >> .env
      fi
    done
    echo ".env file created." >&2
  elif [ "$ENV_OPT" = "3" ] && [ -f config.py ]; then
    echo "Scanning config.py for variables..." >&2
    VARS=$(python3 - <<'EOF'
import re
try:
    with open("config.py", "r", encoding="utf-8") as f:
        content = f.read()
    vars_found = []
    vars_found.extend(re.findall(r"^[A-Z_][A-Z0-9_]*(?=\s*=)", content, re.MULTILINE))
    vars_found.extend(re.findall(r"(?:getenv|environ\.get)\([\"\']([A-Z_][A-Z0-9_]*)[\"\']", content))
    vars_found.extend(re.findall(r"environ\[[\"\']([A-Z_][A-Z0-9_]*)[\"\']\]", content))
    for v in sorted(list(set(vars_found))):
        print(v)
except Exception:
    pass
EOF
)
    if [ -z "$VARS" ]; then
      echo "No variables found in config.py. Switching to manual mode." >&2
      echo "Enter environment variables (press Enter on empty key to finish):" >&2
      while true; do
        read -p "Enter KEY (or KEY=VALUE): " INPUT_KEY
        if [ -z "$INPUT_KEY" ]; then
          break
        fi
        if [[ "$INPUT_KEY" == *"="* ]]; then
          echo "$INPUT_KEY" >> .env
        else
          read -p "Enter value for $INPUT_KEY: " INPUT_VAL
          echo "${INPUT_KEY}=${INPUT_VAL}" >> .env
        fi
      done
    else
      echo "Provide values for discovered variables:" >&2
      for v in $VARS; do
        read -p "Value for $v: " VAL
        echo "${v}=${VAL}" >> .env
      done
      echo ".env file created." >&2
    fi
  fi
fi

# Ensure .env is present before proceeding
if [ ! -f .env ]; then
  echo "Error: .env configuration is incomplete. Aborting deployment." >&2
  exit 1
fi

# List python and shell files at root level
LAUNCH_FILES=""
for f in *.py *.sh; do
  if [ -f "$f" ]; then
    LAUNCH_FILES="${LAUNCH_FILES}${f}
"
  fi
done
LAUNCH_FILES=$(echo "$LAUNCH_FILES" | grep -v '^$')

if [ -z "$LAUNCH_FILES" ]; then
  echo "No Python (.py) or Shell (.sh) files found in root directory." >&2
  exit 1
fi

# Select main file using fzf
SELECTED_FILE=$(echo "$LAUNCH_FILES" | fzf --ansi --header="Select the main file to start" --preview-window='hidden') || SELECTED_FILE=""

if [ -z "$SELECTED_FILE" ]; then
  echo "File selection cancelled." >&2
  exit 1
fi

# Generate safe screen name
SCREEN_NAME=$(echo "bot-${DIR_NAME}" | sed 's/[^a-zA-Z0-9_-]/-/g')

# Start file inside screen and detach
if [[ "$SELECTED_FILE" == *.sh ]]; then
  echo "Starting $SELECTED_FILE inside screen session $SCREEN_NAME..." >&2
  screen -dmS "$SCREEN_NAME" bash "$SELECTED_FILE"
else
  echo "Starting $SELECTED_FILE inside screen session $SCREEN_NAME..." >&2
  screen -dmS "$SCREEN_NAME" python3 "$SELECTED_FILE"
fi

echo "Session started and detached." >&2
echo "To view session, run: screen -r $SCREEN_NAME" >&2


