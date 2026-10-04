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
# Также накладываются патчи освобождения памяти и сохранения начальной
# подсказки при отключённой истории распознанного текста, а также
# повторного кодирования первого окна при определении языка.

[CmdletBinding()]
param (
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
Set-Location $RootDir

# Готовые официальные NeMo-бинарники не требуют ни CMake, ни Python.
& "$ScriptDir/nemo-engine-win.ps1" -Force:$Force

$VERSION = "v1.9.3"
$PATCHES = @("tool/recognizer-pcm.patch", "tool/prompt-context.patch", "tool/language-encoder.patch")
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

$PatchHash = ($PATCHES | ForEach-Object {
    (Get-FileHash -Algorithm SHA256 $_).Hash.Substring(0, 6)
}) -join "-"
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

if (-not (Test-Path $TAR)) {
    Write-Host "Скачиваем whisper.cpp $VERSION..."
    $URL = "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/$VERSION.tar.gz"
    Invoke-WebRequest -Uri $URL -OutFile $TAR
}

$DownloadedHash = (Get-FileHash -Algorithm SHA256 $TAR).Hash.ToLower()
if ($DownloadedHash -ne $SHA256.ToLower()) {
    Remove-Item $TAR
    Write-Error "Контрольная сумма архива $TAR не совпала! Ожидалось $SHA256, получено $DownloadedHash"
    exit 1
}

# Новый набор патчей всегда накладывается на чистый архив: иначе локальная
# повторная сборка могла получить новую метку со старым исходным кодом.
if (Test-Path $SRC) {
    Remove-Item $SRC -Recurse -Force
}
tar -xzf $TAR -C $WORK
if ($LASTEXITCODE -ne 0) { throw "Не удалось распаковать whisper.cpp (код $LASTEXITCODE)." }

foreach ($PATCH in $PATCHES) {
    Write-Host "Накладываем патч $PATCH..."
    if (Get-Command "git" -ErrorAction SilentlyContinue) {
        git -C $SRC apply --unidiff-zero "$RootDir/$PATCH"
        if ($LASTEXITCODE -ne 0) { throw "Патч $PATCH не применился (код $LASTEXITCODE)." }
    } elseif (Get-Command "patch" -ErrorAction SilentlyContinue) {
        patch -p1 -d $SRC -i "$RootDir/$PATCH"
        if ($LASTEXITCODE -ne 0) { throw "Патч $PATCH не применился (код $LASTEXITCODE)." }
    } else {
        Write-Error "Для сборки нужна утилита git или patch."
        exit 1
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
if ($LASTEXITCODE -ne 0) { throw "Не удалось настроить Vulkan-сборку (код $LASTEXITCODE)." }

cmake --build $BUILD_VK --config Release --parallel
if ($LASTEXITCODE -ne 0) { throw "Не удалось собрать Vulkan-движок (код $LASTEXITCODE)." }

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
if ($LASTEXITCODE -ne 0) { throw "Не удалось настроить CPU-сборку (код $LASTEXITCODE)." }

cmake --build $BUILD_CPU --config Release --parallel
if ($LASTEXITCODE -ne 0) { throw "Не удалось собрать CPU-движок (код $LASTEXITCODE)." }

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
