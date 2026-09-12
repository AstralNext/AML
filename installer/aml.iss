; AML — Windows 安装包（Inno Setup 6）
; CI：.github/workflows/build.yml 在 flutter build 后调用 ISCC。
;
;   ISCC installer\aml.iss /DMyAppVersion=1.0.0
;
; 输出：aml-{MyAppVersion}-windows-x64-setup.exe

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#define MyAppName "AML"
#define MyAppPublisher "AstralNext"
#define MyAppURL "https://aml.astral.fan/"
#define MyAppExeName "aml.exe"
#define BuildOutput "..\build\windows\x64\runner\Release"

[Setup]
AppId={{B7E4A91C-3D52-4F8A-9C16-E2A8B5D07F43}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ChangesAssociations=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern
SolidCompression=yes
Compression=lzma2/ultra64
CloseApplications=yes
SetupIconFile=..\assets\icon.ico
OutputDir=Output
OutputBaseFilename=aml-{#MyAppVersion}-windows-x64-setup
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Setup
VersionInfoProductName={#MyAppName}

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#BuildOutput}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb"

[Registry]
Root: HKA; Subkey: "Software\Classes\aml"; ValueType: string; ValueName: ""; ValueData: "URL:AML Protocol"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\aml"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\aml\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"
Root: HKA; Subkey: "Software\Classes\aml\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
