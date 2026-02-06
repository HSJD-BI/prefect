
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# --- Ask for Prefect pool name ---
DEFAULT_POOL="vm-BIX"

read -r -p "Enter Prefect pool name [${DEFAULT_POOL}]: " PREFECT_POOL
PREFECT_POOL="${PREFECT_POOL:-$DEFAULT_POOL}"

# Basic validation (systemd + Prefect pool names: keep it simple)
if [[ -z "$PREFECT_POOL" ]]; then
  echo "❌ Pool name cannot be empty."
  exit 1
fi
``

##############################
# Configurable parameters
##############################
TARGET_USER="${TARGET_USER:-ububi}"
HOME_DIR="${HOME_DIR:-/home/$TARGET_USER}"
PREFECT_DIR="${PREFECT_DIR:-$HOME_DIR/prefect}"
PREFECT_API_URL="${PREFECT_API_URL:-http://10.0.1.120:4200/api}"

# Microsoft ODBC package versions to fetch (adjust if needed)
MSODBC_VERSION="${MSODBC_VERSION:-18.3.1.1-1}"
MSSQLTOOLS_VERSION="${MSSQLTOOLS_VERSION:-18.4.1.1-1}"

# Microsoft repo codename path (the original commands used 'focal' explicitly)
MS_REPO_CODENAME="${MS_REPO_CODENAME:-focal}"

##############################
# Safety checks
##############################
CURRENT_USER="$(id -un)"
if [[ "$CURRENT_USER" != "$TARGET_USER" ]]; then
  echo "Please run this script as the target user '$TARGET_USER'."
  echo "Tip: log in as $TARGET_USER or run: sudo -u $TARGET_USER -H bash $0"
  exit 1
fi

if [[ ! -d "$HOME_DIR" ]]; then
  echo "Home directory $HOME_DIR does not exist."
  exit 1
fi

trap 'echo "❌ Script failed at line $LINENO. Check the log above for details."' ERR

echo "==> Installing base packages…"
sudo apt-get update -y
# Try Python 3.13 headers first; fallback to generic python3-dev if not available
if ! sudo apt-get install -y build-essential curl python3.13-dev; then
  echo "python3.13-dev not available, falling back to python3-dev…"
  sudo apt-get install -y build-essential curl python3-dev
fi

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

# Install Prefect + Playwright (keeping your original inclusion of 'uv' shim)
uv pip install prefect uv playwright

echo "==> Installing Playwright browsers and system deps (may prompt for sudo)…"
playwright install --with-deps

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
echo "==> Removing existing ODBC drivers and tools (if present)…"
sudo apt-get remove --purge -y msodbcsql17 msodbcsql18 mssql-tools* unixodbc unixodbc-dev odbcinst || true
sudo apt-get autoremove -y || true
sudo apt-get clean || true

echo "==> Forcing removal of stuck ODBC packages (if any)…"
sudo dpkg --remove --force-remove-reinstreq msodbcsql17 msodbcsql18 mssql-tools18 || true

echo "==> Cleaning Microsoft repo keys and lists (if present)…"
sudo rm -f /etc/apt/sources.list.d/mssql-release.list
sudo rm -f /usr/share/keyrings/microsoft-prod.gpg /etc/apt/trusted.gpg.d/microsoft.asc

arch="$(dpkg --print-architecture)"
echo "==> Downloading Microsoft ODBC 18 and tools .deb packages for arch: ${arch}…"
cd "$PREFECT_DIR"
# Using the explicit FOCAL path as in your original commands; adjust MS_REPO_CODENAME if needed
curl -fLO "https://packages.microsoft.com/repos/microsoft-ubuntu-${MS_REPO_CODENAME}-prod/pool/main/m/msodbcsql18/msodbcsql18_${MSODBC_VERSION}_${arch}.deb"
curl -fLO "https://packages.microsoft.com/repos/microsoft-ubuntu-${MS_REPO_CODENAME}-prod/pool/main/m/mssql-tools18/mssql-tools18_${MSSQLTOOLS_VERSION}_${arch}.deb"

echo "==> Installing unixodbc-dev and pre-accepting EULA for msodbcsql18…"
sudo apt-get update -y
sudo apt-get install -y unixodbc-dev
sudo sh -c "echo msodbcsql18 msodbcsql18/accept_eula select true | debconf-set-selections"

echo "==> Installing downloaded .deb packages…"
set +e
sudo dpkg -i msodbcsql18_*.deb mssql-tools18_*.deb
dpkg_status=$?
set -e
if [[ $dpkg_status -ne 0 ]]; then
  echo "Fixing missing dependencies…"
  sudo apt-get -f install -y
fi

echo "✅ All done!
- Prefect worker service: systemctl --user status prefect-worker
- Logs: journalctl --user -u prefect-worker -f
- Prefect dir: ${PREFECT_DIR}
- ODBC 18 installed: verify with 'odbcinst -q -d' (optional)
"
 