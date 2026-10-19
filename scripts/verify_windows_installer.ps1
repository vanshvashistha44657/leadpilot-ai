param(
  [Parameter(Mandatory = $true)]
  [string]$InstallerPath,
  [string]$TestRoot = "",
  [int]$Port = 18100,
  [switch]$KeepTestRoot
)

$ErrorActionPreference = "Stop"

function Write-ProgressLog {
  param([string]$Message)

  $line = "[{0}] {1}" -f (Get-Date).ToUniversalTime().ToString("o"), $Message
  Write-Host $line
  if (-not [string]::IsNullOrWhiteSpace($script:ProgressLogPath)) {
    Add-Content -LiteralPath $script:ProgressLogPath -Value $line -Encoding utf8
  }
}

function Stop-TestOwnedProcessTree {
  param([int]$RootProcessId)

  $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $children = @{}
  foreach ($process in $processes) {
    $parent = [int]$process.ParentProcessId
    if (-not $children.ContainsKey($parent)) { $children[$parent] = @() }
    $children[$parent] += $process
  }
  $queue = New-Object System.Collections.Queue
  $queue.Enqueue($RootProcessId)
  $ids = New-Object System.Collections.Generic.List[int]
  while ($queue.Count -gt 0) {
    $parentId = [int]$queue.Dequeue()
    if ($ids.Contains($parentId)) { continue }
    $ids.Add($parentId)
    if ($children.ContainsKey($parentId)) {
      foreach ($child in $children[$parentId]) { $queue.Enqueue([int]$child.ProcessId) }
    }
  }
  foreach ($id in ($ids | Sort-Object -Descending)) {
    $process = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($null -eq $process) { continue }
    $cim = $processes | Where-Object { [int]$_.ProcessId -eq $id } | Select-Object -First 1
    $owned = $id -eq $RootProcessId -or
      ($cim -and (([string]$cim.ExecutablePath).StartsWith($script:TestRoot, [StringComparison]::OrdinalIgnoreCase) -or
        ([string]$cim.CommandLine).Contains($script:TestRoot, [StringComparison]::OrdinalIgnoreCase) -or
        ([string]$cim.CommandLine).Contains($script:InstallDirectory, [StringComparison]::OrdinalIgnoreCase)))
    if ($owned) {
      Write-ProgressLog "CLEANUP stopping owned process tree pid=$id"
      Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    } else {
      Write-ProgressLog "CLEANUP left non-owned descendant pid=$id running"
    }
  }
}

function Start-BoundedProcess {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [string]$ArgumentList = "",
    [string]$WorkingDirectory = "",
    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds,
    [Parameter(Mandatory = $true)]
    [string]$OperationName,
    [string]$StandardOutputPath = "",
    [string]$StandardErrorPath = ""
  )

  Write-ProgressLog "START $OperationName (timeout=${TimeoutSeconds}s)"
  $parameters = @{
    FilePath = $FilePath
    ArgumentList = $ArgumentList
    PassThru = $true
    ErrorAction = "Stop"
  }
  if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $parameters.WorkingDirectory = $WorkingDirectory }
  if (-not [string]::IsNullOrWhiteSpace($StandardOutputPath)) { $parameters.RedirectStandardOutput = $StandardOutputPath }
  if (-not [string]::IsNullOrWhiteSpace($StandardErrorPath)) { $parameters.RedirectStandardError = $StandardErrorPath }

  $process = Start-Process @parameters
  try {
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      Write-ProgressLog "TIMEOUT $OperationName (pid=$($process.Id)); stopping only this process"
      Stop-TestOwnedProcessTree $process.Id
      try { $null = $process.WaitForExit(5000) } catch { }
      throw "$OperationName exceeded its ${TimeoutSeconds}-second timeout."
    }
    $process.Refresh()
    $exitCode = [int]$process.ExitCode
    Write-ProgressLog "END $OperationName (pid=$($process.Id), exit=$exitCode)"
    return [pscustomobject]@{
      Id = $process.Id
      ExitCode = $exitCode
      HasExited = $process.HasExited
    }
  } catch {
    if ($null -ne $process -and -not $process.HasExited) {
      Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    throw
  }
}

