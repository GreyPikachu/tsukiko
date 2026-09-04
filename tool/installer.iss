; Установщик tsukiko для Windows (Inno Setup 6).
;
; Двойник macOS-образа (`tool/dmg.sh`): там открытое окно сразу говорит,
; что за программа и что с ней делать. Здесь то же самое средствами
; мастера — свой значок, своя картинка, русский язык по умолчанию.
;
; Три решения, которые иначе выглядели бы прихотью:
;
; 1. PrivilegesRequired=lowest — установка в профиль пользователя
;    ({localappdata}\Programs\tsukiko), без UAC и без прав администратора.
;    Приложению они не нужны ни для чего: ни драйверов, ни служб.
;
; 2. AppMutex — тот же мьютекс, которым приложение ловит вторую свою
;    копию (см. windows/runner/main.cpp). Без него установщик и деинсталлятор
;    честно копировали и удаляли файлы поверх работающей программы: часть
;    файлов оставалась занятой, папка не убиралась, значок висел в трее,
;    а в «Пуске» оставался ярлык на пустое место.
;
; 3. Папку для моделей при установке не спрашиваем. Разбор — в
;    docs/задача-установка-и-удаление.md.

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
; Обратный домен приложения. Обязан совпадать с bundleId из
; lib/platform/os.dart: по нему называется папка с настройками и моделями,
; и деинсталлятор ищет её именно там.
#define BundleId "app.yuko.tsukiko"

