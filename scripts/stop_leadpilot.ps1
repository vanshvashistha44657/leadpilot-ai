$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$pidFile = Join-Path $root "backend\data\runtime\backend.pid"
if (-not (Test-Path -LiteralPath $pidFile)) {
  Write-Host "No LeadPilot backend PID file found."
  exit 0
}
$backendPid = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue
if ($backendPid -and (Get-Process -Id ([int]$backendPid) -ErrorAction SilentlyContinue)) {
  Stop-Process -Id ([int]$backendPid) -Force
  Write-Host "Stopped LeadPilot backend PID $backendPid."
} else {
  Write-Host "LeadPilot backend process is not running."
}
Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
