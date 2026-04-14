#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ask_yes_no() {
  local var_name="$1"
  local prompt="$2"
  local default_value="$3"
  local current_value="${!var_name:-}"
  local answer
  local suffix

  if [[ -n "$current_value" ]]; then
    case "${current_value,,}" in
      y|yes|true|1)
        printf -v "$var_name" "yes"
        return
        ;;
      n|no|false|0)
        printf -v "$var_name" "no"
        return
        ;;
      *)
        echo "Invalid value for ${var_name}: ${current_value}. Use yes/no, true/false, or 1/0."
        exit 1
        ;;
    esac
  fi

  case "${default_value,,}" in
    y|yes)
      suffix="[Y/n]"
      default_value="yes"
      ;;
    n|no)
      suffix="[y/N]"
      default_value="no"
      ;;
    *)
      echo "Invalid default for ${var_name}: ${default_value}."
      exit 1
      ;;
  esac

  if [[ -t 0 ]]; then
    while true; do
      read -r -p "${prompt} ${suffix}: " answer
      answer="${answer:-$default_value}"
      case "${answer,,}" in
        y|yes)
          printf -v "$var_name" "yes"
          return
          ;;
        n|no)
          printf -v "$var_name" "no"
          return
          ;;
        *)
          echo "Please answer yes or no."
          ;;
      esac
    done
  fi

  printf -v "$var_name" "%s" "$default_value"
}

# --- Ask for Prefect pool name ---
DEFAULT_POOL="vm-BIX"

if [[ -t 0 ]]; then
  read -r -p "Enter Prefect pool name [${DEFAULT_POOL}]: " PREFECT_POOL
else
  PREFECT_POOL="${PREFECT_POOL:-$DEFAULT_POOL}"
fi
PREFECT_POOL="${PREFECT_POOL:-$DEFAULT_POOL}"

# Basic validation (systemd + Prefect pool names: keep it simple)
if [[ -z "$PREFECT_POOL" ]]; then
  echo "❌ Pool name cannot be empty."
  exit 1
fi

ask_yes_no INSTALL_PLAYWRIGHT "Install Playwright Python package, browsers, and system dependencies?" "yes"
ask_yes_no INSTALL_ODBC "Install Microsoft ODBC 18 drivers and tools?" "yes"

##############################
# Configurable parameters
##############################
TARGET_USER="${TARGET_USER:-$(id -un)}"
HOME_DIR="${HOME_DIR:-$(getent passwd "$TARGET_USER" | cut -d: -f6)}"
PREFECT_DIR="${PREFECT_DIR:-$HOME_DIR/prefect}"
PREFECT_API_URL="${PREFECT_API_URL:-http://10.0.1.120:4200/api}"

##############################
# Safety checks
##############################
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
else
  echo "This script expects Ubuntu and could not read /etc/os-release."
  exit 1
fi

if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "This script is intended for Ubuntu. Detected: ${PRETTY_NAME:-unknown OS}."
  exit 1
fi

CURRENT_USER="$(id -un)"
if [[ "$EUID" -eq 0 && "${TARGET_USER}" == "root" ]]; then
  echo "Do not run this script with sudo/root directly."
  echo "Run it as the Ubuntu VM user instead, for example: bash $0"
  exit 1
fi

if [[ "$CURRENT_USER" != "$TARGET_USER" ]]; then
  echo "Please run this script as the target user '$TARGET_USER'."
  echo "Tip: log in as $TARGET_USER or run: sudo -u $TARGET_USER -H bash $0"
  exit 1
fi

if [[ -z "$HOME_DIR" || ! -d "$HOME_DIR" ]]; then
  echo "Home directory for $TARGET_USER does not exist."
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required. Install sudo or run from an Ubuntu user with sudo access."
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemd is required for the Prefect worker service, but systemctl was not found."
  exit 1
fi

trap 'echo "❌ Script failed at line $LINENO. Check the log above for details."' ERR

echo "==> Installing base packages…"
sudo apt-get update
sudo apt-get install -y build-essential ca-certificates curl gpg python3-dev

