param(
  [string]$PythonExecutable = "python",
  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory,
  [string]$BackendDirectory = "",
  [string]$RequirementsFile = ""
)

$ErrorActionPreference = "Stop"

function Resolve-PythonExecutable {
  param([string]$Value)

  if (Test-Path -LiteralPath $Value -PathType Leaf) {
    return [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Value).Path)
  }

  $command = Get-Command $Value -ErrorAction SilentlyContinue
  if ($null -eq $command) {
    throw "Python executable '$Value' was not found. Install Python 3.12 on the build machine or pass its full path."
  }
  return [IO.Path]::GetFullPath($command.Source)
}

function Get-FullPath {
  param([string]$Value)

  if ([IO.Path]::IsPathRooted($Value)) {
    return [IO.Path]::GetFullPath($Value)
  }
  return [IO.Path]::GetFullPath((Join-Path (Get-Location) $Value))
}

$scriptRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BackendDirectory)) {
  $BackendDirectory = Join-Path $scriptRoot "backend"
}
if ([string]::IsNullOrWhiteSpace($RequirementsFile)) {
  $RequirementsFile = Join-Path $BackendDirectory "requirements-runtime.txt"
}

$pythonPath = Resolve-PythonExecutable $PythonExecutable
$backendPath = Get-FullPath $BackendDirectory
$requirementsPath = Get-FullPath $RequirementsFile
$outputPath = Get-FullPath $OutputDirectory
$sourceHome = Split-Path -Parent $pythonPath

if (-not (Test-Path -LiteralPath $backendPath -PathType Container)) {
  throw "Backend directory was not found: $backendPath"
}
if (-not (Test-Path -LiteralPath $requirementsPath -PathType Leaf)) {
  throw "Pinned runtime requirements were not found: $requirementsPath"
}
if ([StringComparer]::OrdinalIgnoreCase.Equals($sourceHome, $outputPath)) {
  throw "Python runtime output must not replace the source Python installation."
}
if ($outputPath.StartsWith("$sourceHome\", [StringComparison]::OrdinalIgnoreCase)) {
  throw "Python runtime output must not be inside the source Python installation."
}

$version = (& $pythonPath -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}')").Trim()
if ($LASTEXITCODE -ne 0 -or $version -notmatch '^3\.12\.') {
  throw "LeadPilot requires a Python 3.12 build runtime. '$pythonPath' reported '$version'."
}

if (Test-Path -LiteralPath $outputPath) {
  Remove-Item -LiteralPath $outputPath -Recurse -Force
}
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

Write-Host "Copying Python $version from $sourceHome"
Copy-Item -Path (Join-Path $sourceHome "*") -Destination $outputPath -Recurse -Force

# The installed application never runs Python's own test suite. Removing its
# test certificates and fixtures keeps the distributable smaller and prevents
# test-only key material from being copied into the installer.
$pythonTests = Join-Path $outputPath "Lib\test"
if (Test-Path -LiteralPath $pythonTests) {
  Remove-Item -LiteralPath $pythonTests -Recurse -Force
}

$sitePackages = Join-Path $outputPath "Lib\site-packages"
if (Test-Path -LiteralPath $sitePackages) {
  Remove-Item -LiteralPath $sitePackages -Recurse -Force
}
New-Item -ItemType Directory -Path $sitePackages -Force | Out-Null

$env:PYTHONDONTWRITEBYTECODE = "1"
Write-Host "Installing backend dependencies into the private runtime"
& $pythonPath -m pip install --disable-pip-version-check --no-cache-dir --ignore-installed --target $sitePackages -r $requirementsPath
if ($LASTEXITCODE -ne 0) {
  throw "Backend dependency installation failed with exit code $LASTEXITCODE."
}

$runtimePython = Join-Path $outputPath "python.exe"
if (-not (Test-Path -LiteralPath $runtimePython -PathType Leaf)) {
  throw "The prepared runtime does not contain python.exe: $runtimePython"
}

$validation = "import sys; assert sys.version_info[:2] == (3, 12); import fastapi, uvicorn, multipart; print('runtime imports ok')"
& $runtimePython -c $validation
if ($LASTEXITCODE -ne 0) {
  throw "The prepared Python runtime could not import the backend dependencies."
}

Write-Host "Prepared private Python runtime: $outputPath"
