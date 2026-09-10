# Скачать официальные нативные сборки NeMo-Speech.cpp для Windows.
# Vulkan используется первым, CPU остаётся гарантированным фоллбэком.
# Python в дистрибутив не входит и для запуска GGUF не нужен.
[CmdletBinding()]
param (
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
Set-Location $RootDir

$VERSION = "0.1.0"
$BASE_URL = "https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v$VERSION"
$ASSETS = @(
    @{
        Name = "nemo-speech-$VERSION-windows-x86_64-vulkan.zip"
        Sha = "b5e7b04a637da4eb25a60253e2db65774998e8dfb48c08b4db763009b82ac7ac"
        Folder = "nemo-vulkan"
    },
    @{
        Name = "nemo-speech-$VERSION-windows-x86_64-cpu.zip"
        Sha = "5e4ea81046012edcd77fd8848de8eefb5a4ba38cc26f52eb544ab184695a75d6"
        Folder = "nemo-cpu"
    }
)
$OUT = "windows/Engine"
$WORK = "build/nemo-engine"
$STAMP = "$OUT/.nemo-version"

if (-not $Force -and (Test-Path $STAMP) -and
    ((Get-Content $STAMP -Raw).Trim() -eq $VERSION) -and
    (Test-Path "$OUT/nemo-vulkan/bin/nemo-speech.exe") -and
    (Test-Path "$OUT/nemo-cpu/bin/nemo-speech.exe")) {
    Write-Host "NeMo-Speech.cpp $VERSION уже подготовлен — $OUT"
    exit 0
}

New-Item -ItemType Directory -Force -Path $OUT, $WORK | Out-Null
foreach ($asset in $ASSETS) {
    $archive = Join-Path $WORK $asset.Name
    if (-not (Test-Path $archive)) {
        Write-Host "Скачиваем NeMo-Speech.cpp $($asset.Name)..."
        Invoke-WebRequest -Uri "$BASE_URL/$($asset.Name)" -OutFile $archive
    }
    $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLower()
    if ($actual -ne $asset.Sha) {
        Remove-Item $archive -Force
        throw "Контрольная сумма $($asset.Name) не совпала: $actual"
    }
    $target = Join-Path $OUT $asset.Folder
    if (Test-Path $target) {
        Remove-Item $target -Recurse -Force
    }
    Expand-Archive -Path $archive -DestinationPath $target -Force
}

Set-Content -Path $STAMP -Value $VERSION -NoNewline
Write-Host "NeMo-Speech.cpp $VERSION подготовлен: Vulkan и CPU, без Python."
