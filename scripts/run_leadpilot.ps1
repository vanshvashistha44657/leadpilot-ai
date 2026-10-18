param(
  [string]$InstallRoot = "",
  [string]$DataDirectory = "",
  [int]$Port = 8000,
  [string]$LocalToken = "",
  [switch]$LaunchFrontend,
  [switch]$LaunchFlutter,
  [switch]$VerifyOnly,
  [switch]$KeepBackend
)

$ErrorActionPreference = "Stop"

function ConvertTo-FullPath {
  param([string]$PathValue)

  if ([IO.Path]::IsPathRooted($PathValue)) {
    return [IO.Path]::GetFullPath($PathValue)
  }
  return [IO.Path]::GetFullPath((Join-Path (Get-Location) $PathValue))
}

function Ensure-Directory {
  param([string]$PathValue)

  if (-not (Test-Path -LiteralPath $PathValue -PathType Container)) {
    New-Item -ItemType Directory -Path $PathValue -Force | Out-Null
  }
}

function New-LocalToken {
  $bytes = New-Object byte[] 32
  $random = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $random.GetBytes($bytes)
  } finally {
    $random.Dispose()
  }
  return [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}

function Write-DefaultConfig {
  param([string]$PathValue)

  @'
# LeadPilot per-user configuration. Provider credentials remain environment-only
# and are never persisted by the installed launcher.
EMAIL_PROVIDER=mock
LOG_LEVEL=INFO
IMPORT_BATCH_SIZE=100
AI_PROVIDER=none
AI_MODEL=
AI_BASE_URL=https://api.openai.com/v1
AI_TIMEOUT_SECONDS=20
AI_MAX_RETRIES=2
AI_RETRY_BACKOFF_SECONDS=0.25
GMAIL_REDIRECT_URI=http://127.0.0.1:8000/api/gmail/oauth/callback
GMAIL_SCOPES=https://www.googleapis.com/auth/gmail.modify
GMAIL_TIMEOUT_SECONDS=20
GMAIL_MAX_RETRIES=2
GMAIL_RETRY_BACKOFF_SECONDS=0.25
'@ | Set-Content -LiteralPath $PathValue -Encoding utf8
}

function Import-UserConfig {
  param([string]$PathValue)

  $allowedNames = @(
    "EMAIL_PROVIDER", "LOG_LEVEL", "IMPORT_BATCH_SIZE",
    "AI_PROVIDER", "AI_MODEL", "AI_BASE_URL",
    "AI_TIMEOUT_SECONDS", "AI_MAX_RETRIES", "AI_RETRY_BACKOFF_SECONDS",
    "GMAIL_REDIRECT_URI", "GMAIL_SCOPES",
    "GMAIL_TIMEOUT_SECONDS", "GMAIL_MAX_RETRIES", "GMAIL_RETRY_BACKOFF_SECONDS",
    "GMAIL_LIVE_SEND_APPROVED", "GMAIL_LIVE_SEND_TESTED"
  )
  foreach ($line in (Get-Content -LiteralPath $PathValue)) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
      $name = $matches[1]
      if ($allowedNames -notcontains $name) { continue }
      $value = $matches[2]
      if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
        $value = $value.Substring(1, $value.Length - 2)
      }
      Set-Item -Path ("Env:{0}" -f $name) -Value $value
    }
  }
}

function Get-ProcessPath {
  param([System.Diagnostics.Process]$Process)

  try {
    return [IO.Path]::GetFullPath($Process.Path)
  } catch {
    return ""
  }
}

function Test-TrackedProcess {
  param(
    [System.Diagnostics.Process]$Process,
    [object]$Metadata,
    [string]$ExpectedExecutable
  )

  if ($null -eq $Process -or $Process.HasExited) { return $false }
  $actualPath = Get-ProcessPath $Process
  if ([string]::IsNullOrWhiteSpace($actualPath) -or
      -not [StringComparer]::OrdinalIgnoreCase.Equals($actualPath, $ExpectedExecutable)) {
    return $false
  }
  try {
    $recorded = [DateTimeOffset]::Parse([string]$Metadata.started_at_utc)
    $actual = [DateTimeOffset]$Process.StartTime.ToUniversalTime()
    return ([Math]::Abs(($actual - $recorded).TotalSeconds) -le 15)
  } catch {
    return $false
  }
}

function Test-KnownLeadPilotInstallation {
  param([string]$ExecutablePath)

  try {
    $pythonDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($ExecutablePath))
    $runtimeDirectory = Split-Path -Parent $pythonDirectory
    $applicationRoot = Split-Path -Parent $runtimeDirectory
    return (Test-Path -LiteralPath (Join-Path $applicationRoot "backend\app\main.py") -PathType Leaf) -and
      (Test-Path -LiteralPath (Join-Path $applicationRoot "LeadPilot\leadpilot_frontend.exe") -PathType Leaf)
  } catch {
    return $false
  }
}

