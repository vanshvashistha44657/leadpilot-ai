param(
  [Parameter(Mandatory = $true)]
  [string]$InstallerPath,
  [string]$TestRoot = "",
  [int]$Port = 18100,
  [switch]$KeepTestRoot
)

$ErrorActionPreference = "Stop"

function ConvertTo-FullPath {
  param([string]$PathValue)

  if ([IO.Path]::IsPathRooted($PathValue)) {
    return [IO.Path]::GetFullPath($PathValue)
  }
  return [IO.Path]::GetFullPath((Join-Path (Get-Location) $PathValue))
}

function Assert-Path {
  param([string]$PathValue)

  if (-not (Test-Path -LiteralPath $PathValue)) {
    throw "Installer smoke check expected this path: $PathValue"
  }
}

function Invoke-Installer {
  param([string]$Executable, [string]$InstallDirectory)

  $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="' + $InstallDirectory + '" /TASKS="desktopicon"'
  $process = Start-Process -FilePath $Executable -ArgumentList $arguments -Wait -PassThru
  if ($process.ExitCode -ne 0) {
    throw "Installer exited with code $($process.ExitCode)."
  }
}

function Invoke-Uninstaller {
  param([string]$InstallDirectory)

  $uninstaller = Join-Path $InstallDirectory "unins000.exe"
  Assert-Path $uninstaller
  $process = Start-Process -FilePath $uninstaller -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART" -Wait -PassThru
  if ($process.ExitCode -ne 0) {
    throw "Uninstaller exited with code $($process.ExitCode)."
  }
}