echo "==> Installing uv (Astral)…"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# Ensure ~/.local/bin is in PATH for this session and future logins
if ! grep -qs '\.local/bin' "$HOME_DIR/.profile" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME_DIR/.profile"
fi
export PATH="$HOME_DIR/.local/bin:$PATH"

echo "==> Setting up Prefect project and virtual environment…"
mkdir -p "$PREFECT_DIR"
cd "$PREFECT_DIR"

# Create venv with uv and activate
uv venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate

PREFECT_VER="3.6.16"
PENDULUM_VER="3.2.0"
PYDANTIC_VER="2.12.5"

if [[ "$INSTALL_PLAYWRIGHT" == "yes" ]]; then
  uv pip install prefect==$PREFECT_VER pendulum==$PENDULUM_VER pydantic==$PYDANTIC_VER uv playwright

  echo "==> Installing Playwright browsers and system deps (may prompt for sudo)…"
  playwright install --with-deps
else
  uv pip install prefect==$PREFECT_VER pendulum==$PENDULUM_VER pydantic==$PYDANTIC_VER uv
  echo "==> Skipping Playwright install."
fi

echo "==> Creating user systemd service for Prefect worker…"
mkdir -p "$HOME_DIR/.config/systemd/user"
SERVICE_PATH="$HOME_DIR/.config/systemd/user/prefect-worker.service"

cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Prefect worker for ${PREFECT_POOL}
After=network.target graphical.target
Wants=graphical.target

[Service]
Type=simple
WorkingDirectory=${PREFECT_DIR}
Environment="PREFECT_API_URL=${PREFECT_API_URL}"
ExecStart=${PREFECT_DIR}/.venv/bin/uv run prefect worker start --pool "${PREFECT_POOL}" --type process
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

# Ensure user services survive reboots without an active login session
echo "==> Enabling linger for user '${TARGET_USER}' (so user services can start at boot)…"
loginctl enable-linger "$TARGET_USER" || true

echo "==> Reloading and enabling the Prefect worker service…"
systemctl --user daemon-reload
systemctl --user enable --now prefect-worker

#############################################
# ODBC driver cleanup and re-install (18.x)
#############################################
if [[ "$INSTALL_ODBC" == "yes" ]]; then
  echo "==> Removing existing ODBC drivers and tools (if present)…"
  sudo apt-get remove --purge -y msodbcsql17 msodbcsql18 mssql-tools* unixodbc unixodbc-dev odbcinst || true
  sudo apt-get autoremove -y || true
  sudo apt-get clean || true

  echo "==> Forcing removal of stuck ODBC packages (if any)…"
  sudo dpkg --remove --force-remove-reinstreq msodbcsql17 msodbcsql18 mssql-tools18 || true

  echo "==> Cleaning Microsoft repo keys and lists (if present)…"
  sudo rm -f /etc/apt/sources.list.d/mssql-release.list
  sudo rm -f /usr/share/keyrings/microsoft-prod.gpg /etc/apt/trusted.gpg.d/microsoft.asc

  echo "==> Installing Microsoft package repository for Ubuntu ${VERSION_ID}…"
  repo_deb="packages-microsoft-prod.deb"
  cd "$PREFECT_DIR"
  curl -fsSLo "$repo_deb" "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb"
  sudo dpkg -i "$repo_deb"
  rm -f "$repo_deb"

  echo "==> Installing Microsoft ODBC 18, tools, and unixODBC headers…"
  sudo apt-get update
  sudo ACCEPT_EULA=Y apt-get install -y msodbcsql18 mssql-tools18 unixodbc-dev

  if ! grep -qs '/opt/mssql-tools18/bin' "$HOME_DIR/.profile" 2>/dev/null; then
    echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' >> "$HOME_DIR/.profile"
  fi
else
  echo "==> Skipping Microsoft ODBC install."
fi

echo "✅ All done!
- Prefect worker service: systemctl --user status prefect-worker
- Logs: journalctl --user -u prefect-worker -f
- Prefect dir: ${PREFECT_DIR}
- Playwright install: ${INSTALL_PLAYWRIGHT}
- ODBC 18 install: ${INSTALL_ODBC}
"
