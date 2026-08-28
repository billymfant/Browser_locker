; Browser Locker installer.
;
; Installs to Program Files, which is deliberate and not just convention: the
; scheduled task runs a script from here with administrator rights, so a
; location non-administrators can write to would hand them code execution as
; admin. Setup reads the ACL back and refuses to continue if it is wrong.
;
; Build:  iscc build\BraveLocker.iss   (or build\Build.ps1)

#define AppName        "Browser Locker"
#define AppVersion     "1.0.0"
#define AppPublisher   "Browser Locker"
#define AppExeName     "BrowserLocker.cmd"

[Setup]
AppId={{7E2F1C64-9A3D-4B8E-9C21-5D6A0F4B77E1}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\BrowserLocker
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=BrowserLockerSetup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Administrator, not lowest: creating a VHDX, enabling BitLocker and
; registering the mount task all require it.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#AppName}
; Windows 10 1809 / Windows 11. Older builds are untested.
MinVersion=10.0.17763

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\src\*";     DestDir: "{app}\src";     Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\scripts\*"; DestDir: "{app}\scripts"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\gui\*";     DestDir: "{app}\gui";     Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\README.md"; DestDir: "{app}";         Flags: ignoreversion
Source: "..\docs\*";    DestDir: "{app}\docs";    Flags: ignoreversion recursesubdirs createallsubdirs
Source: "BrowserLocker.cmd"; DestDir: "{app}";    Flags: ignoreversion

[Icons]
Name: "{group}\Browser Locker Setup";  Filename: "{app}\{#AppExeName}"
Name: "{group}\Read me";             Filename: "{app}\README.md"
Name: "{group}\Uninstall Browser Locker"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Set up Browser Locker now"; Flags: postinstall nowait skipifsilent

[UninstallRun]
; Undo the machine changes - restore Brave's shortcuts, remove the scheduled
; task, put the profile back - BEFORE the files needed to do that are deleted.
; It refuses if the vault is the only copy of the user's data.
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Uninstall-BraveLocker.ps1"" -Force"; \
  Flags: runhidden waituntilterminated; RunOnceId: "BraveLockerUndo"

[Code]
function InitializeSetup(): Boolean;
var
  Edition: String;
begin
  Result := True;

  // BitLocker does not exist on Windows Home. Say so here rather than let
  // someone get most of the way through and fail with a half-built vault.
  RegQueryStringValue(HKEY_LOCAL_MACHINE,
    'SOFTWARE\Microsoft\Windows NT\CurrentVersion', 'EditionID', Edition);

  if (Pos('Core', Edition) = 1) then
  begin
    MsgBox('Browser Locker needs Windows Pro, Enterprise or Education.'#13#10#13#10
         + 'This PC is running a Home edition, which does not include BitLocker, '
         + 'and Browser Locker has no way to encrypt the vault without it.'#13#10#13#10
         + 'Nothing has been changed on your PC.',
      mbCriticalError, MB_OK);
    Result := False;
  end;
end;
