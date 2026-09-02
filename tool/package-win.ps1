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

$ENGINE_DIR = "windows/Engine"
if (-not $SkipEngine) {
    # Сборок движка две — с Vulkan и без; какую запускать, приложение
    # решает на месте (см. os.engineNames). Имени без суффикса нет.
    if (-not (Test-Path "$ENGINE_DIR/tsukiko-recognizer-cpu.exe")) {
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

# Подготовка папки инсталлятора
$OUT_INSTALLER = "build/installer"
if (-not (Test-Path $OUT_INSTALLER)) {
    New-Item -ItemType Directory -Force -Path $OUT_INSTALLER | Out-Null
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
    & $ISCC "$ScriptDir/installer.iss"
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