function Save-Diagnostics {
  param([string]$DestinationDirectory)

  if ([string]::IsNullOrWhiteSpace($DestinationDirectory) -or
      [string]::IsNullOrWhiteSpace($script:TestRoot) -or
      -not (Test-Path -LiteralPath $script:TestRoot)) { return }
  try {
    New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    if (Test-Path -LiteralPath $script:ProgressLogPath) {
      Copy-Item -LiteralPath $script:ProgressLogPath -Destination (Join-Path $DestinationDirectory "installer-lifecycle.log") -Force
    }
    $processSnapshot = Join-Path $DestinationDirectory "process-snapshot.txt"
    Get-CimInstance Win32_Process |
      Where-Object {
        ($_.ExecutablePath -and $_.ExecutablePath.IndexOf($script:TestRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
        ($_.CommandLine -and $_.CommandLine.IndexOf($script:TestRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0)
      } |
      Select-Object ProcessId, ParentProcessId, ExecutablePath, CommandLine |
      Format-List | Out-File -LiteralPath $processSnapshot -Encoding utf8
    $logDirectory = Join-Path $script:TestRoot "process-logs"
    if (Test-Path -LiteralPath $logDirectory) {
      Copy-Item -LiteralPath $logDirectory -Destination (Join-Path $DestinationDirectory "process-logs") -Recurse -Force
    }
    Write-ProgressLog "Diagnostics saved to $DestinationDirectory"
  } catch {
    Write-ProgressLog "WARNING diagnostics save failed: $($_.Exception.Message)"
  }
}

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

function Wait-PathAbsent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PathValue,
    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds,
    [Parameter(Mandatory = $true)]
    [string]$OperationName
  )

  Write-ProgressLog "START $OperationName (timeout=${TimeoutSeconds}s)"
  $deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
  while ((Get-Date).ToUniversalTime() -lt $deadline) {
    if (-not (Test-Path -LiteralPath $PathValue)) {
      Write-ProgressLog "END $OperationName (path absent)"
      return
    }
    Start-Sleep -Milliseconds 250
  }
  throw "$OperationName exceeded its ${TimeoutSeconds}-second timeout: $PathValue"
}

function Invoke-Installer {
  param(
    [string]$Executable,
    [string]$InstallDirectory,
    [string]$DataDirectory
  )

  $number = if ($script:InstallerInvocation -gt 0) { $script:InstallerInvocation } else { 1 }
  $script:InstallerInvocation = $number + 1
  $logDirectory = Join-Path $script:TestRoot "process-logs"
  New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
  $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="' + $InstallDirectory + '" /TASKS="desktopicon" /LEADPILOTDATADIR="' + $DataDirectory + '" /LOG="' + (Join-Path $logDirectory "installer-$number.log") + '"'
  $process = Start-BoundedProcess -FilePath $Executable -ArgumentList $arguments -TimeoutSeconds 180 -OperationName "installer invocation $number" -StandardOutputPath (Join-Path $logDirectory "installer-$number.stdout.log") -StandardErrorPath (Join-Path $logDirectory "installer-$number.stderr.log")
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
  $logDirectory = Join-Path $script:TestRoot "process-logs"
  New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
  $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LEADPILOTDATADIR="' + $DataDirectory + '" /LOG="' + (Join-Path $logDirectory "uninstaller.log") + '"'
  $process = Start-BoundedProcess -FilePath $uninstaller -ArgumentList $arguments -TimeoutSeconds 120 -OperationName "uninstaller invocation" -StandardOutputPath (Join-Path $logDirectory "uninstaller.stdout.log") -StandardErrorPath (Join-Path $logDirectory "uninstaller.stderr.log")
  if ($process.ExitCode -ne 0) {
    throw "Uninstaller exited with code $($process.ExitCode)."
  }
  Wait-PathAbsent (Split-Path -Parent $uninstaller) 30 "wait for uninstaller file cleanup"
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
  Write-ProgressLog "START packaged backend verification on port $CheckPort"
  $process = Start-BoundedProcess -FilePath "powershell.exe" -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '" -InstallRoot "' + $InstallDirectory + '" -DataDirectory "' + $script:UserData + '" -Port ' + $CheckPort + ' -VerifyOnly') -WorkingDirectory $InstallDirectory -TimeoutSeconds 30 -OperationName "packaged backend verification on port $CheckPort" -StandardOutputPath (Join-Path $script:ProcessLogDirectory "backend-verify-$CheckPort.stdout.log") -StandardErrorPath (Join-Path $script:ProcessLogDirectory "backend-verify-$CheckPort.stderr.log")
  if ($process.ExitCode -ne 0) {
    throw "Installed package verification failed with exit code $($process.ExitCode)."
  }
}

