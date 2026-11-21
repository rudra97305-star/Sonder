[Setup]
AppId={{B0256F8E-2C4F-4740-969E-A5C26BDFC24D}
AppName=Sonder
AppVersion=1.1.0
AppPublisher=Sonder
DefaultDirName={localappdata}\Programs\Sonder
DefaultGroupName=Sonder
DisableDirPage=no
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.17763
SetupIconFile={#ArtworkDir}\Sonder.ico
UninstallDisplayIcon={app}\Sonder.exe
WizardStyle=modern dynamic
WizardImageFile={#ArtworkDir}\Wizard.bmp
WizardSmallImageFile={#ArtworkDir}\WizardSmall.bmp
DisableWelcomePage=no
Compression=lzma2/fast
SolidCompression=yes
OutputDir={#InstallerOutputDir}
OutputBaseFilename=Sonder-Setup
CloseApplicationsFilter=Sonder.exe,python.exe
RestartApplications=no
SetupLogging=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Files]
Source: "{#VCRedist}"; DestName: "vc_redist.x64.exe"; Flags: dontcopy noencryption
Source: "{#WebViewBootstrap}"; DestName: "MicrosoftEdgeWebview2Setup.exe"; Flags: dontcopy noencryption
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Excludes: "\.python310\Lib\site-packages\bin\*,tests,__pycache__"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\Sonder"; Filename: "{app}\Sonder.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\Sonder"; Filename: "{app}\Sonder.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\Sonder.exe"; Description: "Launch Sonder"; Flags: postinstall nowait skipifsilent

[Code]
const
  WebViewClient = 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  VCRuntimeKey = 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64';

function HasWebViewVersion(RootKey: Integer): Boolean;
var
  Version: String;
begin
  Result := RegQueryStringValue(RootKey, WebViewClient, 'pv', Version) and
    (Version <> '') and (Version <> '0.0.0.0');
end;

function WebViewInstalled: Boolean;
begin
  Result := HasWebViewVersion(HKLM32) or HasWebViewVersion(HKCU);
end;

function VisualCRuntimeInstalled: Boolean;
var
  Installed, Minor: Cardinal;
begin
  Result := RegQueryDWordValue(HKLM64, VCRuntimeKey, 'Installed', Installed) and
    (Installed = 1) and RegQueryDWordValue(HKLM64, VCRuntimeKey, 'Minor', Minor) and
    (Minor >= 38) and FileExists(ExpandConstant('{sys}\msvcp140.dll'));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  if not WebViewInstalled then
  begin
    Log('Installing Microsoft Edge WebView2 Runtime.');
    ExtractTemporaryFile('MicrosoftEdgeWebview2Setup.exe');
    if not Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'), '/silent /install',
        '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) or not WebViewInstalled then
    begin
      Result := 'Microsoft Edge WebView2 setup could not finish. Check your internet connection and retry.';
      exit;
    end;
  end;

  if not VisualCRuntimeInstalled then
  begin
    Log('Installing Microsoft Visual C++ x64 Runtime.');
    ExtractTemporaryFile('vc_redist.x64.exe');
    if not ShellExec('runas', ExpandConstant('{tmp}\vc_redist.x64.exe'),
        '/install /passive /norestart', '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode) then
      Result := 'Microsoft Visual C++ setup needs administrator approval. Approve the Microsoft installer and retry.'
    else if ResultCode = 3010 then
      NeedsRestart := True
    else if not VisualCRuntimeInstalled then
      Result := 'Microsoft Visual C++ setup could not finish (exit code ' + IntToStr(ResultCode) + ').';
  end;
end;
