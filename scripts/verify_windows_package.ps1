param(
  [Parameter(Mandatory = $true)]
  [string]$PackageDirectory,
  [string]$DataDirectory = "",
  [int]$Port = 18000,
  [switch]$KeepData
)

$ErrorActionPreference = "Stop"

function ConvertTo-FullPath {
  param([string]$PathValue)

  if ([IO.Path]::IsPathRooted($PathValue)) {
    return [IO.Path]::GetFullPath($PathValue)
  }
  return [IO.Path]::GetFullPath((Join-Path (Get-Location) $PathValue))
}

$package = ConvertTo-FullPath $PackageDirectory
if (-not (Test-Path -LiteralPath $package -PathType Container)) {
  throw "Package directory was not found: $package"
}

$requiredFiles = @(
  (Join-Path $package "LeadPilot\leadpilot_frontend.exe"),
  (Join-Path $package "backend\app\main.py"),
  (Join-Path $package "runtime\python\python.exe"),
  (Join-Path $package "scripts\run_leadpilot.ps1"),
  (Join-Path $package "scripts\stop_leadpilot.ps1"),
  (Join-Path $package "config\backend.env.example")
)
foreach ($requiredFile in $requiredFiles) {
  if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
    throw "Package verification failed; required file was not found: $requiredFile"
  }
}

if ([string]::IsNullOrWhiteSpace($DataDirectory)) {
  $DataDirectory = Join-Path ([IO.Path]::GetTempPath()) ("LeadPilot-package-verification-" + [Guid]::NewGuid().ToString("N"))
}
$dataRoot = ConvertTo-FullPath $DataDirectory
$launcher = Join-Path $package "scripts\run_leadpilot.ps1"
$metadata = Join-Path $dataRoot "runtime\backend.process.json"
$database = Join-Path $dataRoot "data\leadpilot.db"
$config = Join-Path $dataRoot "config\backend.env"
$powerShell = (Get-Command powershell.exe -ErrorAction Stop).Source

try {
  & $powerShell -NoProfile -ExecutionPolicy Bypass -File $launcher -InstallRoot $package -DataDirectory $dataRoot -Port $Port -VerifyOnly
  if ($LASTEXITCODE -ne 0) {
    throw "Packaged launcher verification failed with exit code $LASTEXITCODE."
  }

  if (-not (Test-Path -LiteralPath $database -PathType Leaf)) {
    throw "The packaged backend did not create its persistent SQLite database: $database"
  }
  if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
    throw "The packaged launcher did not create its persistent user configuration: $config"
  }
  $configText = Get-Content -LiteralPath $config -Raw
  if ($configText -notmatch '(?m)^GMAIL_CLIENT_ID\s*=') {
    throw "The packaged launcher configuration does not permit GMAIL_CLIENT_ID."
  }
  if ($configText -match '(?m)^GMAIL_CLIENT_SECRET\s*=') {
    throw "The packaged launcher configuration must not persist GMAIL_CLIENT_SECRET."
  }
  if ($configText -match '(?m)^GMAIL_REDIRECT_URI\s*=') {
    throw "The packaged launcher configuration must not persist GMAIL_REDIRECT_URI."
  }
  if (Test-Path -LiteralPath $metadata) {
    throw "The packaged launcher left backend ownership metadata after verification: $metadata"
  }
  if (Test-Path -LiteralPath (Join-Path $package "data")) {
    throw "The package contains a replaceable-installation data directory."
  }

  Write-Host "Windows package verification passed: runtime, dependencies, readiness, authentication, persistence, and shutdown."
} finally {
  if (-not $KeepData -and (Test-Path -LiteralPath $dataRoot)) {
    Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue
  } elseif ($KeepData) {
    Write-Host "Verification data retained at $dataRoot"
  }
}
