param(
  [string]$StagingDirectory = "",
  [string]$OutputDirectory = "",
  [string]$InnoSetupCompiler = "",
  [string]$AppVersion = "0.1.0"
)

$ErrorActionPreference = "Stop"

function ConvertTo-FullPath {
  param([string]$PathValue)

  if ([IO.Path]::IsPathRooted($PathValue)) {
    return [IO.Path]::GetFullPath($PathValue)
  }
  return [IO.Path]::GetFullPath((Join-Path (Get-Location) $PathValue))
}

function Resolve-InnoCompiler {
  param([string]$RequestedPath)

  if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
    if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
      throw "Inno Setup compiler was not found: $RequestedPath"
    }
    return [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RequestedPath).Path)
  }

  $command = Get-Command iscc.exe -ErrorAction SilentlyContinue
  if ($null -ne $command) { return [IO.Path]::GetFullPath($command.Source) }

  $candidates = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 7\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 7\ISCC.exe"
  )
  foreach ($candidate in $candidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return [IO.Path]::GetFullPath($candidate)
    }
  }
  throw "Inno Setup compiler (ISCC.exe) was not found. Install Inno Setup for installer builds; unrelated tests do not require it."
}

$root = ConvertTo-FullPath (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($StagingDirectory)) {
  $StagingDirectory = Join-Path $root "dist\leadpilot-windows"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path $root "dist"
}
$staging = ConvertTo-FullPath $StagingDirectory
$output = ConvertTo-FullPath $OutputDirectory
$iss = ConvertTo-FullPath (Join-Path $root "packaging\windows\LeadPilot.iss")
$compiler = Resolve-InnoCompiler $InnoSetupCompiler
$localAppData = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $env:TEMP } else { $env:LOCALAPPDATA }
$persistentData = ConvertTo-FullPath (Join-Path $localAppData "LeadPilot")
$outputPrefix = $output.TrimEnd('\') + '\'
$dataPrefix = $persistentData.TrimEnd('\') + '\'
if ([StringComparer]::OrdinalIgnoreCase.Equals($output, $persistentData) -or
    $output.StartsWith($dataPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    $persistentData.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Refusing to place installer output inside or over persistent user data: $output"
}

if (-not (Test-Path -LiteralPath $staging -PathType Container)) {
  throw "Windows package staging directory was not found: $staging. Run scripts\package_windows.ps1 first."
}
if (-not (Test-Path -LiteralPath $iss -PathType Leaf)) {
  throw "Inno Setup definition was not found: $iss"
}

$requiredFiles = @(
  (Join-Path $staging "LeadPilot\leadpilot_frontend.exe"),
  (Join-Path $staging "app_icon.ico"),
  (Join-Path $staging "runtime\python\python.exe"),
  (Join-Path $staging "backend\app\main.py"),
  (Join-Path $staging "scripts\run_leadpilot.ps1"),
  (Join-Path $staging "scripts\stop_leadpilot.ps1")
)
foreach ($requiredFile in $requiredFiles) {
  if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
    throw "Installer input is incomplete; required file was not found: $requiredFile"
  }
}
if (Test-Path -LiteralPath (Join-Path $staging "data")) {
  throw "Installer input contains a package-local data directory. Persistent user data must remain outside the installation directory."
}

New-Item -ItemType Directory -Path $output -Force | Out-Null
$installerPath = Join-Path $output "LeadPilot-Setup.exe"
if (Test-Path -LiteralPath $installerPath) {
  Remove-Item -LiteralPath $installerPath -Force
}

Write-Host "Compiling LeadPilot installer with $compiler"
& $compiler "/Qp" "/DAppVersion=$AppVersion" "/DStagingDirectory=$staging" "/O$output" $iss
if ($LASTEXITCODE -ne 0) {
  throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
  throw "Inno Setup reported success but did not produce $installerPath"
}

$hash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
Write-Host "Built LeadPilot installer: $installerPath"
Write-Host "SHA256: $hash"