[Setup]
AppId={{E5D48316-2F10-4A59-B817-5735160E21D0}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
VersionInfoVersion={#MyAppVersion}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
DisableProgramGroupPage=yes
; Установка без прав администратора:
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; Мьютекс тот же, что и в приложении: пока оно работает, ни ставить
; поверх, ни удалять нельзя — иначе останутся занятые файлы.
AppMutex=TsukikoAppSingleInstanceMutex
CloseApplications=yes
RestartApplications=no
OutputDir=..\build\installer
OutputBaseFilename=tsukiko-setup
; Значок установщика — только .ico: Inno Setup другого формата не берёт
; и на .webp просто не соберётся.
SetupIconFile=..\windows\runner\resources\app_icon.ico
; Картинки мастера рисует tool/installer-images.py. Списком, а не парой:
; Inno Setup берёт из него ближайшую к нынешнему масштабу экрана и
; растягивает своим простым растяжением. Пока размеров было два, на
; всяком другом масштабе растягивать приходилось сильно — отсюда и мыло.
; Набор ниже тот же, в каком Inno поставляет свои собственные картинки,
; так что на любом обычном масштабе растягивать почти нечего.
WizardImageFile=..\design\installer-banner-164x314.bmp,..\design\installer-banner-192x386.bmp,..\design\installer-banner-292x534.bmp,..\design\installer-banner-386x690.bmp,..\design\installer-banner-423x797.bmp,..\design\installer-banner-637x1200.bmp
WizardSmallImageFile=..\design\installer-logo-55x58.bmp,..\design\installer-logo-64x68.bmp,..\design\installer-logo-92x97.bmp,..\design\installer-logo-119x123.bmp,..\design\installer-logo-128x132.bmp,..\design\installer-logo-138x140.bmp,..\design\installer-logo-192x192.bmp
WizardImageStretch=yes
; Значок в шапке лежит 32-битным BMP с прозрачностью, и «defined» значит,
; что цвет в нём не помножен на альфу заранее. Без этой строки Inno
; прозрачность просто не смотрит, и раньше под значок приходилось класть
; белую подложку — а в тёмном виде мастера (ниже) она была бы дырой.
WizardImageAlphaFormat=defined
Compression=lzma2/ultra64
SolidCompression=yes
; Вид мастера. «modern» — белое поле страницы вместо серого; «dynamic» —
; светлый или тёмный вид вслед за настройкой самой Windows.
;
; Это и есть предел того, что Inno Setup позволяет менять во внешнем виде
; директивами: набор готовых видов (classic/modern, светлый/тёмный/по
; системе, плюс несколько встроенных раскрасок вроде polar и slate),
; картинки, значок и размер окна. Своих цветов и шрифтов у мастера нет —
; их можно навязать только из [Code], разбирая внутренности WizardForm,
; и такое ломается на каждом обновлении Inno и на каждом нестандартном
; масштабе экрана. Мы туда не лезем.
WizardStyle=modern dynamic
; Первая страница мастера. Inno Setup 6 по умолчанию её выключает — и
; вместе с ней пропадали и наша большая картинка (она оставалась только
; на последней странице), и написанный тут же WelcomeLabel2, который
; больше негде показать. Ставим явно.
DisableWelcomePage=no
; Окно мастера крупнее стандартного. Оно рассчитано на 1996 год, и на
; нынешнем экране картинка в нём выходит с почтовую марку; 120% — это
; всё ещё окно установщика, а не витрина.
WizardSizePercent=120

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
russian.WelcomeLabel2=Программа установит {#MyAppName} {#MyAppVersion} на этот компьютер.%n%nРасшифровка аудио и диктовка. Всё считается на этой машине: ни записи, ни текст никуда не уходят.
english.WelcomeLabel2=Setup will install {#MyAppName} {#MyAppVersion} on your computer.%n%nAudio transcription and dictation. Everything is computed locally: neither recordings nor text ever leave this machine.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "startup"; Description: "{cm:AutoStartProgram,{#MyAppName}}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Всё содержимое релизной папки Flutter (исполняемый файл, flutter_windows.dll, папка data, Engine)
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; Автозапуск. Ту же запись правит сама программа (SetLoginItemEnabled
; в dictation_bridge.cpp), поэтому здесь она заводится только по галке,
; а вот убирается — всегда: без uninsdeletevalue после удаления в реестре
; оставалась строка, которая каждый вход в систему пыталась запустить
; несуществующий файл.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: string; ValueName: "{#MyAppName}"; \
    ValueData: """{app}\{#MyAppExeName}"" --login-item"; \
    Flags: uninsdeletevalue; Tasks: startup
; Вторая запись ничего не делает при установке — она нужна ради
; `uninsdeletevalue`. Без неё удаление вычищало бы автозапуск только
; у тех, кто поставил галку в мастере; а включить его можно и потом,
; из настроек самой программы, — и тогда строка оставалась бы в реестре
; навсегда. Обновлению поверх она при этом не мешает: галку человека
; здесь никто не трогает.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: none; ValueName: "{#MyAppName}"; \
    Flags: uninsdeletevalue dontcreatekey
; След, который оставляет не программа, а сама Windows: «помощник
; по совместимости» запоминает всякий запущенный exe. Своё имя из этого
; списка убираем — иначе после удаления в реестре остаётся мусор с путём
; к файлу, которого больше нет.
Root: HKCU; Subkey: "Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store"; \
    ValueType: none; ValueName: "{app}\{#MyAppExeName}"; \
    Flags: uninsdeletevalue deletevalue dontcreatekey

[UninstallRun]
; Пояс сверх подтяжек. AppMutex не даст удалять при работающей программе,
; но движок мог пережить её падение: полтора гигабайта модели держит
; отдельный процесс, и он бы не дал стереть свою папку.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM tsukiko-dictation-vulkan.exe"; Flags: runhidden skipifdoesntexist; RunOnceId: "KillDictationVk"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM tsukiko-dictation-cpu.exe"; Flags: runhidden skipifdoesntexist; RunOnceId: "KillDictationCpu"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM tsukiko-recognizer-vulkan.exe"; Flags: runhidden skipifdoesntexist; RunOnceId: "KillRecognizerVk"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM tsukiko-recognizer-cpu.exe"; Flags: runhidden skipifdoesntexist; RunOnceId: "KillRecognizerCpu"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#MyAppExeName}"; Flags: runhidden skipifdoesntexist; RunOnceId: "KillApp"

[UninstallDelete]
; Папка приложения после удаления файлов остаётся с пустыми подпапками
; от Flutter — убираем её целиком.
Type: filesandordirs; Name: "{app}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
{ ── что спросить при удалении ───────────────────────────────────────────
  Своё — файлы программы, ярлыки, запись в автозапуске — убираем всегда
  и молча: это наш мусор. Чужое — скачанные модели и папка с расшифровками
  — не наше. Спрашиваем, и по умолчанию отвечаем «нет»: полтора гигабайта
  качаются полчаса, а расшифровки человек делал сам.

  Отдельными вопросами, а не одним: модели можно выбросить и оставить
  расшифровки, и наоборот. }

function ModelsDir(): string;
begin
  Result := ExpandConstant('{userappdata}\{#BundleId}\models');
end;

function SupportDir(): string;
begin
  Result := ExpandConstant('{userappdata}\{#BundleId}');
end;

function LibraryDir(): string;
begin
  Result := ExpandConstant('{userdocs}\{#MyAppName}');
end;

{ Сколько весит папка со всем, что в ней лежит. Нужно затем, чтобы
  вопрос был не «удалить модели?», а «удалить 3,1 ГБ моделей?» —
  на второй вопрос человек отвечает осознанно. }
function DirSize(const Dir: string): Int64;
var
  Found: TFindRec;
begin
  Result := 0;
  if not FindFirst(Dir + '\*', Found) then
    Exit;
  try
    repeat
      if (Found.Name = '.') or (Found.Name = '..') then
        Continue;
      if (Found.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
        Result := Result + DirSize(Dir + '\' + Found.Name)
      else
        { Умножением, а не сдвигом: Pascal Script сдвигает 32-битное. }
        Result := Result + Int64(Found.SizeHigh) * 4294967296 + Int64(Found.SizeLow);
    until not FindNext(Found);
  finally
    FindClose(Found);
  end;
end;

function HumanSize(Bytes: Int64): string;
begin
  if Bytes >= 1073741824 then
    Result := Format('%.1f ГБ', [Bytes / 1073741824.0])
  else
    Result := Format('%d МБ', [Bytes div 1048576]);
end;

{ Настройки без программы бесполезны, но и весят они килобайты: убираем
  их всегда, а модели — только если разрешили. Поэтому не «снести папку
  целиком», а по именам. }
procedure RemoveOurSettings();
begin
  DeleteFile(SupportDir() + '\settings.json');
  DeleteFile(SupportDir() + '\dictation.json');
  DeleteFile(SupportDir() + '\whisper-server.pid');
  DelTree(SupportDir() + '\bin', True, True, True);
  { Пустую папку убираем, непустую (остались модели) — оставляем как есть. }
  RemoveDir(SupportDir());
end;

procedure CurUninstallStepChanged(CurStep: TUninstallStep);
var
  Size: Int64;
begin
  if CurStep <> usPostUninstall then
    Exit;

  if DirExists(ModelsDir()) then
  begin
    Size := DirSize(ModelsDir());
    if Size > 0 then
      if SuppressibleMsgBox(
           'Удалить скачанные модели распознавания?' + #13#10#13#10 +
           ModelsDir() + #13#10 +
           'Занимают ' + HumanSize(Size) + '.' + #13#10#13#10 +
           'Если tsukiko ставится заново или обновляется, модели лучше '
           + 'оставить: качать их заново — это полчаса.',
           mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES then
        DelTree(ModelsDir(), True, True, True);
  end;

  RemoveOurSettings();

  if DirExists(LibraryDir()) then
  begin
    Size := DirSize(LibraryDir());
    if SuppressibleMsgBox(
         'Удалить папку с расшифровками и записями?' + #13#10#13#10 +
         LibraryDir() + #13#10 +
         'Занимает ' + HumanSize(Size) + '.' + #13#10#13#10 +
         'Это сделанная вами работа, а не файлы программы. '
         + 'Мы её не трогаем, пока вы не скажете.',
         mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES then
      DelTree(LibraryDir(), True, True, True);
  end;
end;
