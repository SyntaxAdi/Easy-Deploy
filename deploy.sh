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

# Choose operation mode
echo "Choose operation mode:" >&2
echo "1) Clone and deploy a new repository" >&2
echo "2) Manage and redeploy an existing cloned repository" >&2
if [ -n "$NEON_DB_URL" ]; then
  echo "3) Deploy from saved Neon database configuration (One-click deploy)" >&2
fi
while true; do
  read -p "Select option: " OP_MODE
  if [ "$OP_MODE" = "1" ] || [ "$OP_MODE" = "2" ] || { [ "$OP_MODE" = "3" ] && [ -n "$NEON_DB_URL" ]; }; then
    break
  fi
  echo "Invalid option." >&2
done

if [ "$OP_MODE" = "3" ] && [ -n "$NEON_DB_URL" ]; then
  echo "Fetching configurations from Neon database..." >&2
  CONFIGS=$(python3 - <<'EOF'
import sys, os, urllib.parse
db_url = os.environ.get("NEON_DB_URL")
if not db_url:
    print("Error: NEON_DB_URL not set.", file=sys.stderr)
    sys.exit(1)

try:
    import pg8000.dbapi
except ImportError:
    import subprocess
    pip_cmd = [sys.executable, "-m", "pip", "install", "pg8000"]
    help_out = subprocess.run([sys.executable, "-m", "pip", "install", "--help"], capture_output=True, text=True).stdout
    if "break-system-packages" in help_out:
        pip_cmd.append("--break-system-packages")
    subprocess.run(pip_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    import pg8000.dbapi

try:
    url = urllib.parse.urlparse(db_url)
    conn = pg8000.dbapi.connect(
        user=url.username,
        password=url.password,
        host=url.hostname,
        port=url.port or 5432,
        database=url.path[1:],
        ssl_context=True
    )
    cursor = conn.cursor()
    cursor.execute("CREATE TABLE IF NOT EXISTS deployments (id SERIAL PRIMARY KEY, name VARCHAR(255) UNIQUE NOT NULL, repo_url TEXT NOT NULL, folder_name VARCHAR(255) NOT NULL, env_content TEXT NOT NULL, start_cmd VARCHAR(255) NOT NULL, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)")
    conn.commit()
    
    cursor.execute("SELECT name, repo_url, folder_name, start_cmd FROM deployments ORDER BY name")
    rows = cursor.fetchall()
    if not rows:
        print("No configurations found.", file=sys.stderr)
        sys.exit(0)
    for r in rows:
        print(f"{r[0]}\t{r[1]}\t{r[2]}\t{r[3]}")
    cursor.close()
    conn.close()
except Exception as e:
    print(f"Database error: {e}", file=sys.stderr)
    sys.exit(1)
EOF
)

  if [ -z "$CONFIGS" ] || [ "$CONFIGS" = "No configurations found." ]; then
    echo "No saved configurations found. Switching to clone mode..." >&2
    OP_MODE="1"
  else
    # Select using fzf with multi-selection enabled
    SELECTED_CONFIGS=$(echo "$CONFIGS" | fzf --ansi -m --header="Select configuration(s) to deploy (Press Tab to select multiple, Enter to confirm)" --preview-window='hidden') || SELECTED_CONFIGS=""
    if [ -z "$SELECTED_CONFIGS" ]; then
      echo "Selection cancelled." >&2
      exit 1
    fi
    
    ROOT_DIR=$(pwd)

    echo "$SELECTED_CONFIGS" | while read -r LINE; do
      if [ -z "$LINE" ]; then
        continue
      fi
      
      cd "$ROOT_DIR"
      
      CONFIG_NAME=$(echo "$LINE" | cut -f1)
      REPO_URL=$(echo "$LINE" | cut -f2)
      DIR_NAME=$(echo "$LINE" | cut -f3)
      SELECTED_FILE=$(echo "$LINE" | cut -f4)
      
      echo "----------------------------------------" >&2
      echo "Deploying configuration: $CONFIG_NAME..." >&2
      
      # Retrieve env content from DB
      ENV_CONTENT=$(export CONFIG_NAME; python3 - <<'EOF'
import sys, os, urllib.parse, pg8000.dbapi
db_url = os.environ.get("NEON_DB_URL")
cfg_name = os.environ.get("CONFIG_NAME")
try:
    url = urllib.parse.urlparse(db_url)
    conn = pg8000.dbapi.connect(
        user=url.username, password=url.password, host=url.hostname, port=url.port or 5432, database=url.path[1:], ssl_context=True
    )
    cursor = conn.cursor()
    cursor.execute("SELECT env_content FROM deployments WHERE name = %s", [cfg_name])
    row = cursor.fetchone()
    if row:
        print(row[0], end="")
    cursor.close()
    conn.close()
except Exception:
    sys.exit(1)
EOF
)

      # Perform deployment using saved configuration
      if [ -d "$DIR_NAME" ]; then
        echo "Directory $DIR_NAME already exists. Pulling latest..." >&2
        cd "$DIR_NAME"
        git pull
      else
        echo "Cloning repository..." >&2
        AUTH_URL=$(echo "$REPO_URL" | sed "s|https://|https://${GIT_TOKEN}@|")
        git clone "$AUTH_URL" "$DIR_NAME"
        cd "$DIR_NAME"
      fi
      
      # Write saved .env content
      echo "$ENV_CONTENT" > .env
      echo ".env file restored from database." >&2
      
      # Install requirements.txt if present
      if [ -f requirements.txt ]; then
        echo "Installing Python packages..." >&2
        if pip3 install --help | grep -q 'break-system-packages'; then
          pip3 install -r requirements.txt --break-system-packages
        else
          pip3 install -r requirements.txt
        fi
      fi

      # Generate safe screen name
      SCREEN_NAME=$(echo "bot-${DIR_NAME}" | sed 's/[^a-zA-Z0-9_-]/-/g')

      # Terminate existing screen session with the same name if running
      if screen -list | grep -q "\.${SCREEN_NAME}\s"; then
        echo "Stopping existing screen session: $SCREEN_NAME..." >&2
        screen -XS "$SCREEN_NAME" quit 2>/dev/null || true
        sleep 1
      fi

      # Start file inside screen and detach
      if [[ "$SELECTED_FILE" == *.sh ]]; then
        echo "Starting $SELECTED_FILE inside screen session $SCREEN_NAME..." >&2
        screen -dmS "$SCREEN_NAME" bash "$SELECTED_FILE"
      else
        echo "Starting $SELECTED_FILE inside screen session $SCREEN_NAME..." >&2
        screen -dmS "$SCREEN_NAME" python3 "$SELECTED_FILE"
      fi

      echo "Session started and detached for: $SCREEN_NAME" >&2
    done
    
    exit 0
  fi
fi

if [ "$OP_MODE" = "2" ]; then
  # Find existing cloned repositories
  EXISTING_REPOS=$(find . -maxdepth 2 -name ".git" -type d 2>/dev/null | sed 's|/\.git$||' | sed 's|^\./||' | grep -v '^$' | grep -v '^\.$') || EXISTING_REPOS=""

  if [ -z "$EXISTING_REPOS" ]; then
    echo "No existing cloned repositories found. Switching to cloning mode..." >&2
    OP_MODE="1"
  else
    # Select existing repo using fzf
    SELECTED_DIR=$(echo "$EXISTING_REPOS" | fzf --ansi --header="Select an existing repository directory" --preview-window='hidden') || SELECTED_DIR=""
    
    if [ -z "$SELECTED_DIR" ]; then
      echo "Selection cancelled." >&2
      exit 1
    fi
    
    DIR_NAME="$SELECTED_DIR"
    cd "$DIR_NAME"
    echo "Selected directory: $DIR_NAME" >&2

    # Choose actions for existing repo
    echo "Choose action for $DIR_NAME:" >&2
    echo "1) Pull latest updates and restart bot" >&2
    echo "2) Reconfigure/update .env and restart bot" >&2
    echo "3) Reinstall python dependencies and restart bot" >&2
    echo "4) Just restart bot" >&2
    read -p "Select action (1/2/3/4): " MANAGE_OPT

    if [ "$MANAGE_OPT" = "1" ]; then
      echo "Pulling latest updates..." >&2
      git pull
      INSTALL_DEPS=1
    elif [ "$MANAGE_OPT" = "2" ]; then
      echo "Removing current .env for reconfiguration..." >&2
      rm -f .env
    elif [ "$MANAGE_OPT" = "3" ]; then
      echo "Flagging dependencies for reinstall..." >&2
      INSTALL_DEPS=1
      FORCE_REINSTALL=1
    fi
  fi
fi

if [ "$OP_MODE" = "1" ]; then
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

  # Extract default directory name from URL
  DEFAULT_DIR=$(basename "$REPO_URL")
  read -p "Enter target folder name [$DEFAULT_DIR]: " CUSTOM_DIR
  DIR_NAME="${CUSTOM_DIR:-$DEFAULT_DIR}"

  echo "Selected Repository: $REPO_NAME"

  # Clone or pull repository
  if [ -d "$DIR_NAME" ]; then
    echo "Directory $DIR_NAME already exists. Pulling latest..." >&2
    cd "$DIR_NAME"
    git pull
  else
    echo "Cloning repository..." >&2
    AUTH_URL=$(echo "$REPO_URL" | sed "s|https://|https://${GIT_TOKEN}@|")
    git clone "$AUTH_URL" "$DIR_NAME"
    cd "$DIR_NAME"
  fi
  INSTALL_DEPS=1
fi

echo "Now in directory: $(pwd)"

# Install requirements.txt if present and requested
if [ "$INSTALL_DEPS" = "1" ] && [ -f requirements.txt ]; then
  echo "Installing Python packages..." >&2
  PIP_FLAGS=""
  if [ "$FORCE_REINSTALL" = "1" ]; then
    PIP_FLAGS="--force-reinstall --no-cache-dir"
  fi
  
  if pip3 install --help | grep -q 'break-system-packages'; then
    pip3 install $PIP_FLAGS -r requirements.txt --break-system-packages
  else
    pip3 install $PIP_FLAGS -r requirements.txt
  fi
fi

if [ -z "$DB_DEPLOYED" ]; then
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
fi

# Ensure .env is present before proceeding
if [ ! -f .env ]; then
  echo "Error: .env configuration is incomplete. Aborting deployment." >&2
  exit 1
fi

if [ -z "$DB_DEPLOYED" ]; then
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
fi

# Generate safe screen name
SCREEN_NAME=$(echo "bot-${DIR_NAME}" | sed 's/[^a-zA-Z0-9_-]/-/g')

# Terminate existing screen session with the same name if running
if screen -list | grep -q "\.${SCREEN_NAME}\s"; then
  echo "Stopping existing screen session: $SCREEN_NAME..." >&2
  screen -XS "$SCREEN_NAME" quit 2>/dev/null || true
  # Sleep briefly to ensure session is released
  sleep 1
fi

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

# Save deployment configuration to Neon if enabled
if [ -n "$NEON_DB_URL" ] && [ -z "$DB_DEPLOYED" ]; then
  read -p "Would you like to save/update this configuration in Neon database? (y/N): " SAVE_CONF
  if [[ "$SAVE_CONF" =~ ^[Yy]$ ]]; then
    read -p "Enter a unique name for this deployment configuration: " CONF_NAME_INPUT
    if [ -n "$CONF_NAME_INPUT" ]; then
      echo "Saving configuration to Neon..." >&2
      if [ -z "$REPO_URL" ]; then
        REPO_URL=$(git config --get remote.origin.url 2>/dev/null || echo "")
      fi
      ENV_VALS=$(cat .env 2>/dev/null || echo "")
      
      export CONF_NAME_INPUT REPO_URL DIR_NAME SELECTED_FILE ENV_VALS
      python3 - <<'EOF'
import sys, os, urllib.parse
db_url = os.environ.get("NEON_DB_URL")
cfg_name = os.environ.get("CONF_NAME_INPUT")
repo_url = os.environ.get("REPO_URL")
folder_name = os.environ.get("DIR_NAME")
env_content = os.environ.get("ENV_VALS")
start_cmd = os.environ.get("SELECTED_FILE")

try:
    import pg8000.dbapi
except ImportError:
    import subprocess
    pip_cmd = [sys.executable, "-m", "pip", "install", "pg8000"]
    help_out = subprocess.run([sys.executable, "-m", "pip", "install", "--help"], capture_output=True, text=True).stdout
    if "break-system-packages" in help_out:
        pip_cmd.append("--break-system-packages")
    subprocess.run(pip_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    import pg8000.dbapi

try:
    url = urllib.parse.urlparse(db_url)
    conn = pg8000.dbapi.connect(
        user=url.username, password=url.password, host=url.hostname, port=url.port or 5432, database=url.path[1:], ssl_context=True
    )
    cursor = conn.cursor()
    cursor.execute("CREATE TABLE IF NOT EXISTS deployments (id SERIAL PRIMARY KEY, name VARCHAR(255) UNIQUE NOT NULL, repo_url TEXT NOT NULL, folder_name VARCHAR(255) NOT NULL, env_content TEXT NOT NULL, start_cmd VARCHAR(255) NOT NULL, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)")
    conn.commit()
    
    cursor.execute(
        "INSERT INTO deployments (name, repo_url, folder_name, env_content, start_cmd) VALUES (%s, %s, %s, %s, %s) "
        "ON CONFLICT (name) DO UPDATE SET repo_url = EXCLUDED.repo_url, folder_name = EXCLUDED.folder_name, env_content = EXCLUDED.env_content, start_cmd = EXCLUDED.start_cmd",
        [cfg_name, repo_url, folder_name, env_content, start_cmd]
    )
    conn.commit()
    print("Configuration saved successfully.", file=sys.stderr)
    cursor.close()
    conn.close()
except Exception as e:
    print(f"Error saving configuration: {e}", file=sys.stderr)
EOF
    fi
  fi
fi


