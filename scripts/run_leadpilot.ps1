param(
  [int]$Port = 8000,
  [string]$LocalToken = "",
  [switch]$LaunchFlutter
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$backend = Join-Path $root "backend"
$frontend = Join-Path $root "frontend"
$runtime = Join-Path $backend "data\runtime"
$pidFile = Join-Path $runtime "backend.pid"
$stdout = Join-Path $runtime "backend.stdout.log"
$stderr = Join-Path $runtime "backend.stderr.log"

if (-not (Test-Path -LiteralPath $backend)) { throw "Backend directory not found: $backend" }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw "Python 3.12+ is required." }
if (-not (Test-Path -LiteralPath $runtime)) { New-Item -ItemType Directory -Path $runtime | Out-Null }

if ([string]::IsNullOrWhiteSpace($LocalToken)) {
  $bytes = New-Object byte[] 32
  $random = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $random.GetBytes($bytes) } finally { $random.Dispose() }
  $LocalToken = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}

if (Test-Path -LiteralPath $pidFile) {
  $existingPid = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue
  if ($existingPid -and (Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue)) {
    throw "LeadPilot backend is already running with PID $existingPid. Use scripts\stop_leadpilot.ps1 first."
  }
  Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

$env:LOCAL_TOKEN = $LocalToken
$env:DRY_RUN = "true"
$env:LIVE_SENDING_ENABLED = "false"
$process = Start-Process -FilePath "python" -ArgumentList "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "$Port" -WorkingDirectory $backend -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
$process.Id | Set-Content -LiteralPath $pidFile -Encoding ascii

$ready = $false
for ($attempt = 0; $attempt -lt 40; $attempt++) {
  Start-Sleep -Milliseconds 250
  try {
    $response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health/ready" -UseBasicParsing -TimeoutSec 2
    if ($response.StatusCode -eq 200) { $ready = $true; break }
  } catch { }
}
if (-not $ready) {
  Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
  throw "Backend did not become ready. Inspect $stderr"
}

Write-Host "LeadPilot backend is ready at http://127.0.0.1:$Port (PID $($process.Id))."
Write-Host "Dry-run is enforced and live sending is disabled for this launcher."
Write-Host "Logs: $stdout and $stderr"
if ($LaunchFlutter) {
  if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { throw "Flutter is not installed; backend remains running. Launch Flutter after installing the SDK." }
  Push-Location $frontend
  try {
    $env:LEADPILOT_API_URL = "http://127.0.0.1:$Port"
    $env:LEADPILOT_LOCAL_TOKEN = $LocalToken
    flutter run -d windows
  } finally {
    Pop-Location
  }
}
