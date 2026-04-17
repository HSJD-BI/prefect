$ErrorActionPreference = "Stop"

##############################
# Configuración
##############################
$DEFAULT_POOL = "vm-BIX"
$PREFECT_POOL = Read-Host "Enter Prefect pool name [$DEFAULT_POOL]"
if ([string]::IsNullOrWhiteSpace($PREFECT_POOL)) {
    $PREFECT_POOL = $DEFAULT_POOL
}

$INSTALL_PLAYWRIGHT = "no"
$INSTALL_ODBC = "no"

$PREFECT_API_URL = "http://10.0.1.120:4200/api"

$PREFECT_DIR = "$env:USERPROFILE\prefect"

##############################
# Crear carpeta
##############################
Write-Host "==> Creating Prefect directory..."
New-Item -ItemType Directory -Force -Path $PREFECT_DIR | Out-Null
Set-Location $PREFECT_DIR

##############################
# Verificar Python
##############################
Write-Host "==> Checking Python..."
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Error "Python is required. Install Python 3.10+ and re-run."
    exit 1
}

##############################
# Crear venv
##############################
if (-not (Test-Path ".venv")) {
    Write-Host "==> Creating virtual environment..."
    python -m venv .venv
}

$VENV_PY = "$PREFECT_DIR\.venv\Scripts\python.exe"
$VENV_PIP = "$PREFECT_DIR\.venv\Scripts\pip.exe"

##############################
# Instalar dependencias
##############################
Write-Host "==> Installing dependencies..."
& $VENV_PIP install --upgrade pip

$PREFECT_VER="3.6.25"
$PENDULUM_VER="3.2.0"
$PYDANTIC_VER="2.12.5"

if ($INSTALL_PLAYWRIGHT -eq "yes") {
    & $VENV_PIP install prefect==$PREFECT_VER pendulum==$PENDULUM_VER pydantic==$PYDANTIC_VER playwright
    Write-Host "==> Installing Playwright browsers..."
    & "$PREFECT_DIR\.venv\Scripts\playwright.exe" install
} else {
    & $VENV_PIP install prefect==$PREFECT_VER pendulum==$PENDULUM_VER pydantic==$PYDANTIC_VER
}

##############################
# Crear script runner
##############################
$RUNNER = "$PREFECT_DIR\run-worker.ps1"

@"
`$env:PREFECT_API_URL="$PREFECT_API_URL"
& "$PREFECT_DIR\.venv\Scripts\prefect.exe" worker start --pool "$PREFECT_POOL" --type process
"@ | Out-File -Encoding utf8 $RUNNER

##############################
# Crear servicio Windows
##############################
Write-Host "==> Creating Windows service..."

$SERVICE_NAME = "PrefectWorker-$PREFECT_POOL"

# Necesita NSSM (Non-Sucking Service Manager)
$nssm = "$PREFECT_DIR\nssm.exe"

if (-not (Test-Path $nssm)) {
    Write-Host "==> Downloading NSSM..."
    Invoke-WebRequest "https://nssm.cc/release/nssm-2.24.zip" -OutFile "nssm.zip"
    Expand-Archive nssm.zip -DestinationPath .
    Copy-Item ".\nssm-2.24\win64\nssm.exe" $nssm
}

# Crear servicio
& $nssm install $SERVICE_NAME "powershell.exe" "-ExecutionPolicy Bypass -File `"$RUNNER`""

& $nssm set $SERVICE_NAME Start SERVICE_AUTO_START
& $nssm start $SERVICE_NAME

##############################
# ODBC (opcional)
##############################
if ($INSTALL_ODBC -eq "yes") {
    Write-Host "==> Installing Microsoft ODBC Driver 18..."
    Start-Process msiexec.exe -Wait -ArgumentList "/i https://go.microsoft.com/fwlink/?linkid=2249006 /quiet /norestart"
}

Write-Host "✅ Done!"
Write-Host "Service: $SERVICE_NAME"