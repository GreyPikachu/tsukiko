#!/bin/sh
# Собрать минимальный ffmpeg для Windows — тот, что перекладывает звук
# в WAV перед распознаванием.
#
# Зачем он вообще нужен: whisper читает сам только wav, mp3, flac и ogg
# с Vorbis. А в разговор приходит другое — голосовые из мессенджеров
# (Opus в ogg), записи с диктофона (AAC в m4a), дорожки из видео.
# На macOS их перекладывает системный afconvert, на Windows системного
# конвертера нет.
#
# Media Foundation не выручает: Opus в ogg она без отдельного расширения
# из магазина не читает, а расширение ставится не у всех. Проверено
# по документации Microsoft, а не по догадке.
#
# Строго LGPL: ни --enable-gpl, ни --enable-nonfree. Иначе класть его
# внутрь приложения стало бы нельзя.
#
# Запускать в MSYS2 (mingw64). В CI это делает .github/workflows/windows.yml,
# руками — так же, той же командой.
set -e
cd "$(dirname "$0")/.."

VERSION=7.1.5
SHA=de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f

OUT=windows/Engine
WORK=build/ffmpeg
STAMP="$OUT/.ffmpeg-version"

if [ "$1" != "--force" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$VERSION" ] &&
  [ -f "$OUT/ffmpeg.exe" ]; then
  echo "ffmpeg $VERSION уже собран — $OUT"
  exit 0
fi

mkdir -p "$WORK" "$OUT"
SRC="$WORK/ffmpeg-$VERSION"
TAR="$WORK/ffmpeg-$VERSION.tar.xz"

if [ ! -d "$SRC" ]; then
  echo "качаем ffmpeg $VERSION…"
  curl -fsSL -o "$TAR" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
  # Сверяем то, что скачали: подменённый архив собрался бы молча.
  echo "$SHA  $TAR" | sha256sum -c -
  tar xf "$TAR" -C "$WORK"
fi

cd "$SRC"
# --disable-everything и поимённый список: полный ffmpeg весит под сотню
# мегабайт и тянет кодеки, которые нам не нужны ни на что.
[ -f config.h ] || ./configure \
  --disable-everything \
  --disable-network \
  --disable-autodetect \
  --disable-doc \
  --disable-debug \
  --disable-shared \
  --enable-static \
  --enable-small \
  --enable-protocol=file \
  --enable-demuxer=wav,ogg,matroska,mov,mp3,flac,aac,aiff,asf,w64 \
  --enable-decoder=opus,vorbis,aac,mp3,flac,alac,wmav1,wmav2,wmapro,wmalossless,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8 \
  --enable-parser=opus,vorbis,aac,mpegaudio,flac \
  --enable-muxer=wav \
  --enable-encoder=pcm_s16le \
  --enable-filter=aresample,aformat,anull \
  --enable-bsf=null

make -j "$(nproc 2>/dev/null || echo 4)"

cd - >/dev/null
cp "$SRC/ffmpeg.exe" "$OUT/ffmpeg.exe"
# LGPL обязывает возить с собой текст лицензии.
cp "$SRC/COPYING.LGPLv2.1" "$OUT/ffmpeg-LICENSE.txt"
echo "$VERSION" > "$STAMP"

ls -la "$OUT/ffmpeg.exe"
echo "ffmpeg $VERSION собран"