function Get-InstalledShortcut {
  param([string]$FileName)

  $candidates = @(
    (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\$FileName"),
    (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$FileName"),
    (Join-Path $env:PUBLIC "Desktop\$FileName"),
    (Join-Path ([Environment]::GetFolderPath("Desktop")) $FileName)
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  }
  return $null
}

function Assert-LauncherShortcut {
  param([string]$ShortcutPath)

  Assert-Path $ShortcutPath
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($ShortcutPath)
  if ($shortcut.TargetPath -notmatch "(?i)\\powershell(?:\.exe)?$") {
    throw "Shortcut does not target Windows PowerShell: $ShortcutPath"
  }
  if ($shortcut.Arguments -notmatch "run_leadpilot\.ps1" -or
      $shortcut.Arguments -notmatch "-LaunchFrontend") {
    throw "Shortcut does not invoke the LeadPilot launcher contract: $ShortcutPath"
  }
}

function Invoke-PackagedVerification {
  param([string]$InstallDirectory, [int]$CheckPort)

  $launcher = Join-Path $InstallDirectory "scripts\run_leadpilot.ps1"
  Assert-Path $launcher
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -InstallRoot $InstallDirectory -Port $CheckPort -VerifyOnly
  if ($LASTEXITCODE -ne 0) {
    throw "Installed package verification failed with exit code $LASTEXITCODE."
  }
}

function Find-OwnedFrontend {
  param([string]$InstallDirectory)

  $expected = [IO.Path]::GetFullPath((Join-Path $InstallDirectory "LeadPilot\leadpilot_frontend.exe"))
  foreach ($process in @(Get-Process -Name "leadpilot_frontend" -ErrorAction SilentlyContinue)) {
    try {
      if (-not $process.HasExited -and [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($process.Path), $expected)) {
        return $process
      }
    } catch { }
  }
  return $null
}

function Invoke-FrontendSmoke {
  param([string]$InstallDirectory, [int]$CheckPort)

  $launcher = Join-Path $InstallDirectory "scripts\run_leadpilot.ps1"
  $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '" -InstallRoot "' + $InstallDirectory + '" -Port ' + $CheckPort + ' -LaunchFrontend'
  $launcherProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -PassThru
  $frontend = $null
  for ($attempt = 0; $attempt -lt 60; $attempt++) {
    Start-Sleep -Milliseconds 500
    $frontend = Find-OwnedFrontend $InstallDirectory
    if ($null -ne $frontend -or $launcherProcess.HasExited) { break }
  }
  if ($null -eq $frontend) {
    if (-not $launcherProcess.HasExited) { Stop-Process -Id $launcherProcess.Id -Force -ErrorAction SilentlyContinue }
    throw "Installed launcher did not start the packaged Flutter frontend."
  }

  Start-Sleep -Seconds 3
  $null = $frontend.CloseMainWindow()
  $graceful = $frontend.WaitForExit(10000)
  if (-not $graceful -and -not $frontend.HasExited) {
    Stop-Process -Id $frontend.Id -Force
  }
  $null = $launcherProcess.WaitForExit(15000)
  if (-not $launcherProcess.HasExited -or $launcherProcess.ExitCode -ne 0) {
    throw "Installed launcher did not cleanly exit after the frontend closed."
  }
  if (-not $graceful) {
    throw "Installed Flutter frontend required a forced close during the smoke test."
  }
}

function Invoke-BackendOnlyStart {
  param([string]$InstallDirectory, [int]$CheckPort)

  $launcher = Join-Path $InstallDirectory "scripts\run_leadpilot.ps1"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -InstallRoot $InstallDirectory -Port $CheckPort -KeepBackend
  if ($LASTEXITCODE -ne 0) {
    throw "Installed backend-only launcher exited with code $LASTEXITCODE."
  }
}

function Assert-NoPackageSecrets {
  param([string]$InstallDirectory)

  $forbiddenNames = @(".env", ".db", ".sqlite", ".sqlite3", ".log", ".pem", ".key", ".p12", ".pfx")
  foreach ($file in @(Get-ChildItem -LiteralPath $InstallDirectory -Recurse -File)) {
    if ($forbiddenNames -contains $file.Extension.ToLowerInvariant() -or $file.Name -match '^\.env$') {
      throw "Installer copied a forbidden runtime/private file: $($file.FullName)"
    }
  }
}

$installer = ConvertTo-FullPath $InstallerPath
Assert-Path $installer
if ([string]::IsNullOrWhiteSpace($TestRoot)) {
  $TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("LeadPilot-installer-test-" + [Guid]::NewGuid().ToString("N"))
}
$testRoot = ConvertTo-FullPath $TestRoot
if (-not $testRoot.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
  throw "Installer smoke tests may only delete a test root under the system temporary directory: $testRoot"
}
$installDirectory = Join-Path $testRoot "Installed LeadPilot AI"
$testLocalAppData = Join-Path $testRoot "LocalAppData"
$userData = Join-Path $testLocalAppData "LeadPilot"
$oldLocalAppData = $env:LOCALAPPDATA
$oldDataOverride = $env:LEADPILOT_DATA_DIRECTORY

try {
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $testLocalAppData -Force | Out-Null
  $env:LOCALAPPDATA = $testLocalAppData
  $env:LEADPILOT_DATA_DIRECTORY = $userData

  Invoke-Installer $installer $installDirectory
  Assert-Path (Join-Path $installDirectory "LeadPilot\leadpilot_frontend.exe")
  Assert-Path (Join-Path $installDirectory "runtime\python\python.exe")
  Assert-LauncherShortcut (Get-InstalledShortcut "LeadPilot AI.lnk")
  Assert-NoPackageSecrets $installDirectory

  Invoke-PackagedVerification $installDirectory $Port
  $database = Join-Path $userData "data\leadpilot.db"
  $config = Join-Path $userData "config\backend.env"
  $marker = Join-Path $userData "backups\phase2-preservation-marker.txt"
  Assert-Path $database
  Assert-Path $config
  New-Item -ItemType Directory -Path (Split-Path -Parent $marker) -Force | Out-Null
  "installer lifecycle marker" | Set-Content -LiteralPath $marker -Encoding utf8
  $databaseHashBeforeUpgrade = (Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash

  Invoke-BackendOnlyStart $installDirectory ($Port + 1)
  $metadata = Join-Path $userData "runtime\backend.process.json"
  Assert-Path $metadata
  Invoke-Installer $installer $installDirectory
  if (Test-Path -LiteralPath $metadata) {
    throw "Upgrade left the application-owned backend running."
  }
  Assert-Path $marker
  if ((Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash -ne $databaseHashBeforeUpgrade) {
    throw "Upgrade changed the persistent SQLite database."
  }
  Invoke-PackagedVerification $installDirectory ($Port + 2)

  Invoke-FrontendSmoke $installDirectory ($Port + 3)
  Invoke-FrontendSmoke $installDirectory ($Port + 4)
  Invoke-BackendOnlyStart $installDirectory ($Port + 5)
  Invoke-Uninstaller $installDirectory

  if (Test-Path -LiteralPath $installDirectory) {
    throw "Uninstall left the installation directory behind: $installDirectory"
  }
  Assert-Path $database
  Assert-Path $config
  Assert-Path $marker
  if ($null -ne (Get-InstalledShortcut "LeadPilot AI.lnk")) {
    throw "Uninstall left a LeadPilot shortcut behind."
  }

  Write-Host "Windows installer smoke verification passed: install, launcher contract, frontend launch, upgrade, backend shutdown, uninstall, and data preservation."
} finally {
  if ($null -eq $oldLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $oldLocalAppData }
  if ($null -eq $oldDataOverride) { Remove-Item Env:LEADPILOT_DATA_DIRECTORY -ErrorAction SilentlyContinue } else { $env:LEADPILOT_DATA_DIRECTORY = $oldDataOverride }
  if (-not $KeepTestRoot -and (Test-Path -LiteralPath $testRoot)) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  } elseif ($KeepTestRoot) {
    Write-Host "Installer smoke test root retained at $testRoot"
  }
}