function Invoke-FrontendSmoke {
  param([string]$InstallDirectory, [string]$DataDirectory, [int]$CheckPort)

  $launcher = Join-Path $InstallDirectory "scripts\run_leadpilot.ps1"
  $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '" -InstallRoot "' + $InstallDirectory + '" -DataDirectory "' + $DataDirectory + '" -Port ' + $CheckPort + ' -FrontendTimeoutSeconds 120 -LaunchFrontend'
  Write-ProgressLog "START frontend smoke on port $CheckPort"
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

  Write-ProgressLog "FRONTEND STARTED pid=$($frontend.Id) on port $CheckPort; requesting graceful shutdown"
  Start-Sleep -Seconds 3
  $closeRequested = $frontend.CloseMainWindow()
  Write-ProgressLog "FRONTEND CLOSE REQUESTED pid=$($frontend.Id) result=$closeRequested"
  $graceful = $frontend.WaitForExit(10000)
  Write-ProgressLog "FRONTEND WAIT COMPLETE pid=$($frontend.Id) graceful=$graceful"
  if (-not $graceful -and -not $frontend.HasExited) {
    Stop-Process -Id $frontend.Id -Force
    $null = $frontend.WaitForExit(5000)
  }
  Write-ProgressLog "START launcher wait pid=$($launcherProcess.Id)"
  $launcherExited = $launcherProcess.WaitForExit(15000)
  Write-ProgressLog "END launcher wait pid=$($launcherProcess.Id) exited=$launcherExited"
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
  Write-ProgressLog "END frontend smoke on port $CheckPort"
}

function Invoke-BackendOnlyStart {
  param([string]$InstallDirectory, [int]$CheckPort)

  $launcher = Join-Path $InstallDirectory "scripts\run_leadpilot.ps1"
  Write-ProgressLog "START backend-only launch on port $CheckPort"
  $process = Start-BoundedProcess -FilePath "powershell.exe" -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '" -InstallRoot "' + $InstallDirectory + '" -DataDirectory "' + $script:UserData + '" -Port ' + $CheckPort + ' -KeepBackend') -WorkingDirectory $InstallDirectory -TimeoutSeconds 30 -OperationName "backend-only launch on port $CheckPort" -StandardOutputPath (Join-Path $script:ProcessLogDirectory "backend-only-$CheckPort.stdout.log") -StandardErrorPath (Join-Path $script:ProcessLogDirectory "backend-only-$CheckPort.stderr.log")
  if ($process.ExitCode -ne 0) {
    throw "Installed backend-only launcher exited with code $($process.ExitCode)."
  }
  Write-ProgressLog "END backend-only launch on port $CheckPort"
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
      Write-ProgressLog "START cleanup stop helper"
      $stopProcess = Start-BoundedProcess -FilePath "powershell.exe" -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $stopScript + '" -InstallRoot "' + $InstallDirectory + '" -DataDirectory "' + $DataDirectory + '" -StopFrontend') -WorkingDirectory $InstallDirectory -TimeoutSeconds 20 -OperationName "cleanup stop helper" -StandardOutputPath (Join-Path $script:ProcessLogDirectory "cleanup-stop.stdout.log") -StandardErrorPath (Join-Path $script:ProcessLogDirectory "cleanup-stop.stderr.log")
      Write-ProgressLog "END cleanup stop helper exit=$($stopProcess.ExitCode)"
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
$script:InstallerInvocation = 1
$script:UserData = $userData
$script:ProcessLogDirectory = Join-Path $testRoot "process-logs"
$script:ProgressLogPath = Join-Path $testRoot "installer-lifecycle.log"
$script:DiagnosticDirectory = Join-Path (Split-Path -Parent $installer) "installer-test-diagnostics"
$script:TestFailed = $false
$script:InstallDirectory = $installDirectory
New-Item -ItemType Directory -Path $script:ProcessLogDirectory -Force | Out-Null
Write-ProgressLog "BEGIN installer lifecycle verification"

