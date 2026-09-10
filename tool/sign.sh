#!/bin/sh
# Подписать собранное приложение постоянной подписью разработчика.
#
# Зачем: macOS привязывает выданное разрешение («Универсальный доступ»)
# к подписи приложения. Flutter собирает с ad-hoc
# подписью, а её отпечаток меняется с каждой сборкой — выданное разрешение
# после пересборки перестаёт действовать, и диктовка молча замолкает.
# Подпись сертификатом из связки ключей одна и та же от сборки к сборке,
# поэтому разрешение выдаётся один раз.
#
# Заодно кладёт внутрь движок whisper.cpp — его надо собрать заранее,
# один раз: ./tool/engine.sh
#
# Запускать после `flutter build macos --release`.
set -e
cd "$(dirname "$0")/.."

APP=build/macos/Build/Products/Release/tsukiko.app
ID=$(security find-identity -v -p codesigning | awk 'NR==1 {print $2}')
if [ -z "$ID" ]; then
  echo "Нет сертификата для подписи кода. Xcode → Settings → Accounts." >&2
  exit 1
fi

# Движок едет внутри приложения: у всех один и тот же, не зависит от того,
# что стоит у человека в системе, и не пропадает, если он снесёт Homebrew.
# Собирается отдельно — tool/engine.sh.
ENGINE=macos/Engine
if [ ! -x "$ENGINE/tsukiko-recognizer" ] || [ ! -x "$ENGINE/tsukiko-dictation" ] ||
  [ ! -x "$ENGINE/nemo/bin/nemo-speech" ]; then
  echo "Нет движка в $ENGINE. Соберите: ./tool/engine.sh" >&2
  exit 1
fi
# Helpers — место для вложенных программ, и по правилам подписи там
# не должно лежать ничего, кроме них: лицензия едет в Resources.
mkdir -p "$APP/Contents/Helpers"
cp "$ENGINE/tsukiko-recognizer" "$ENGINE/tsukiko-dictation" "$APP/Contents/Helpers/"
cp "$ENGINE/whisper.cpp-LICENSE.txt" "$APP/Contents/Resources/"
rm -rf "$APP/Contents/Helpers/nemo"
cp -R "$ENGINE/nemo" "$APP/Contents/Helpers/"

# Расшифровщик из командной строки. Едет рядом с движком, потому что
# он такая же вложенная программа: скрипту и нейросетевому агенту нужен
# текст, а не окно, и запускать ради одного голосового сообщения весь
# интерфейс с котом — нелепо. Flutter в него не входит вовсе, поэтому
# `dart compile exe` собирает его за секунды и без движка Flutter.
dart compile exe bin/tsukiko_transcribe.dart \
  -o "$APP/Contents/Helpers/tsukiko-transcribe"

# Метка времени от службы Apple, а не `--timestamp=none`.
#
# Без неё подпись действительна ровно столько, сколько действителен
# сертификат, — а сертификат разработчика живёт год. То есть через год
# приложение перестало бы запускаться у всех, кому его отдали, и
# у самого автора тоже. С меткой подпись переживает истечение
# сертификата: она удостоверяет, что подписано было, пока он ещё
# действовал.
#
# Стоит это одного обращения к сети при сборке. Без сети подписать
# по-прежнему можно — TSUKIKO_NO_TIMESTAMP=1, — но раздавать такое
# нельзя.
STAMP=--timestamp
[ -n "$TSUKIKO_NO_TIMESTAMP" ] && STAMP=--timestamp=none

# Вложенное подписывается первым: подпись бандла запечатывает то, что внутри.
find "$APP/Contents/Frameworks" -depth 1 -print0 |
  xargs -0 -I{} codesign --force --sign "$ID" "$STAMP" {}
find "$APP/Contents/Helpers" -type f \( -perm -111 -o -name '*.dylib' \) -print0 |
  xargs -0 -I{} codesign --force --sign "$ID" "$STAMP" {}
codesign --force --sign "$ID" "$STAMP" \
  --entitlements macos/Runner/Release.entitlements "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier' || true
