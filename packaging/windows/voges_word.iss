#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppExe "voges_word.exe"
#define ProgId "VogesWord.Document"

[Setup]
AppId={{237302D4-CF82-4A6D-B1A5-F3E8C553542A}
ShowLanguageDialog=auto
AppName=Voges Word
AppVersion={#AppVersion}
AppPublisher=omanoloneto
AppPublisherURL=https://omanoloneto.pro/voges/word/
AppSupportURL=https://github.com/omanoloneto/voges-word/issues
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\Voges Word
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
ChangesAssociations=yes
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName=Voges Word
OutputDir=..\..\build\installer
OutputBaseFilename=VogesWord-windows-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[CustomMessages]
english.DocumentTypeName=Voges Word Document
brazilianportuguese.DocumentTypeName=Documento do Voges Word
spanish.DocumentTypeName=Documento de Voges Word

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Voges Word"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\Voges Word"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; adds the app to "Open with" for .docx and .txt without making it the default program
Root: HKA; Subkey: "Software\Classes\{#ProgId}"; ValueType: string; ValueData: "{cm:DocumentTypeName}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\{#ProgId}\DefaultIcon"; ValueType: string; ValueData: "{app}\{#AppExe},0"
Root: HKA; Subkey: "Software\Classes\{#ProgId}\shell\open\command"; ValueType: string; ValueData: """{app}\{#AppExe}"" ""%1"""
Root: HKA; Subkey: "Software\Classes\.docx\OpenWithProgids"; ValueType: string; ValueName: "{#ProgId}"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.txt\OpenWithProgids"; ValueType: string; ValueName: "{#ProgId}"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\{#AppExe}"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "Voges Word"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Applications\{#AppExe}\SupportedTypes"; ValueType: string; ValueName: ".docx"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\{#AppExe}\SupportedTypes"; ValueType: string; ValueName: ".txt"; ValueData: ""

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,Voges Word}"; Flags: nowait postinstall skipifsilent
