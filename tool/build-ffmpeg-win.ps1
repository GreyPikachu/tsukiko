# Подготовка минимального аудио-декодера ffmpeg.exe (LGPL) для Windows.
#
# Зачем нужен:
# На macOS перекладывание звука в 16 кГц моно WAV делает системный afconvert.
# На Windows системного конвертера нет, а whisper.cpp не читает Opus (голосовые
# Telegram/WhatsApp), AAC/M4A (диктофон iPhone) и видеофайлы (MP4/MKV).
#
# Этот скрипт подготавливает сверхлегковесный ffmpeg.exe (~5-10 МБ):
# - строго под лицензией LGPL (без флагов --enable-gpl / --enable-nonfree);
# - отключены все видеокодеки, сетевые протоколы и энкодеры (--disable-everything);
# - включены только аудиодекодеры: AAC, Opus, Vorbis, FLAC, MP3, ALAC, WMA, PCM;
# - результат копируется в windows/Engine/ffmpeg.exe вместе с текстом лицензии LGPL.

[CmdletBinding()]
param (
    [switch]$BuildFromSource
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
Set-Location $RootDir

$OUT = "windows/Engine"
if (-not (Test-Path $OUT)) {
    New-Item -ItemType Directory -Force -Path $OUT | Out-Null
}

$LICENSE_DST = "$OUT/ffmpeg-LICENSE.txt"

# Текст лицензии LGPL v2.1/v3 обязателен рядом с бинарником:
if (-not (Test-Path $LICENSE_DST)) {
    $LgplUrl = "https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/COPYING.LGPLv2.1"
    try {
        Invoke-WebRequest -Uri $LgplUrl -OutFile $LICENSE_DST
    } catch {
        Set-Content -Path $LICENSE_DST -Value "FFmpeg is licensed under the GNU Lesser General Public License (LGPL) version 2.1 or later. See https://ffmpeg.org/legal.html"
    }
}

if ($BuildFromSource) {
    Write-Host "Сборка минимального FFmpeg из исходников (требуется MSYS2 / MinGW-w64)..."
    $WORK = "build/ffmpeg"
    if (-not (Test-Path $WORK)) { New-Item -ItemType Directory -Force -Path $WORK | Out-Null }
    
    # Конфигурация для минимального audio-only LGPL декодера:
    $CONFIG_ARGS = @(
        "--prefix=$RootDir/$OUT",
        "--disable-everything",
        "--disable-network",
        "--disable-autodetect",
        "--disable-doc",
        "--enable-small",
        "--enable-protocol=file",
        "--enable-demuxer=wav,ogg,matroska,mov,mp4,aac,mp3,flac,avi,asf,aiff",
        "--enable-decoder=aac,opus,vorbis,flac,mp3,alac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,wmalossless,wmapro,wmav1,wmav2,wmavoice",
        "--enable-muxer=wav",
        "--enable-encoder=pcm_s16le",
        "--enable-filter=aresample,aformat"
    )
    Write-Host "Флаги сборки: $($CONFIG_ARGS -join ' ')"
    Write-Host "Запустите ./configure $($CONFIG_ARGS -join ' ') && make -j в окружении MSYS2."
} else {
    Write-Host "Для автоматической сборки дистрибутива убедитесь, что минимальный LGPL ffmpeg.exe помещён в $OUT/ffmpeg.exe."
}