function Stop-TrackedProcess {
  param(
    [System.Diagnostics.Process]$Process,
    [string]$MetadataPath,
    [string]$ExpectedExecutable,
    [object]$Metadata
  )

  if ($null -ne $Process -and -not $Process.HasExited) {
    if (-not (Test-TrackedProcess $Process $Metadata $ExpectedExecutable)) {
      throw "Refusing to stop a process that is not the LeadPilot backend started by this launcher."
    }
    Stop-Process -Id $Process.Id -Force
    try { $null = $Process.WaitForExit(5000) } catch { }
  }
  if (Test-Path -LiteralPath $MetadataPath) {
    Remove-Item -LiteralPath $MetadataPath -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-ApiCheck {
  param(
    [string]$Uri,
    [hashtable]$Headers = @{}
  )

  return Invoke-WebRequest -Uri $Uri -Headers $Headers -UseBasicParsing -TimeoutSec 3
}

if ($LaunchFlutter -and $LaunchFrontend) {
  throw "Choose either -LaunchFlutter for development or -LaunchFrontend for a packaged release."
}
if ($VerifyOnly -and ($LaunchFlutter -or $LaunchFrontend)) {
  throw "-VerifyOnly cannot be combined with a frontend launch option."
}

$root = if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
  ConvertTo-FullPath (Join-Path $PSScriptRoot "..")
} else {
  ConvertTo-FullPath $InstallRoot
}
$backend = Join-Path $root "backend"
$frontendExecutable = Join-Path $root "LeadPilot\leadpilot_frontend.exe"
$packagedPython = Join-Path $root "runtime\python\python.exe"
$sourceFrontend = Join-Path $root "frontend"

if (-not (Test-Path -LiteralPath $backend -PathType Container)) {
  throw "Backend directory not found: $backend"
}

if (Test-Path -LiteralPath $packagedPython -PathType Leaf) {
  $pythonPath = [IO.Path]::GetFullPath($packagedPython)
} else {
  $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
  if ($null -eq $pythonCommand) {
    throw "No bundled Python runtime was found and Python is not available on PATH."
  }
  $pythonPath = [IO.Path]::GetFullPath($pythonCommand.Source)
}

if ($LaunchFrontend -and -not (Test-Path -LiteralPath $frontendExecutable -PathType Leaf)) {
  throw "Packaged Flutter frontend was not found: $frontendExecutable"
}

if ([string]::IsNullOrWhiteSpace($DataDirectory)) {
  if (-not [string]::IsNullOrWhiteSpace($env:LEADPILOT_DATA_DIRECTORY)) {
    $DataDirectory = $env:LEADPILOT_DATA_DIRECTORY
  } else {
    $localAppData = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $env:TEMP } else { $env:LOCALAPPDATA }
    $DataDirectory = Join-Path $localAppData "LeadPilot"
  }
}
$dataRoot = ConvertTo-FullPath $DataDirectory
$configDirectory = Join-Path $dataRoot "config"
$dataPath = Join-Path $dataRoot "data"
$backupDirectory = Join-Path $dataRoot "backups"
$logsDirectory = Join-Path $dataRoot "logs"
$runtimeDirectory = Join-Path $dataRoot "runtime"
$configFile = Join-Path $configDirectory "backend.env"
$metadataPath = Join-Path $runtimeDirectory "backend.process.json"
$stdout = Join-Path $logsDirectory "backend.stdout.log"
$stderr = Join-Path $logsDirectory "backend.stderr.log"
$databasePath = Join-Path $dataPath "leadpilot.db"

foreach ($directory in @($configDirectory, $dataPath, $backupDirectory, $logsDirectory, $runtimeDirectory)) {
  Ensure-Directory $directory
}
if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
  Write-DefaultConfig $configFile
}
Import-UserConfig $configFile

# These are intentionally enforced for the desktop launcher. A future live-send
# release must use a separate, explicit deployment policy and operator approval.
$env:LOCAL_ONLY_API = "true"
$env:DATABASE_PATH = $databasePath
$env:BACKUP_DIRECTORY = $backupDirectory
$env:DRY_RUN = "true"
$env:LIVE_SENDING_ENABLED = "false"
$env:GMAIL_LIVE_SEND_APPROVED = "false"
$env:GMAIL_LIVE_SEND_TESTED = "false"

if ([string]::IsNullOrWhiteSpace($LocalToken)) {
  $LocalToken = New-LocalToken
}
$env:LOCAL_TOKEN = $LocalToken

