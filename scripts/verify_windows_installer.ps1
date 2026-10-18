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
  param(
    [string]$Executable,
    [string]$InstallDirectory,
    [string]$DataDirectory
  )

  $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="' + $InstallDirectory + '" /TASKS="desktopicon" /LEADPILOTDATADIR="' + $DataDirectory + '"'
  $process = Start-Process -FilePath $Executable -ArgumentList $arguments -Wait -PassThru
  if ($process.ExitCode -ne 0) {
    throw "Installer exited with code $($process.ExitCode)."
  }
}

function Invoke-Uninstaller {
  param(
    [string]$InstallDirectory,
    [string]$DataDirectory
  )

  $uninstaller = Join-Path $InstallDirectory "unins000.exe"
  Assert-Path $uninstaller
  $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LEADPILOTDATADIR="' + $DataDirectory + '"'
  $process = Start-Process -FilePath $uninstaller -ArgumentList $arguments -Wait -PassThru
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

function Get-TrackedFrontend {
  param(
    [string]$InstallDirectory,
    [string]$DataDirectory
  )

  $metadataPath = Join-Path $DataDirectory "runtime\frontend.process.json"
  if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return $null }
  try {
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $expected = [IO.Path]::GetFullPath((Join-Path $InstallDirectory "LeadPilot\leadpilot_frontend.exe"))
    $recorded = [IO.Path]::GetFullPath([string]$metadata.executable)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($recorded, $expected)) { return $null }
    $process = Get-Process -Id ([int]$metadata.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process -or $process.HasExited) { return $null }
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($process.Path), $expected)) { return $null }
    $recordedStart = [DateTimeOffset]::Parse([string]$metadata.started_at_utc)
    $actualStart = [DateTimeOffset]$process.StartTime.ToUniversalTime()
    if ([Math]::Abs(($actualStart - $recordedStart).TotalSeconds) -gt 15) { return $null }
    return $process
  } catch {
    return $null
  }
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

function Invoke-FrontendSmoke {
  param([string]$InstallDirectory, [string]$DataDirectory, [int]$CheckPort)

  $launcher = Join-Path $InstallDirectory "scripts\run_leadpilot.ps1"
  $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '" -InstallRoot "' + $InstallDirectory + '" -Port ' + $CheckPort + ' -LaunchFrontend'
  $launcherProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -PassThru
  $script:ActiveLauncherProcess = $launcherProcess
  $script:ActiveInstallDirectory = $InstallDirectory
  $script:ActiveDataDirectory = $DataDirectory
  $frontend = $null
  for ($attempt = 0; $attempt -lt 60; $attempt++) {
    Start-Sleep -Milliseconds 500
    $frontend = Get-TrackedFrontend $InstallDirectory $DataDirectory
    if ($null -ne $frontend -or $launcherProcess.HasExited) { break }
  }
  if ($null -eq $frontend) {
    if (-not $launcherProcess.HasExited) { Stop-Process -Id $launcherProcess.Id -Force -ErrorAction SilentlyContinue }
    $exitCode = if ($launcherProcess.HasExited) { $launcherProcess.ExitCode } else { "running" }
    throw "Installed launcher did not publish its owned packaged Flutter frontend (launcher state: $exitCode)."
  }
  $script:ActiveFrontendProcess = $frontend

  Start-Sleep -Seconds 3
  $closeRequested = $frontend.CloseMainWindow()
  $graceful = $frontend.WaitForExit(10000)
  if (-not $graceful -and -not $frontend.HasExited) {
    Stop-Process -Id $frontend.Id -Force
    $null = $frontend.WaitForExit(5000)
  }
  $null = $launcherProcess.WaitForExit(15000)
  if (-not $graceful) {
    throw "Owned packaged Flutter frontend did not exit gracefully after CloseMainWindow returned $closeRequested."
  }
  if (-not $launcherProcess.HasExited) {
    throw "Installed launcher did not exit after its owned frontend process closed."
  }
  if ($launcherProcess.ExitCode -ne 0) {
    throw "Installed launcher exited with code $($launcherProcess.ExitCode) after its owned frontend process closed."
  }
  $script:ActiveFrontendProcess = $null
  $script:ActiveLauncherProcess = $null
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

function Stop-TestOwnedFrontend {
  param(
    [System.Diagnostics.Process]$Process,
    [string]$InstallDirectory
  )

  if ($null -eq $Process -or $Process.HasExited) { return }
  $expected = [IO.Path]::GetFullPath((Join-Path $InstallDirectory "LeadPilot\leadpilot_frontend.exe"))
  try {
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($Process.Path), $expected)) {
      return
    }
    $null = $Process.CloseMainWindow()
    $null = $Process.WaitForExit(5000)
    if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force }
    $null = $Process.WaitForExit(5000)
  } catch { }
}

