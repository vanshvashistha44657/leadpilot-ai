#ifndef AppVersion
#define AppVersion "0.1.0"
#endif

#ifndef StagingDirectory
#define StagingDirectory "..\..\dist\leadpilot-windows"
#endif

#define AppName "LeadPilot AI"
#define AppPublisher "LeadPilot AI"

[Setup]
AppId={{9B8DF6F4-0B54-4B0A-9D57-2E3AFB5A8C1D}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\LeadPilot AI
DefaultGroupName={#AppName}
DisableProgramGroupPage=no
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=LeadPilot-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\LeadPilot\leadpilot_frontend.exe
SetupIconFile={#StagingDirectory}\app_icon.ico
ChangesAssociations=no
AllowNoIcons=no
UsePreviousAppDir=yes
VersionInfoDescription=LeadPilot AI Windows installer
VersionInfoProductName=LeadPilot AI
VersionInfoProductVersion={#AppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a Desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#StagingDirectory}\INSTALL_LAYOUT.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StagingDirectory}\LeadPilot\*"; DestDir: "{app}\LeadPilot"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "{#StagingDirectory}\backend\*"; DestDir: "{app}\backend"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "{#StagingDirectory}\runtime\*"; DestDir: "{app}\runtime"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "{#StagingDirectory}\scripts\*"; DestDir: "{app}\scripts"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "{#StagingDirectory}\config\backend.env.example"; DestDir: "{app}\config"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\run_leadpilot.ps1"" -InstallRoot ""{app}"" -LaunchFrontend"; WorkingDir: "{app}"; IconFilename: "{app}\LeadPilot\leadpilot_frontend.exe"; Comment: "Start LeadPilot AI"
Name: "{autodesktop}\{#AppName}"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\run_leadpilot.ps1"" -InstallRoot ""{app}"" -LaunchFrontend"; WorkingDir: "{app}"; IconFilename: "{app}\LeadPilot\leadpilot_frontend.exe"; Tasks: desktopicon; Comment: "Start LeadPilot AI"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\run_leadpilot.ps1"" -InstallRoot ""{app}"" -LaunchFrontend"; WorkingDir: "{app}"; Description: "Launch LeadPilot AI"; Flags: postinstall nowait skipifsilent runasoriginaluser

[Code]
function TrimTrailingBackslashes(PathValue: string): string;
begin
  Result := PathValue;
  while (Length(Result) > 3) and (Result[Length(Result)] = '\') do
    Delete(Result, Length(Result), 1);
end;

function IsSameOrChildPath(ParentPath, CandidatePath: string): Boolean;
var
  ParentNormalized, CandidateNormalized, Prefix: string;
begin
  ParentNormalized := TrimTrailingBackslashes(ParentPath);
  CandidateNormalized := TrimTrailingBackslashes(CandidatePath);
  Prefix := ParentNormalized + '\';
  Result := (CompareText(ParentNormalized, CandidateNormalized) = 0) or
    ((Length(CandidateNormalized) > Length(Prefix)) and
      (CompareText(Copy(CandidateNormalized, 1, Length(Prefix)), Prefix) = 0));
end;

function PathsOverlap(FirstPath, SecondPath: string): Boolean;
begin
  Result := IsSameOrChildPath(FirstPath, SecondPath) or
    IsSameOrChildPath(SecondPath, FirstPath);
end;

function PersistentDataDirectory: string;
var
  CommandLineDataDirectory: string;
begin
  CommandLineDataDirectory := ExpandConstant('{param:leadpilotdatadir|}');
  if CommandLineDataDirectory <> '' then
    Result := CommandLineDataDirectory
  else
    Result := ExpandConstant('{localappdata}\LeadPilot');
end;

function StopInstalledLeadPilot(InstallDirectory: string): Boolean;
var
  StopScript, MetadataPath, DataDirectory, Parameters: string;
  ResultCode: Integer;
begin
  StopScript := AddBackslash(InstallDirectory) + 'scripts\stop_leadpilot.ps1';
  DataDirectory := PersistentDataDirectory;
  MetadataPath := AddBackslash(DataDirectory) + 'runtime\backend.process.json';
  if not FileExists(StopScript) then begin
    Result := not FileExists(MetadataPath);
    if not Result then
      MsgBox('LeadPilot is running, but its shutdown helper is missing. Repair the installation before continuing.', mbError, MB_OK);
    exit;
  end;

  Parameters := '-NoProfile -ExecutionPolicy Bypass -File "' + StopScript +
    '" -InstallRoot "' + InstallDirectory + '" -DataDirectory "' +
    DataDirectory + '" -StopFrontend';
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Parameters, InstallDirectory, SW_HIDE, ewWaitUntilTerminated, ResultCode) and
    (ResultCode = 0);
  if not Result then
    MsgBox('LeadPilot could not stop its owned processes. Close LeadPilot and try again. User data was not removed.', mbError, MB_OK);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = wpSelectDir then begin
    if PathsOverlap(ExpandConstant('{app}'), ExpandConstant('{localappdata}\LeadPilot')) then begin
      MsgBox('Choose an installation directory outside %LOCALAPPDATA%\LeadPilot. That directory contains persistent user data and must never be replaced or removed with the application.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  CurrentDirectory, PreviousDirectory: string;
begin
  Result := '';
  CurrentDirectory := ExpandConstant('{app}');
  PreviousDirectory := GetPreviousData('InstallDir', '');
  if (PreviousDirectory <> '') and
     (CompareText(TrimTrailingBackslashes(PreviousDirectory), TrimTrailingBackslashes(CurrentDirectory)) <> 0) then begin
    if not StopInstalledLeadPilot(PreviousDirectory) then begin
      Result := 'The previous LeadPilot installation is still running and could not be stopped.';
      exit;
    end;
  end;
  if not StopInstalledLeadPilot(CurrentDirectory) then
    Result := 'LeadPilot could not stop its owned processes before installation.';
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  SetPreviousData(PreviousDataKey, 'InstallDir', ExpandConstant('{app}'));
end;

function InitializeUninstall(): Boolean;
begin
  Result := StopInstalledLeadPilot(ExpandConstant('{app}'));
  if Result then
    MsgBox('LeadPilot application files and shortcuts will be removed. Persistent data under %LOCALAPPDATA%\LeadPilot is preserved.', mbInformation, MB_OK);
end;
