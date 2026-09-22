# Скрипт полной сборки и упаковки дистрибутива tsukiko для Windows.
#
# Шаги:
# 1. Проверяет наличие движка в windows/Engine (или вызывает tool/engine-win.ps1).
# 2. Собирает Flutter приложение: flutter build windows --release.
# 3. Копирует папку Engine в релизный каталог build/windows/x64/runner/Release/.
# 4. Запускает компилятор Inno Setup (ISCC.exe) для создания tsukiko-setup.exe.
# 5. Упаковывает релиз в tsukiko-portable.zip для любителей переносимых версий.

[CmdletBinding()]
param (
    [switch]$SkipEngine
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
Set-Location $RootDir

# Проверяем версию до начала тяжёлой сборки и не используем уже выпущенную.
python "$ScriptDir/version.py" build --platform windows
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$VERSION = python "$ScriptDir/version.py" current
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$BUILD_NUMBER = (Select-String -Path "pubspec.yaml" -Pattern '^version:\s*\d+\.\d+\.\d+\+(\d+)\s*$').Matches[0].Groups[1].Value

$ENGINE_DIR = "windows/Engine"
if (-not $SkipEngine) {
    # Сборок движка две — с Vulkan и без; какую запускать, приложение
    # решает на месте (см. os.engineNames). Имени без суффикса нет.
    if (-not (Test-Path "$ENGINE_DIR/tsukiko-recognizer-cpu.exe") -or
        -not (Test-Path "$ENGINE_DIR/nemo-cpu/bin/nemo-speech.exe") -or
        -not (Test-Path "$ENGINE_DIR/nemo-vulkan/bin/nemo-speech.exe")) {
        Write-Host "Движок не собран, запускаем tool/engine-win.ps1..."
        & "$ScriptDir/engine-win.ps1"
    }
}

Write-Host "Собираем Flutter-приложение для Windows..."
flutter build windows --release

$RELEASE_DIR = "build/windows/x64/runner/Release"
$TARGET_ENGINE = "$RELEASE_DIR/Engine"

Write-Host "Копируем встроенный движок и аудиодекодер в релизную папку..."
if (-not (Test-Path $TARGET_ENGINE)) {
    New-Item -ItemType Directory -Force -Path $TARGET_ENGINE | Out-Null
}
Copy-Item "$ENGINE_DIR/*" $TARGET_ENGINE -Recurse -Force

# Расшифровщик из командной строки: скрипту и нейросетевому агенту нужен
# текст, а не окно. Flutter в него не входит, поэтому dart compile exe
# собирает его отдельно и за секунды. Кладём рядом с tsukiko.exe — так
# его проще найти тому, кто зовёт его снаружи.
Write-Host "Собираем tsukiko-transcribe.exe..."
dart compile exe bin/tsukiko_transcribe.dart -o "$RELEASE_DIR/tsukiko-transcribe.exe"

# Подготовка папки инсталлятора
$OUT_INSTALLER = "build/installer"
if (-not (Test-Path $OUT_INSTALLER)) {
    New-Item -ItemType Directory -Force -Path $OUT_INSTALLER | Out-Null
}

# Версия уже проверена в начале скрипта.
Write-Host "Версия выпуска: $VERSION"

# Без аудиодекодера установщик собирать нельзя: на Windows без него
# не расшифровать ни m4a, ни opus, ни дорожку из видео.
if (-not (Test-Path "$TARGET_ENGINE/ffmpeg.exe")) {
    Write-Error "Нет $TARGET_ENGINE/ffmpeg.exe. Сначала: tool\build-ffmpeg-win.ps1"
    exit 1
}

# Сборка инсталлятора через Inno Setup
$ISCC = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
if (-not $ISCC) {
    $CommonPaths = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
    )
    foreach ($p in $CommonPaths) {
        if (Test-Path $p) {
            $ISCC = $p
            break
        }
    }
}

if ($ISCC) {
    Write-Host "Создаём установщик tsukiko-setup.exe через Inno Setup..."
    & $ISCC "/DMyAppVersion=$VERSION" "/DMyAppBuildNumber=$BUILD_NUMBER" "$ScriptDir/installer.iss"
    Write-Host "Установщик создан: $OUT_INSTALLER/tsukiko-setup.exe"
} else {
    Write-Warning "Inno Setup (ISCC.exe) не найден. Установите Inno Setup для генерации tsukiko-setup.exe."
}

Write-Host "Создаём portable-архив tsukiko-portable.zip..."
$PORTABLE_ZIP = "$OUT_INSTALLER/tsukiko-portable.zip"
if (Test-Path $PORTABLE_ZIP) { Remove-Item $PORTABLE_ZIP -Force }
Compress-Archive -Path "$RELEASE_DIR/*" -DestinationPath $PORTABLE_ZIP -CompressionLevel Optimal
Write-Host "Portable архив создан: $PORTABLE_ZIP"

Write-Host "Готово! Релизные файлы в $OUT_INSTALLER"
