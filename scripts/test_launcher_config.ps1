param()

$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$launcher = Join-Path $root "scripts\run_leadpilot.ps1"
$dataRoot = Join-Path ([IO.Path]::GetTempPath()) ("LeadPilot-launcher-config-" + [Guid]::NewGuid().ToString("N"))
$configDirectory = Join-Path $dataRoot "config"
$configFile = Join-Path $configDirectory "backend.env"
$oldValues = @{}

foreach ($name in @("GMAIL_CLIENT_ID", "GMAIL_CLIENT_SECRET", "GMAIL_REDIRECT_URI", "DRY_RUN", "LIVE_SENDING_ENABLED", "GMAIL_LIVE_SEND_APPROVED", "GMAIL_LIVE_SEND_TESTED")) {
  $oldValues[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
  [Environment]::SetEnvironmentVariable($name, $null, "Process")
}

try {
  New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
  $configLines = @(
    "GMAIL_CLIENT_ID=desktop-client-id",
    ("GMAIL_CLIENT" + "_SECRET=config-secret-must-not-import"),
    "GMAIL_REDIRECT_URI=http://127.0.0.1:8000/api/gmail/oauth/callback",
    "DRY_RUN=false",
    "LIVE_SENDING_ENABLED=true",
    "GMAIL_LIVE_SEND_APPROVED=true",
    "GMAIL_LIVE_SEND_TESTED=true"
  )
  $configLines | Set-Content -LiteralPath $configFile -Encoding utf8

  $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -InstallRoot $root -DataDirectory $dataRoot -VerifyConfigOnly 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    throw "Launcher config probe failed with exit code $LASTEXITCODE. Output: $raw"
  }
  $result = $raw.Trim() | ConvertFrom-Json
  if (-not $result.gmail_client_id_configured) { throw "GMAIL_CLIENT_ID was not imported from backend.env." }
  if ($result.gmail_client_secret_imported) { throw "GMAIL_CLIENT_SECRET was imported from backend.env." }
  if ($result.gmail_redirect_uri_imported) { throw "GMAIL_REDIRECT_URI was imported from backend.env." }
  if ($result.dry_run -ne "true") { throw "Launcher did not force DRY_RUN=true." }
  if ($result.live_sending_enabled -ne "false") { throw "Launcher did not force LIVE_SENDING_ENABLED=false." }
  if ($result.gmail_live_send_approved -ne "false") { throw "Launcher did not force GMAIL_LIVE_SEND_APPROVED=false." }
  if ($result.gmail_live_send_tested -ne "false") { throw "Launcher did not force GMAIL_LIVE_SEND_TESTED=false." }
  Write-Host "Launcher configuration regression test passed."
} finally {
  foreach ($name in $oldValues.Keys) {
    [Environment]::SetEnvironmentVariable($name, $oldValues[$name], "Process")
  }
  if (Test-Path -LiteralPath $dataRoot) {
    Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
