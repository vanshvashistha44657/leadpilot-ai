param(
  [string]$OutputDirectory = "",
  [string]$PythonExecutable = "python"
)

$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$frontend = Join-Path $root "frontend"
$backend = Join-Path $root "backend"
$prepareRuntime = Join-Path $PSScriptRoot "prepare_python_runtime.ps1"
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path $root "dist\leadpilot-windows"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$localAppData = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $env:TEMP } else { $env:LOCALAPPDATA }
$persistentData = [IO.Path]::GetFullPath((Join-Path $localAppData "LeadPilot"))
$outputPrefix = $OutputDirectory.TrimEnd('\') + '\'
$dataPrefix = $persistentData.TrimEnd('\') + '\'

if ([StringComparer]::OrdinalIgnoreCase.Equals($OutputDirectory, $root) -or
    [StringComparer]::OrdinalIgnoreCase.Equals($OutputDirectory, [IO.Path]::GetPathRoot($OutputDirectory)) -or
    [StringComparer]::OrdinalIgnoreCase.Equals($OutputDirectory, $persistentData) -or
    $OutputDirectory.StartsWith($dataPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    $persistentData.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Refusing to delete an unsafe package output directory: $OutputDirectory"
}

$release = Join-Path $frontend "build\windows\x64\runner\Release"
if (-not (Test-Path -LiteralPath $release -PathType Container)) {
  throw "Flutter Windows release output was not found at $release. Run scripts\build_windows.ps1 after Visual Studio is installed."
}
if (-not (Test-Path -LiteralPath $prepareRuntime -PathType Leaf)) {
  throw "Python runtime preparation script was not found: $prepareRuntime"
}

if (Test-Path -LiteralPath $OutputDirectory) {
  Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $OutputDirectory "backend") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $OutputDirectory "config") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $OutputDirectory "scripts") -Force | Out-Null

Copy-Item -LiteralPath $release -Destination (Join-Path $OutputDirectory "LeadPilot") -Recurse -Force
Copy-Item -LiteralPath (Join-Path $frontend "windows\runner\resources\app_icon.ico") -Destination (Join-Path $OutputDirectory "app_icon.ico") -Force
Copy-Item -LiteralPath (Join-Path $backend "app") -Destination (Join-Path $OutputDirectory "backend") -Recurse -Force
Copy-Item -LiteralPath (Join-Path $backend "pyproject.toml") -Destination (Join-Path $OutputDirectory "backend") -Force
Copy-Item -LiteralPath (Join-Path $backend "requirements-runtime.txt") -Destination (Join-Path $OutputDirectory "backend") -Force
Copy-Item -LiteralPath (Join-Path $backend ".env.example") -Destination (Join-Path $OutputDirectory "config\backend.env.example") -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "run_leadpilot.ps1") -Destination (Join-Path $OutputDirectory "scripts") -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "stop_leadpilot.ps1") -Destination (Join-Path $OutputDirectory "scripts") -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "verify_windows_package.ps1") -Destination (Join-Path $OutputDirectory "scripts") -Force

$runtimeOutput = Join-Path $OutputDirectory "runtime\python"
& $prepareRuntime -PythonExecutable $PythonExecutable -OutputDirectory $runtimeOutput -BackendDirectory $backend -RequirementsFile (Join-Path $backend "requirements-runtime.txt")
if ($LASTEXITCODE -ne 0) {
  throw "Private Python runtime preparation failed with exit code $LASTEXITCODE."
}

$runtimePython = Join-Path $runtimeOutput "python.exe"
$requiredFiles = @(
  (Join-Path $OutputDirectory "LeadPilot\leadpilot_frontend.exe"),
  (Join-Path $OutputDirectory "app_icon.ico"),
  (Join-Path $OutputDirectory "backend\app\main.py"),
  (Join-Path $OutputDirectory "runtime\python\python.exe"),
  (Join-Path $OutputDirectory "scripts\run_leadpilot.ps1"),
  (Join-Path $OutputDirectory "scripts\stop_leadpilot.ps1"),
  (Join-Path $OutputDirectory "scripts\verify_windows_package.ps1")
)
foreach ($requiredFile in $requiredFiles) {
  if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
    throw "Package staging is incomplete; required file was not found: $requiredFile"
  }
}

@"
LeadPilot Windows staging layout
===============================

LeadPilot\                 Flutter Windows release output
backend\app\              FastAPI backend source and migrations
runtime\python\           Private Python 3.12 runtime and backend dependencies
scripts\                   Installed launcher and process-safe shutdown helper
config\                    Non-secret configuration template only

Persistent user data is not stored here. The launcher uses
%LOCALAPPDATA%\LeadPilot by default for:
  config\backend.env       user-editable configuration
  data\leadpilot.db        SQLite database
  backups\                  database backups
  logs\                     backend stdout/stderr
  runtime\backend.process.json  process ownership metadata

The launcher forces DRY_RUN=true, LIVE_SENDING_ENABLED=false, and local-only
binding. It generates the local API token in memory and never writes or logs it.
This directory is the input to the Phase 2 Inno Setup installer. Compile it
with scripts\build_windows_installer.ps1 after the staging checks pass.
"@ | Set-Content -LiteralPath (Join-Path $OutputDirectory "INSTALL_LAYOUT.txt") -Encoding utf8

& $runtimePython -c "import fastapi, uvicorn, multipart; print('staged backend dependencies ok')"
if ($LASTEXITCODE -ne 0) {
  throw "The staged Python runtime failed its dependency import check."
}

Write-Host "Prepared LeadPilot Windows package staging directory: $OutputDirectory"
Write-Host "Frontend release: $(Join-Path $OutputDirectory 'LeadPilot')"
Write-Host "Private Python runtime: $(Join-Path $OutputDirectory 'runtime\python')"
Write-Host "Backend source: $(Join-Path $OutputDirectory 'backend')"
Write-Host "User data is kept outside the package under %LOCALAPPDATA%\LeadPilot."