$expectedExecutable = [IO.Path]::GetFullPath($pythonPath)
if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
  $oldMetadata = $null
  try {
    $oldMetadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
  } catch {
    # A malformed or stale ownership record is safe to replace; no process is
    # stopped unless its identity matches the recorded executable and start time.
  }
  if ($null -ne $oldMetadata) {
    $oldProcess = Get-Process -Id ([int]$oldMetadata.pid) -ErrorAction SilentlyContinue
    $oldExecutable = [string]$oldMetadata.executable
    if ([string]::IsNullOrWhiteSpace($oldExecutable)) { $oldExecutable = $expectedExecutable }
    $oldExecutable = [IO.Path]::GetFullPath($oldExecutable)
    if ($null -ne $oldProcess -and -not $oldProcess.HasExited) {
      if ((Test-KnownLeadPilotInstallation $oldExecutable) -and
          (Test-TrackedProcess $oldProcess $oldMetadata $oldExecutable)) {
        throw "LeadPilot backend is already running with PID $($oldMetadata.pid)."
      }
      throw "Refusing to replace an active process with an unverified LeadPilot ownership record."
    }
  }
  Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
}

$backendProcess = $null
$backendStarted = $false
$stopWhenDone = ($LaunchFrontend -or $LaunchFlutter -or $VerifyOnly) -and -not $KeepBackend
try {
  $arguments = @(
    "-m", "uvicorn", "app.main:app",
    "--host", "127.0.0.1",
    "--port", $Port.ToString([Globalization.CultureInfo]::InvariantCulture)
  )
  $backendProcess = Start-Process -FilePath $pythonPath -ArgumentList $arguments -WorkingDirectory $backend -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
  $backendStarted = $true
  $metadata = [ordered]@{
    pid = $backendProcess.Id
    executable = $expectedExecutable
    started_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  }
  $metadata | ConvertTo-Json | Set-Content -LiteralPath $metadataPath -Encoding ascii

  $ready = $false
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    $backendProcess.Refresh()
    if ($backendProcess.HasExited) {
      throw "Backend exited before it became ready. Inspect $stderr"
    }
    try {
      $response = Invoke-ApiCheck "http://127.0.0.1:$Port/health/ready"
      if ($response.StatusCode -eq 200) { $ready = $true; break }
    } catch { }
    Start-Sleep -Milliseconds 250
  }
  if (-not $ready) {
    throw "Backend did not become ready within 10 seconds. Inspect $stderr"
  }

  try {
    $authenticated = Invoke-ApiCheck "http://127.0.0.1:$Port/api/settings" @{ "X-Local-Token" = $LocalToken }
  } catch {
    throw "Backend readiness succeeded, but authenticated API verification failed. Inspect $stderr"
  }
  if ($authenticated.StatusCode -ne 200) {
    throw "The backend rejected the generated local authentication token. Inspect $stderr"
  }
  $publicSettings = $authenticated.Content | ConvertFrom-Json
  if (-not $publicSettings.dry_run -or $publicSettings.live_sending_enabled) {
    throw "The desktop launcher safety defaults were not enforced by the backend. Inspect $stderr"
  }

  if ($VerifyOnly) {
    Write-Host "LeadPilot package backend and local authentication verified."
    return
  }

  if ($LaunchFrontend) {
    $env:LEADPILOT_API_URL = "http://127.0.0.1:$Port"
    $env:LEADPILOT_LOCAL_TOKEN = $LocalToken
    $frontendProcess = Start-Process -FilePath $frontendExecutable -WorkingDirectory (Split-Path -Parent $frontendExecutable) -PassThru
    $null = $frontendProcess.WaitForExit()
    if ($frontendProcess.ExitCode -ne 0) {
      throw "LeadPilot frontend exited with code $($frontendProcess.ExitCode)."
    }
  } elseif ($LaunchFlutter) {
    if ($null -eq (Get-Command flutter -ErrorAction SilentlyContinue)) {
      throw "Flutter is not installed; use -LaunchFrontend with a packaged release or install the Flutter SDK."
    }
    $env:LEADPILOT_API_URL = "http://127.0.0.1:$Port"
    $env:LEADPILOT_LOCAL_TOKEN = $LocalToken
    Push-Location $sourceFrontend
    try {
      flutter run -d windows
      if ($LASTEXITCODE -ne 0) { throw "Flutter exited with code $LASTEXITCODE." }
    } finally {
      Pop-Location
    }
  } else {
    Write-Host "LeadPilot backend is ready at http://127.0.0.1:$Port (PID $($backendProcess.Id))."
    Write-Host "Dry-run is enforced and live sending is disabled for this launcher."
    Write-Host "Logs: $stdout and $stderr"
  }
} finally {
  if ($stopWhenDone -and $backendStarted) {
    Stop-TrackedProcess $backendProcess $metadataPath $expectedExecutable $metadata
  }
}
