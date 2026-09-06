; hermes-ui.iss
; Inno Setup script for HermesUI Windows x64 Desktop Installer
; All characters and comments in this file are strictly ASCII (project requirement).

#define MyAppName "HermesUI"
#ifndef MyAppVersion
#define MyAppVersion "0.1.17"
#endif
#define MyAppPublisher "silent-reader-cn"
#define MyAppURL "https://github.com/silent-reader-cn/hermes-ui"
#define MyAppExeName "hermes_ui.exe"

[Setup]
; Fixed GUID for upgrade continuity; prevents duplicate installs across versions
AppId={{8B41253C-9A5C-4B74-8C37-A3C8B7E20E21}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=LICENSE.txt
OutputDir=..\build\installer
OutputBaseFilename=HermesUI-{#MyAppVersion}-x64-setup
SetupIconFile=app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
; NOTE: there is no such [Setup] directive as ConfirmUninstall in any Inno Setup
; release (compiler rejects it). The uninstall confirmation is fully taken over
; by InitializeUninstall() below, which shows a custom dialog with the
; "also remove logs and WebUI state data" checkbox.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Main Flutter application runner binaries -> {app}
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

; Bundled WebUI sidecar runtime and source -> {app}\webui
Source: "..\build\webui-bundle\*"; DestDir: "{app}\webui"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
var
  DeleteUserDataCheckbox: TNewCheckBox;
  ShouldDeleteUserData: Boolean;

function InitializeUninstall(): Boolean;
var
  ConfirmForm: TSetupForm;
  PromptLabel: TLabel;
  YesBtn, NoBtn: TNewButton;
begin
  Result := False;
  ShouldDeleteUserData := False;

  // Silent uninstallation keeps logs and user data by default
  if UninstallSilent then
  begin
    Result := True;
    Exit;
  end;

  // Inno Setup >= 6.5 changed the CreateCustomForm prototype: size is passed
  // as arguments (client width, client height, keep size X, center on show).
  ConfirmForm := CreateCustomForm(ScaleX(440), ScaleY(180), False, True);
  ConfirmForm.Caption := 'Uninstall ' + '{#MyAppName}';

  PromptLabel := TLabel.Create(ConfirmForm);
  PromptLabel.Parent := ConfirmForm;
  PromptLabel.Left := ScaleX(20);
  PromptLabel.Top := ScaleY(20);
  PromptLabel.Width := ScaleX(400);
  PromptLabel.Height := ScaleY(40);
  PromptLabel.AutoSize := False;
  PromptLabel.WordWrap := True;
  PromptLabel.Caption := 'Are you sure you want to completely remove ' + '{#MyAppName}' + ' and all of its components?';

  DeleteUserDataCheckbox := TNewCheckBox.Create(ConfirmForm);
  DeleteUserDataCheckbox.Parent := ConfirmForm;
  DeleteUserDataCheckbox.Left := ScaleX(20);
  DeleteUserDataCheckbox.Top := ScaleY(75);
  DeleteUserDataCheckbox.Width := ScaleX(400);
  DeleteUserDataCheckbox.Height := ScaleY(24);
  DeleteUserDataCheckbox.Caption := 'Also remove logs and WebUI state data';
  DeleteUserDataCheckbox.Checked := False;

  YesBtn := TNewButton.Create(ConfirmForm);
  YesBtn.Parent := ConfirmForm;
  YesBtn.Left := ScaleX(250);
  YesBtn.Top := ScaleY(130);
  YesBtn.Width := ScaleX(80);
  YesBtn.Height := ScaleY(26);
  YesBtn.Caption := '&Yes';
  YesBtn.ModalResult := mrYes;
  YesBtn.Default := True;

  NoBtn := TNewButton.Create(ConfirmForm);
  NoBtn.Parent := ConfirmForm;
  NoBtn.Left := ScaleX(340);
  NoBtn.Top := ScaleY(130);
  NoBtn.Width := ScaleX(80);
  NoBtn.Height := ScaleY(26);
  NoBtn.Caption := '&No';
  NoBtn.ModalResult := mrNo;
  NoBtn.Cancel := True;

  if ConfirmForm.ShowModal = mrYes then
  begin
    ShouldDeleteUserData := DeleteUserDataCheckbox.Checked;
    Result := True;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  LogsDir: String;
  StateDir: String;
  AppDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    // Delete logs and state data only if user checked the option
    if ShouldDeleteUserData then
    begin
      LogsDir := ExpandConstant('{localappdata}\hermes\webui-bundled');
      if DirExists(LogsDir) then
      begin
        DelTree(LogsDir, True, True, True);
      end;

      StateDir := ExpandConstant('{localappdata}\hermes\webui');
      if DirExists(StateDir) then
      begin
        DelTree(StateDir, True, True, True);
      end;
    end;

    // Clean up any remaining files in the installation directory
    AppDir := ExpandConstant('{app}');
    if DirExists(AppDir) then
    begin
      DelTree(AppDir, True, True, True);
    end;
  end;
end;