function Stop-TestOwnedBackendFromMetadata {
  param([string]$DataDirectory)

  $metadataPath = Join-Path (Join-Path $DataDirectory "runtime") "backend.process.json"
  if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return }
  try {
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $process = Get-Process -Id ([int]$metadata.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process -or $process.HasExited) {
      Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
      return
    }
    $recordedPath = [IO.Path]::GetFullPath([string]$metadata.executable)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($process.Path), $recordedPath)) { return }
    $recordedStart = [DateTimeOffset]::Parse([string]$metadata.started_at_utc)
    $actualStart = [DateTimeOffset]$process.StartTime.ToUniversalTime()
    if ([Math]::Abs(($actualStart - $recordedStart).TotalSeconds) -gt 15) { return }
    Stop-Process -Id $process.Id -Force
    $null = $process.WaitForExit(5000)
    if ($process.HasExited) {
      Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
    }
  } catch { }
}

function Invoke-TestOwnedCleanup {
  param(
    [string]$InstallDirectory,
    [string]$DataDirectory
  )

  $frontend = $script:ActiveFrontendProcess
  if ($null -eq $frontend) { $frontend = Get-TrackedFrontend $InstallDirectory $DataDirectory }
  Stop-TestOwnedFrontend $frontend $InstallDirectory

  $stopScript = Join-Path $InstallDirectory "scripts\stop_leadpilot.ps1"
  if (Test-Path -LiteralPath $stopScript -PathType Leaf) {
    try {
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopScript -InstallRoot $InstallDirectory -DataDirectory $DataDirectory -StopFrontend
    } catch { }
  }
  Stop-TestOwnedBackendFromMetadata $DataDirectory

  $launcher = $script:ActiveLauncherProcess
  if ($null -ne $launcher -and -not $launcher.HasExited) {
    try { $null = $launcher.WaitForExit(5000) } catch { }
    if (-not $launcher.HasExited) {
      Stop-Process -Id $launcher.Id -Force -ErrorAction SilentlyContinue
      try { $null = $launcher.WaitForExit(5000) } catch { }
    }
  }
  $script:ActiveFrontendProcess = $null
  $script:ActiveLauncherProcess = $null
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
$script:ActiveFrontendProcess = $null
$script:ActiveLauncherProcess = $null

try {
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $testLocalAppData -Force | Out-Null
  $env:LOCALAPPDATA = $testLocalAppData
  $env:LEADPILOT_DATA_DIRECTORY = $userData

  Invoke-Installer $installer $installDirectory $userData
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
  Invoke-Installer $installer $installDirectory $userData
  if (Test-Path -LiteralPath $metadata) {
    throw "Upgrade left the application-owned backend running."
  }
  Assert-Path $marker
  if ((Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash -ne $databaseHashBeforeUpgrade) {
    throw "Upgrade changed the persistent SQLite database."
  }
  Invoke-PackagedVerification $installDirectory ($Port + 2)

  Invoke-FrontendSmoke $installDirectory $userData ($Port + 3)
  Invoke-FrontendSmoke $installDirectory $userData ($Port + 4)
  Invoke-BackendOnlyStart $installDirectory ($Port + 5)
  Invoke-Uninstaller $installDirectory $userData

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
  Invoke-TestOwnedCleanup $installDirectory $userData
  if ($null -eq $oldLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $oldLocalAppData }
  if ($null -eq $oldDataOverride) { Remove-Item Env:LEADPILOT_DATA_DIRECTORY -ErrorAction SilentlyContinue } else { $env:LEADPILOT_DATA_DIRECTORY = $oldDataOverride }
  if (-not $KeepTestRoot -and (Test-Path -LiteralPath $testRoot)) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  } elseif ($KeepTestRoot) {
    Write-Host "Installer smoke test root retained at $testRoot"
  }
}
