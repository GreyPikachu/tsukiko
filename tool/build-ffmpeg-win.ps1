# Аудиодекодер для Windows: проверка и указание, чем его собрать.
#
# Сама сборка — в tool/build-ffmpeg.sh: у ffmpeg своей сборочной среды
# в духе Unix нет, configure это обычный шелл-скрипт, и запускать его
# надо в MSYS2. Держать два описания одной сборки — верный способ
# развести их при первой же правке, поэтому здесь только проверка.
#
# Зачем декодер нужен: whisper читает сам только wav, mp3, flac и ogg
# с Vorbis. А в разговор приходит другое — голосовые из мессенджеров
# (Opus в ogg), записи с диктофона (AAC в m4a), дорожки из видео.
# На macOS их перекладывает системный afconvert, на Windows системного
# конвертера нет, а Media Foundation не читает Opus в ogg без отдельного
# расширения из магазина.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$RootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $RootDir

$OUT = "windows/Engine"

if (Test-Path "$OUT/ffmpeg.exe") {
    $size = [math]::Round((Get-Item "$OUT/ffmpeg.exe").Length / 1MB, 1)
    Write-Host "Аудиодекодер на месте: $OUT/ffmpeg.exe ($size МБ)"
    exit 0
}

Write-Error @"
Нет $OUT/ffmpeg.exe — без него Windows не расшифрует голосовые (Opus),
записи с диктофона (m4a) и дорожки из видео.

Соберите его в MSYS2 (mingw64):

    ./tool/build-ffmpeg.sh

Это же делает сборка на GitHub — .github/workflows/windows.yml, — и
результат там кладётся в кэш, так что собирается он один раз.
"@
exit 1
