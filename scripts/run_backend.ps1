param(
  [int]$Port = 8000,
  [string]$LocalToken = "local-development-token"
)

$ErrorActionPreference = "Stop"
$backend = Join-Path $PSScriptRoot "..\backend"
if (-not (Test-Path -LiteralPath $backend)) {
  throw "Backend directory not found: $backend"
}

$env:LOCAL_TOKEN = $LocalToken
$env:DRY_RUN = "true"
$env:LIVE_SENDING_ENABLED = "false"
Push-Location $backend
try {
  python -m uvicorn app.main:app --host 127.0.0.1 --port $Port
} finally {
  Pop-Location
}
