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
    if ($CurrentStamp -eq $STAMPED -and (Test-Path "$OUT/tsukiko-recognizer-cpu.exe") -and (Test-Path "$OUT/tsukiko-dictation-cpu.exe")) {
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
# Собирается под любой процессор, а не под тот, на котором собирали.
#
# GGML_NATIVE по умолчанию включён и значит «оптимизировать под эту
# машину». Собираем мы на раннере GitHub, а там серверные Xeon с AVX-512,
# которых на обычном компьютере нет. Такой бинарник печатает версию
# и умирает на первой же настоящей арифметике — сразу после «loading
# model from», с кодом 0xC0000409. Ни модель, ни видеокарта тут ни при
# чём: падают обе сборки на любой модели.
#
# базовый набор инструкций, то есть без AVX2 на машинах, где
# он есть. Быстрее было бы GGML_BACKEND_DL=ON + GGML_CPU_ALL_VARIANTS=ON —
# тогда ggml кладёт рядом несколько библиотек и выбирает лучшую на месте.
# Это стоит отдельных файлов рядом с бинарником; браться за это имеет
# смысл, если процессорный путь окажется узким местом. Основную работу
# всё равно делает Vulkan.
cmake -S $SRC -B $BUILD_VK `
    -DCMAKE_BUILD_TYPE=Release `
    -DGGML_NATIVE=OFF `
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
    -DGGML_NATIVE=OFF `
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

# Третьей копии под именем без суффикса не делаем. Выбирает приложение,
# и выбирает по делу: Vulkan-сборку Windows убивает на запуске, если
# в системе нет vulkan-1.dll (её кладут драйверы видеокарты), — тогда
# берётся процессорная. Копия «на всякий случай» только раздула бы
# установщик на лишние мегабайты и подменяла бы этот выбор.

Copy-Item "$SRC/LICENSE" "$OUT/whisper.cpp-LICENSE.txt" -Force
Set-Content -Path $STAMP -Value $STAMPED -NoNewline

Write-Host "Движок $VERSION для Windows успешно собран:"
Get-ChildItem $OUT -Filter "tsukiko-*.exe" | Select-Object Name, Length
