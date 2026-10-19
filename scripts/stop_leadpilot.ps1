param(
  [string]$InstallRoot = "",
  [string]$DataDirectory = "",
  [switch]$StopFrontend
)

$ErrorActionPreference = "Stop"

function Write-LifecycleLog {
  param([string]$Message)

  Write-Host ("[{0}] {1}" -f (Get-Date).ToUniversalTime().ToString("o"), $Message)
}

function ConvertTo-FullPath {
  param([string]$PathValue)

  if ([IO.Path]::IsPathRooted($PathValue)) {
    return [IO.Path]::GetFullPath($PathValue)
  }
  return [IO.Path]::GetFullPath((Join-Path (Get-Location) $PathValue))
}

function Get-ProcessPath {
  param([System.Diagnostics.Process]$Process)

  try {
    return [IO.Path]::GetFullPath($Process.Path)
  } catch {
    return ""
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

function Stop-OwnedFrontend {
  param(
    [string]$ApplicationRoot,
    [string]$DataRoot
  )

  $frontendPath = [IO.Path]::GetFullPath((Join-Path $ApplicationRoot "LeadPilot\leadpilot_frontend.exe"))
  $metadataPath = Join-Path (Join-Path $DataRoot "runtime") "frontend.process.json"
  if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return }

  try {
    Write-LifecycleLog "START owned frontend stop"
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $recordedPath = [IO.Path]::GetFullPath([string]$metadata.executable)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($recordedPath, $frontendPath)) {
      throw "Refusing to stop a frontend whose recorded executable is not this LeadPilot installation."
    }
    $process = Get-Process -Id ([int]$metadata.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process -or $process.HasExited) {
      Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
      return
    }
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals((Get-ProcessPath $process), $recordedPath)) {
      throw "Refusing to stop a frontend whose process path does not match its ownership record."
    }
    $recordedStart = [DateTimeOffset]::Parse([string]$metadata.started_at_utc)
    $actualStart = [DateTimeOffset]$process.StartTime.ToUniversalTime()
    if ([Math]::Abs(($actualStart - $recordedStart).TotalSeconds) -gt 15) {
      throw "Refusing to stop a frontend whose start time does not match its ownership record."
    }
    if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
      $null = $process.CloseMainWindow()
      $null = $process.WaitForExit(5000)
    }
    if (-not $process.HasExited) {
      Stop-Process -Id $process.Id -Force
      $null = $process.WaitForExit(5000)
    }
    if (-not $process.HasExited) {
      throw "LeadPilot frontend PID $($process.Id) did not exit."
    }
    Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
    Write-LifecycleLog "END owned frontend stop"
  } catch {
    throw $_
  }
}

$root = if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
  ConvertTo-FullPath (Join-Path $PSScriptRoot "..")
} else {
  ConvertTo-FullPath $InstallRoot
}
$expectedExecutable = Join-Path $root "runtime\python\python.exe"
if (-not (Test-Path -LiteralPath $expectedExecutable -PathType Leaf)) {
  $command = Get-Command python -ErrorAction SilentlyContinue
  if ($null -ne $command) { $expectedExecutable = [IO.Path]::GetFullPath($command.Source) }
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
$metadataPath = Join-Path $dataRoot "runtime\backend.process.json"
if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
  if ($StopFrontend) { Stop-OwnedFrontend $root $dataRoot }
  Write-LifecycleLog "No LeadPilot backend ownership record found. No backend process was stopped."
  exit 0
}

try {
  $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
  $backendPid = [int]$metadata.pid
} catch {
  throw "The LeadPilot backend ownership record is invalid. No process was stopped: $metadataPath"
}

$process = Get-Process -Id $backendPid -ErrorAction SilentlyContinue
if ($null -eq $process -or $process.HasExited) {
  Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
  if ($StopFrontend) { Stop-OwnedFrontend $root $dataRoot }
  Write-LifecycleLog "LeadPilot backend process is not running."
  exit 0
}

$recordedExecutable = [string]$metadata.executable
if ([string]::IsNullOrWhiteSpace($recordedExecutable)) {
  $recordedExecutable = $expectedExecutable
}
$recordedExecutable = [IO.Path]::GetFullPath($recordedExecutable)
if (-not (Test-KnownLeadPilotInstallation $recordedExecutable)) {
  throw "Refusing to stop PID $backendPid because its recorded LeadPilot installation is not available."
}
$actualExecutable = Get-ProcessPath $process
if ([string]::IsNullOrWhiteSpace($actualExecutable) -or
    -not [StringComparer]::OrdinalIgnoreCase.Equals($actualExecutable, $recordedExecutable)) {
  throw "Refusing to stop PID $backendPid because it is not the LeadPilot Python runtime recorded by this application."
}

try {
  $recordedStart = [DateTimeOffset]::Parse([string]$metadata.started_at_utc)
  $actualStart = [DateTimeOffset]$process.StartTime.ToUniversalTime()
  if ([Math]::Abs(($actualStart - $recordedStart).TotalSeconds) -gt 15) {
    throw "Refusing to stop PID $backendPid because its start time does not match the LeadPilot ownership record."
  }
} catch [System.Management.Automation.RuntimeException] {
  throw
} catch {
  throw "Refusing to stop PID $backendPid because its start time could not be verified."
}

Write-LifecycleLog "START owned backend stop pid=$backendPid"
Stop-Process -Id $backendPid -Force
try { $null = $process.WaitForExit(5000) } catch { }
if (-not $process.HasExited) {
  throw "LeadPilot backend PID $backendPid did not exit after the stop request."
}
Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
if ($StopFrontend) { Stop-OwnedFrontend $root $dataRoot }
Write-LifecycleLog "END owned backend stop pid=$backendPid"
