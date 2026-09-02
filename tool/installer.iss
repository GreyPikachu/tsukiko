; Скрипт Inno Setup для создания установщика tsukiko на Windows.
;
; Особенности:
; 1. PrivilegesRequired=lowest — установка строго в профиль текущего пользователя
;    ({localappdata}\Programs\tsukiko) БЕЗ требования прав администратора и БЕЗ UAC.
; 2. Алгоритм сжатия LZMA2 Ultra упаковывает Flutter runtime, движок whisper.cpp
;    и аудиоконвертер в единый компактный установочный файл tsukiko-setup.exe.
; 3. Бесшовное обновление поверх установленной копии с сохранением пользовательских
;    настроек и загруженных моделей в %APPDATA%\app.yuko.tsukiko.

#define MyAppName "tsukiko"
; Версию передаёт tool\package-win.ps1 ключом /DMyAppVersion — он читает
; её из pubspec.yaml. Значение ниже нужно лишь тому, кто запускает ISCC
; руками: третий список версий рядом с pubspec.yaml и os.dart разошёлся бы
; на первом же выпуске.
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#define MyAppPublisher "Yuko"
#define MyAppExeName "tsukiko.exe"
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{E5D48316-2F10-4A59-B817-5735160E21D0}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
DisableProgramGroupPage=yes
; Установка без прав администратора:
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\build\installer
OutputBaseFilename=tsukiko-setup
; Значок установщика — только .ico: Inno Setup другого формата не берёт
; и на .webp просто не соберётся.
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Всё содержимое релизной папки Flutter (исполняемый файл, flutter_windows.dll, папка data, Engine)
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
