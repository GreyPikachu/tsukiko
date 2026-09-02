#!/bin/sh
# Собрать движок whisper.cpp, который поедет внутри приложения.
#
# Зачем свой, а не тот, что у человека из Homebrew: мы передаём модели
# флаги, которых в старых сборках нет вовсе (`--vad`, `-mc`,
# `--carry-initial-prompt`). На чужой сборке распознавание либо падает,
# либо молча работает хуже. Свой движок один и тот же у всех, ставится
# вместе с приложением и не пропадает, если человек снесёт Homebrew.
#
# Чужой при этом не трогается: tsukiko ничего не ставит в систему
# и ничего оттуда не удаляет.
#
# Итог: два самодостаточных универсальных бинарника в macos/Engine.
# Самодостаточных буквально — линкуются только с системными фреймворками
# (сборка статическая, шейдеры Metal вшиты внутрь), поэтому ни
# библиотек рядом, ни правки путей загрузки не нужно.
#
# Нужен cmake: brew install cmake. Он нужен только тому, кто собирает
# приложение, — готовому приложению не нужен ничей.
set -e
cd "$(dirname "$0")/.."

VERSION=v1.9.3
SHA=1650f884effba487025143bd8facd2f9fb40a83b3737a732803c67a8d659d9c0

OUT=macos/Engine
WORK=build/engine
STAMP="$OUT/.version"

if [ "$1" != "--force" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$VERSION" ] &&
  [ -x "$OUT/tsukiko-recognizer" ] && [ -x "$OUT/tsukiko-dictation" ]; then
  echo "движок $VERSION уже собран — $OUT"
  exit 0
fi

command -v cmake >/dev/null || {
  echo "Нужен cmake: brew install cmake" >&2
  exit 1
}

mkdir -p "$WORK" "$OUT"
SRC="$WORK/whisper.cpp-${VERSION#v}"
TAR="$WORK/$VERSION.tar.gz"

if [ ! -d "$SRC" ]; then
  echo "качаем whisper.cpp $VERSION…"
  curl -fsSL -o "$TAR" \
    "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/$VERSION.tar.gz"
  # Сверяем то, что скачали: подменённый архив собрался бы молча.
  echo "$SHA  $TAR" | shasum -a 256 -c - >/dev/null
  tar xzf "$TAR" -C "$WORK"
fi

# Универсальный, как и само приложение: Flutter собирает обе архитектуры.
cmake -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=ON \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 >/dev/null
cmake --build "$SRC/build" --config Release -j "$(sysctl -n hw.ncpu)" >/dev/null

# Имена свои: под ними процессы и видно в «Мониторинге системы».
cp "$SRC/build/bin/whisper-cli" "$OUT/tsukiko-recognizer"
cp "$SRC/build/bin/whisper-server" "$OUT/tsukiko-dictation"
# MIT обязывает возить с собой текст лицензии.
cp "$SRC/LICENSE" "$OUT/whisper.cpp-LICENSE.txt"
echo "$VERSION" > "$STAMP"

echo "движок $VERSION собран:"
ls -la "$OUT" | grep tsukiko-