try {
  Write-ProgressLog "START test root and temporary user-data setup"
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $testLocalAppData -Force | Out-Null
  $env:LOCALAPPDATA = $testLocalAppData
  $env:LEADPILOT_DATA_DIRECTORY = $userData
  Write-ProgressLog "END test root and temporary user-data setup"

  Write-ProgressLog "START initial installation"
  Invoke-Installer $installer $installDirectory $userData
  Write-ProgressLog "END initial installation"
  Write-ProgressLog "START installed-file and shortcut assertions"
  Assert-Path (Join-Path $installDirectory "LeadPilot\leadpilot_frontend.exe")
  Assert-Path (Join-Path $installDirectory "runtime\python\python.exe")
  Assert-LauncherShortcut (Get-InstalledShortcut "LeadPilot AI.lnk")
  Assert-NoPackageSecrets $installDirectory
  Write-ProgressLog "END installed-file and shortcut assertions"

  Write-ProgressLog "START initial installed backend verification"
  Invoke-PackagedVerification $installDirectory $Port
  Write-ProgressLog "END initial installed backend verification"
  $database = Join-Path $userData "data\leadpilot.db"
  $config = Join-Path $userData "config\backend.env"
  $marker = Join-Path $userData "backups\phase2-preservation-marker.txt"
  Write-ProgressLog "START initial persistence assertions"
  Assert-Path $database
  Assert-Path $config
  New-Item -ItemType Directory -Path (Split-Path -Parent $marker) -Force | Out-Null
  "installer lifecycle marker" | Set-Content -LiteralPath $marker -Encoding utf8
  $databaseHashBeforeUpgrade = (Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash
  Write-ProgressLog "END initial persistence assertions"

  Invoke-BackendOnlyStart $installDirectory ($Port + 1)
  $metadata = Join-Path $userData "runtime\backend.process.json"
  Write-ProgressLog "START pre-upgrade ownership assertion"
  Assert-Path $metadata
  Write-ProgressLog "END pre-upgrade ownership assertion"
  Write-ProgressLog "START upgrade while backend is running"
  Invoke-Installer $installer $installDirectory $userData
  Write-ProgressLog "END upgrade while backend is running"
  Write-ProgressLog "START post-upgrade ownership and persistence assertions"
  if (Test-Path -LiteralPath $metadata) {
    throw "Upgrade left the application-owned backend running."
  }
  Assert-Path $marker
  if ((Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash -ne $databaseHashBeforeUpgrade) {
    throw "Upgrade changed the persistent SQLite database."
  }
  Write-ProgressLog "END post-upgrade ownership and persistence assertions"
  Invoke-PackagedVerification $installDirectory ($Port + 2)

  Invoke-FrontendSmoke $installDirectory $userData ($Port + 3)
  Invoke-FrontendSmoke $installDirectory $userData ($Port + 4)
  Invoke-BackendOnlyStart $installDirectory ($Port + 5)
  Write-ProgressLog "START uninstall while backend is running"
  Invoke-Uninstaller $installDirectory $userData
  Write-ProgressLog "END uninstall while backend is running"

  Write-ProgressLog "START post-uninstall application and persistence assertions"
  if (Test-Path -LiteralPath $installDirectory) {
    throw "Uninstall left the installation directory behind: $installDirectory"
  }
  Assert-Path $database
  Assert-Path $config
  Assert-Path $marker
  if ($null -ne (Get-InstalledShortcut "LeadPilot AI.lnk")) {
    throw "Uninstall left a LeadPilot shortcut behind."
  }
  Write-ProgressLog "END post-uninstall application and persistence assertions"

  Write-ProgressLog "END installer lifecycle verification: success"
  Write-Host "Windows installer smoke verification passed: install, launcher contract, frontend launch, upgrade, backend shutdown, uninstall, and data preservation."
} catch {
  $script:TestFailed = $true
  Write-ProgressLog "FAIL installer lifecycle verification: $($_.Exception.Message)"
  throw
} finally {
  Write-ProgressLog "START bounded test-owned cleanup"
  Invoke-TestOwnedCleanup $installDirectory $userData
  Write-ProgressLog "END bounded test-owned cleanup"
  if ($script:TestFailed) {
    Save-Diagnostics $script:DiagnosticDirectory
  }
  if ($null -eq $oldLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $oldLocalAppData }
  if ($null -eq $oldDataOverride) { Remove-Item Env:LEADPILOT_DATA_DIRECTORY -ErrorAction SilentlyContinue } else { $env:LEADPILOT_DATA_DIRECTORY = $oldDataOverride }
  if (-not $KeepTestRoot -and (Test-Path -LiteralPath $testRoot)) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  } elseif ($KeepTestRoot) {
    Write-Host "Installer smoke test root retained at $testRoot"
  }
}
