# Собрать движок whisper.cpp для Windows.
#
# Сборка под Windows создаёт два варианта движка:
# 1. Vulkan-сборка (tsukiko-recognizer-vulkan.exe, tsukiko-dictation-vulkan.exe) —
#    аппаратное ускорение на любых современных GPU: NVIDIA, AMD, Intel.
# 2. CPU-сборка (tsukiko-recognizer-cpu.exe, tsukiko-dictation-cpu.exe) —
#    гарантированный фоллбэк на процессоре, если на ПК нет Vulkan-драйвера.
#
# Обе сборки статически линкуются с C-рантаймом (/MT, MultiThreaded),
# поэтому не требуют установленного Visual C++ Redistributable (vcredist).
#
# Также накладывается патч tool/recognizer-pcm.patch для мгновенного
# освобождения оперативной памяти после расчёта спектрограммы звука.

[CmdletBinding()]
param (
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
Set-Location $RootDir

$VERSION = "v1.9.3"
$PATCH = "tool/recognizer-pcm.patch"
$SHA256 = "1650f884effba487025143bd8facd2f9fb40a83b3737a732803c67a8d659d9c0"

$OUT = "windows/Engine"
$WORK = "build/engine"
$STAMP = "$OUT/.version"

if (-not (Test-Path $OUT)) {
    New-Item -ItemType Directory -Force -Path $OUT | Out-Null
}
if (-not (Test-Path $WORK)) {
    New-Item -ItemType Directory -Force -Path $WORK | Out-Null
}

$PatchHash = (Get-FileHash -Algorithm SHA256 $PATCH).Hash.Substring(0, 12)
$STAMPED = "$VERSION $PatchHash"

if (-not $Force -and (Test-Path $STAMP)) {
    $CurrentStamp = (Get-Content $STAMP -Raw).Trim()
    if ($CurrentStamp -eq $STAMPED -and (Test-Path "$OUT/tsukiko-recognizer.exe") -and (Test-Path "$OUT/tsukiko-dictation.exe")) {
        Write-Host "Движок $VERSION уже собран — $OUT"
        exit 0
    }
}

if (-not (Get-Command "cmake" -ErrorAction SilentlyContinue)) {
    Write-Error "Требуется CMake: установите через 'winget install Kitware.CMake' или Visual Studio Installer."
    exit 1
}

$SRC = "$WORK/whisper.cpp-$($VERSION.TrimStart('v'))"
$TAR = "$WORK/$VERSION.tar.gz"

if (-not (Test-Path $SRC)) {
    Write-Host "Скачиваем whisper.cpp $VERSION..."
    $URL = "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/$VERSION.tar.gz"
    Invoke-WebRequest -Uri $URL -OutFile $TAR
    
    $DownloadedHash = (Get-FileHash -Algorithm SHA256 $TAR).Hash.ToLower()
    if ($DownloadedHash -ne $SHA256.ToLower()) {
        Remove-Item $TAR
        Write-Error "Контрольная сумма архива $TAR не совпала! Ожидалось $SHA256, получено $DownloadedHash"
        exit 1
    }
    
    tar -xzf $TAR -C $WORK
    
    Write-Host "Накладываем патч памяти $PATCH..."
    if (Get-Command "git" -ErrorAction SilentlyContinue) {
        git -C $SRC apply "$RootDir/$PATCH"
    } elseif (Get-Command "patch" -ErrorAction SilentlyContinue) {
        patch -p1 -d $SRC -i "$RootDir/$PATCH"
    } else {
        Write-Warning "Утилита patch/git не найдена, пропускаем наложение патча."
    }
}

# ── 1. Сборка Vulkan (основное GPU-ускорение) ──────────────────────────────────
Write-Host "Конфигурируем и собираем Vulkan-версию движка..."
$BUILD_VK = "$SRC/build-vulkan"
cmake -S $SRC -B $BUILD_VK `
    -DCMAKE_BUILD_TYPE=Release `
    -DBUILD_SHARED_LIBS=OFF `
    -DWHISPER_BUILD_TESTS=OFF `
    -DWHISPER_BUILD_SERVER=ON `
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded `
    -DGGML_VULKAN=ON

cmake --build $BUILD_VK --config Release --parallel

# ── 2. Сборка CPU (надежный фоллбэк) ───────────────────────────────────────────
Write-Host "Конфигурируем и собираем процессорную (CPU) версию движка..."
$BUILD_CPU = "$SRC/build-cpu"
cmake -S $SRC -B $BUILD_CPU `
    -DCMAKE_BUILD_TYPE=Release `
    -DBUILD_SHARED_LIBS=OFF `
    -DWHISPER_BUILD_TESTS=OFF `
    -DWHISPER_BUILD_SERVER=ON `
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded `
    -DGGML_VULKAN=OFF

cmake --build $BUILD_CPU --config Release --parallel

# ── 3. Копирование и фиксация ─────────────────────────────────────────────────
Copy-Item "$BUILD_VK/bin/Release/whisper-cli.exe" "$OUT/tsukiko-recognizer-vulkan.exe" -Force
Copy-Item "$BUILD_VK/bin/Release/whisper-server.exe" "$OUT/tsukiko-dictation-vulkan.exe" -Force

Copy-Item "$BUILD_CPU/bin/Release/whisper-cli.exe" "$OUT/tsukiko-recognizer-cpu.exe" -Force
Copy-Item "$BUILD_CPU/bin/Release/whisper-server.exe" "$OUT/tsukiko-dictation-cpu.exe" -Force

# По умолчанию в качестве основного имени выставляем Vulkan:
Copy-Item "$OUT/tsukiko-recognizer-vulkan.exe" "$OUT/tsukiko-recognizer.exe" -Force
Copy-Item "$OUT/tsukiko-dictation-vulkan.exe" "$OUT/tsukiko-dictation.exe" -Force

Copy-Item "$SRC/LICENSE" "$OUT/whisper.cpp-LICENSE.txt" -Force
Set-Content -Path $STAMP -Value $STAMPED -NoNewline

Write-Host "Движок $VERSION для Windows успешно собран:"
Get-ChildItem $OUT -Filter "tsukiko-*.exe" | Select-Object Name, Length
