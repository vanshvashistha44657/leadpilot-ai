param(
  [string]$OutputDirectory = "",
  [string]$PythonExecutable = "python"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$frontend = Join-Path $root "frontend"
$backend = Join-Path $root "backend"
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path $root "dist\leadpilot-windows"
}

$release = Join-Path $frontend "build\windows\x64\runner\Release"
if (-not (Test-Path -LiteralPath $release)) {
  throw "Flutter Windows release output was not found at $release. Run scripts\build_windows.ps1 after Visual Studio is installed."
}
if (-not (Get-Command $PythonExecutable -ErrorAction SilentlyContinue)) {
  throw "Python executable '$PythonExecutable' was not found. Use the Python runtime that will ship with the installer."
}

if (Test-Path -LiteralPath $OutputDirectory) {
  Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
New-Item -ItemType Directory -Path (Join-Path $OutputDirectory "backend") | Out-Null
New-Item -ItemType Directory -Path (Join-Path $OutputDirectory "config") | Out-Null
New-Item -ItemType Directory -Path (Join-Path $OutputDirectory "data") | Out-Null

Copy-Item -LiteralPath $release -Destination (Join-Path $OutputDirectory "LeadPilot") -Recurse
Copy-Item -LiteralPath (Join-Path $backend "app") -Destination (Join-Path $OutputDirectory "backend") -Recurse -Force
Copy-Item -LiteralPath (Join-Path $backend "pyproject.toml") -Destination (Join-Path $OutputDirectory "backend") -Force
Copy-Item -LiteralPath (Join-Path $backend ".env.example") -Destination (Join-Path $OutputDirectory "config\backend.env.example") -Force

@'
# LeadPilot Windows staging layout
#
# LeadPilot\                 Flutter release output
# backend\app\              FastAPI source
# backend\migrations\       SQLite migrations
# config\                    Local configuration templates only
# data\                      Database/backups/runtime state
#
# The installer must provision a private Python 3.12 runtime and install the
# backend dependencies into that runtime. Do not place provider secrets in the
# Flutter bundle. Generate a local token at first launch and pass it only to
# the localhost backend and desktop process.
'@ | Set-Content -LiteralPath (Join-Path $OutputDirectory "INSTALL_LAYOUT.txt") -Encoding utf8

Write-Host "Prepared portable Windows staging directory: $OutputDirectory"
Write-Host "Frontend release: $(Join-Path $OutputDirectory 'LeadPilot')"
Write-Host "Backend source: $(Join-Path $OutputDirectory 'backend')"
Write-Host "This script does not sign binaries or create an installer. Use MSIX, WiX, or Inno Setup after bundling and testing the Python runtime."
