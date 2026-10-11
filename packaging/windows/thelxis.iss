; Inno Setup script for the Thelxis Windows installer.
;
; Built in CI (.github/workflows/build.yml) with:
;   ISCC /DMyAppVersion=0.1.0 /DMyAppVersionInfo=0.1.0.0 /DSourceDir=<Flutter Release dir>
;        /DOutputDir=<dir> /DOutputBaseFilename=Thelxis-0.1.0-windows-x64-setup thelxis.iss
; Every define has a default so the script also compiles by hand after `flutter build windows`.
;
; Silent self-update (what the in-app updater runs):
;   Thelxis-<ver>-windows-x64-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /RELAUNCH
; /RELAUNCH is our own switch: once the install finished, start the new thelxis.exe with --updated.

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef MyAppVersionInfo
  #define MyAppVersionInfo "0.0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\app\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "Thelxis-" + MyAppVersion + "-windows-x64-setup"
#endif

#define MyAppName "Thelxis"
#define MyAppPublisher "Thelxis"
#define MyAppURL "https://github.com/sibawal/thelxis"
#define MyAppExeName "thelxis.exe"

; "x64compatible" (also allows Windows on ARM, which emulates x64) needs Inno Setup 6.3+.
#if Ver >= 0x06030000
  #define ArchAllowed "x64compatible"
#else
  #define ArchAllowed "x64"
#endif

[Setup]
; Fixed forever: this GUID is how a newer installer finds and upgrades an existing install in place.
AppId={{6F1B2C84-3D5A-4E97-9B0C-7A8E2D4F1C63}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
VersionInfoVersion={#MyAppVersionInfo}
VersionInfoProductName={#MyAppName}
VersionInfoDescription={#MyAppName} Setup
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed={#ArchAllowed}
ArchitecturesInstallIn64BitMode={#ArchAllowed}
MinVersion=10.0
; Admin is required for Program Files and for the Windows Firewall rules below.
PrivilegesRequired=admin
; Name of the single-instance mutex created in app/windows/runner/main.cpp. Setup refuses to run (or waits)
; while the app is open; the in-app updater exits the app right after starting Setup.
AppMutex=Local\io.thelxis.app.single-instance
CloseApplications=force
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
#if FileExists(CompilerPath + "Languages\Russian.isl")
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
#endif

[CustomMessages]
english.AutoStart=Start {#MyAppName} when Windows starts
english.StartupGroup=Startup:
#if FileExists(CompilerPath + "Languages\Russian.isl")
russian.AutoStart=Запускать {#MyAppName} при старте Windows
russian.StartupGroup=Автозапуск:
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "{cm:AutoStart}"; GroupDescription: "{cm:StartupGroup}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; Same per-user Run key the app's own "Start with Windows" switch uses (value name "Thelxis").
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#MyAppName}"; ValueData: """{app}\{#MyAppExeName}"" --minimized"; Flags: uninsdeletevalue; Tasks: autostart

[Run]
; Inbound Windows Firewall rules, scoped to thelxis.exe. Ports: 47100/tcp signaling, 47101/tcp TURN over TCP,
; 47100/udp embedded STUN/TURN, 47102/udp LAN discovery. Delete first so upgrades never stack duplicates.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Thelxis TCP"""; Flags: runhidden; StatusMsg: "Configuring Windows Firewall..."
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Thelxis UDP"""; Flags: runhidden; StatusMsg: "Configuring Windows Firewall..."
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Thelxis TCP"" dir=in action=allow enable=yes profile=any protocol=TCP localport=47100-47101 program=""{app}\{#MyAppExeName}"""; Flags: runhidden; StatusMsg: "Configuring Windows Firewall..."
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Thelxis UDP"" dir=in action=allow enable=yes profile=any protocol=UDP localport=47100,47102 program=""{app}\{#MyAppExeName}"""; Flags: runhidden; StatusMsg: "Configuring Windows Firewall..."
; Interactive install: the usual "Launch Thelxis" checkbox on the last page.
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
; Silent self-update (/RELAUNCH): start the new version as the logged-in user (not elevated), no checkbox involved.
Filename: "{app}\{#MyAppExeName}"; Parameters: "--updated"; Flags: nowait runasoriginaluser; Check: RelaunchRequested

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#MyAppExeName}"; Flags: runhidden; RunOnceId: "StopThelxis"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Thelxis TCP"""; Flags: runhidden; RunOnceId: "DelFirewallTcp"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Thelxis UDP"""; Flags: runhidden; RunOnceId: "DelFirewallUdp"

[Code]
function RelaunchRequested: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/RELAUNCH') = 0 then
    begin
      Result := True;
      Exit;
    end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  // Also drop the Run entry when it was created by the app's own startup switch rather than by this installer.
  if CurUninstallStep = usPostUninstall then
    RegDeleteValue(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', '{#MyAppName}');
end;
