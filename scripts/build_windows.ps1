param(
  [switch]$CreateRunners
)

$ErrorActionPreference = "Stop"
$frontend = Join-Path $PSScriptRoot "..\frontend"
if (-not (Test-Path -LiteralPath $frontend)) {
  throw "Frontend directory not found: $frontend"
}
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  throw "Flutter SDK is required. Install Flutter and enable Windows desktop support first."
}

Push-Location $frontend
try {
  $windowsRunner = Join-Path $frontend "windows"
  if ($CreateRunners -or -not (Test-Path -LiteralPath $windowsRunner)) {
    flutter create --platforms=windows --empty .
  }
  flutter pub get
  flutter analyze
  flutter test
  flutter build windows --release
} finally {
  Pop-Location
}
